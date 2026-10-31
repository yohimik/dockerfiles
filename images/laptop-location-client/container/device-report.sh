#!/bin/sh
# Generate the device job's report before the normal publisher stages any files.
set -eu
umask 077
fail() { printf '%s\n' "$*" >&2; exit 1; }
DEVICE_INFO_FILE=/config/device.json
HOST_INFO_FILE=/input/device-info.json
INCLUDE_CONFIGURATION=false
INCLUDE_CONTAINER_INFO=false
[ -r /config/device-report.sh ] || fail 'Missing /config/device-report.sh'
# shellcheck source=/dev/null
. /config/device-report.sh
for option in "$INCLUDE_CONFIGURATION" "$INCLUDE_CONTAINER_INFO"; do
    case "$option" in true|false) ;; *) fail 'Report include options must be true or false' ;; esac
done

mkdir -p /data/generated
output_dir=$(realpath -e /data/generated)
case "$output_dir" in /data/*) ;; *) fail 'Report output must remain under /data' ;; esac
# Stage on the destination filesystem so the final rename is atomic.
work_dir=$(mktemp -d /data/generated/.device-report.XXXXXX)
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

validate_source() {
    case "$1" in /config/*|/input/*) ;; *) fail 'Device information must be under /config or /input' ;; esac
}

read_object() {
    validate_source "$1"
    resolved=$(realpath -e -- "$1") || fail 'Device information file is missing'
    case "$resolved" in /config/*|/input/*) ;; *) fail 'Device information resolves outside /config or /input' ;; esac
    [ -f "$resolved" ] || fail 'Device information must be a regular JSON file'
    jq -se 'select(length == 1) | .[0] | select(type == "object")' "$resolved" > "$2" \
        || fail 'Device information must contain exactly one JSON object'
}

read_object "$DEVICE_INFO_FILE" "$work_dir/configured.json"
printf '{}\n' > "$work_dir/host.json"
if [ -n "$HOST_INFO_FILE" ]; then
    validate_source "$HOST_INFO_FILE"
    if [ -e "$HOST_INFO_FILE" ] || [ -L "$HOST_INFO_FILE" ]; then
        read_object "$HOST_INFO_FILE" "$work_dir/host.json"
    else
        printf '%s\n' 'Host information is unavailable; run collect-device-info.sh on the host to refresh it.' >&2
    fi
fi

# Include only machine specifications. In particular, hostname, serial number,
# network addresses, environment variables and arbitrary custom fields stay out.
jq -n --slurpfile configured "$work_dir/configured.json" --slurpfile host "$work_dir/host.json" '
    {model_name:null,model_identifier:null,system:null,release:null,architecture:null,
     os_description:null,cpu_model:null,logical_cpus:null,memory_bytes:null} as $fields
    | def machine_fields: with_entries(select(.key as $key | $fields | has($key)));
    $fields + ($host[0] | machine_fields)
      + ($configured[0] | machine_fields | with_entries(select(.value != null and .value != "")))
' > "$work_dir/device.json"
jq -e 'to_entries | all(
    if .key == "logical_cpus" or .key == "memory_bytes" then
        .value == null or (.value | type == "number" and . > 0 and . == floor)
    else .value == null or (.value | type == "string") end
)' "$work_dir/device.json" >/dev/null || fail 'Machine fields must be strings or positive integer counts (or null)'

printf 'null\n' > "$work_dir/runtime.json"
if [ "$INCLUDE_CONTAINER_INFO" = true ]; then
    jq -n --arg hostname "$(hostname)" --arg system "$(uname -s)" \
        --arg release "$(uname -r)" --arg architecture "$(uname -m)" \
        --arg alpine_version "$(cat /etc/alpine-release)" \
        '{source:"container",hostname:$hostname,system:$system,release:$release,
          architecture:$architecture,alpine_version:$alpine_version}' > "$work_dir/runtime.json"
fi

printf 'null\n' > "$work_dir/configuration.json"
if [ "$INCLUDE_CONFIGURATION" = true ]; then
    # Only these read-only trees are configuration. Reject symlinks and
    # special files rather than following a link into credentials or host input.
    if [ ! -d /config ] || [ ! -d /jobs ] || [ ! -d /deployment ]; then
        fail 'Missing configuration, job-script or deployment directory'
    fi
    find /config /jobs /deployment ! -type d ! -type f -print > "$work_dir/unsupported"
    [ ! -s "$work_dir/unsupported" ] || fail 'Configuration snapshots do not allow symlinks or special files'
    : > "$work_dir/files.jsonl"
    # find -exec ... + passes filenames as arguments, including spaces/newlines.
    # A failing batch makes find fail so partial snapshots are never published.
    find /config /jobs /deployment -type f -exec sh -c '
        output=$1
        shift
        for file do
            jq -n --arg path "${file#/}" --rawfile content "$file" \
                '\''{path:$path,content:$content}'\'' >> "$output" || exit 1
        done
    ' sh "$work_dir/files.jsonl" {} +
    jq -s '{files:sort_by(.path)}' "$work_dir/files.jsonl" > "$work_dir/configuration.json"
fi

jq -n --arg at "$(date -u +%FT%TZ)" --slurpfile device "$work_dir/device.json" \
    --slurpfile runtime "$work_dir/runtime.json" --slurpfile configuration "$work_dir/configuration.json" \
    '{schema_version:1,recorded_at:$at,device:$device[0],container_runtime:$runtime[0],
      configuration:$configuration[0]}' > "$work_dir/report.json"
chmod 600 "$work_dir/report.json"
mv -- "$work_dir/report.json" /data/generated/device-report.json
