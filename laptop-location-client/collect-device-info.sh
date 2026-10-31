#!/bin/sh
set -eu
umask 077

die() { printf '%s\n' "$*" >&2; exit 1; }
[ "$#" -eq 0 ] || die 'Usage: ./collect-device-info.sh'
project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
compose_dir="$project_dir"
device_system=$(uname -s)
case "$device_system" in
    MINGW*|MSYS*|CYGWIN*) compose_dir=$(cygpath -m "$project_dir") ;;
esac
command -v docker >/dev/null 2>&1 || die 'Install Docker and Docker Compose first.'
docker compose version >/dev/null || die 'Docker Compose is unavailable.'

# These describe the shell's machine, not the Docker container. Under WSL or
# another VM they describe that guest environment, not the physical host.
captured_at=$(date -u +%FT%TZ)
device_release=$(uname -r)
device_architecture=$(uname -m)
os_description=$(uname -srm)
model_name=''
model_identifier=''
cpu_model=''
logical_cpus=''
memory_bytes=''
windows_hardware='{}'
case "$device_system" in
    Darwin)
        if os_name=$(sw_vers -productName 2>/dev/null) && os_version=$(sw_vers -productVersion 2>/dev/null); then
            os_description="$os_name $os_version"
        fi
        model_identifier=$(sysctl -n hw.model 2>/dev/null || :)
        cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || :)
        logical_cpus=$(sysctl -n hw.logicalcpu 2>/dev/null || :)
        memory_bytes=$(sysctl -n hw.memsize 2>/dev/null || :)
        # Retain only the model-name line; never save a raw hardware report.
        model_name=$(LC_ALL=C system_profiler SPHardwareDataType -detailLevel mini 2>/dev/null |
            awk -F ': ' '/^[[:space:]]*Model Name:/ { print $2; exit }')
        ;;
    Linux)
        model_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null || :)
        cpu_model=$(awk -F ': ' '/^model name[[:space:]]*:/ { print $2; exit }' /proc/cpuinfo 2>/dev/null || :)
        logical_cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || :)
        memory_bytes=$(awk '/^MemTotal:/ { printf "%.0f\n", $2 * 1024; exit }' /proc/meminfo 2>/dev/null || :)
        ;;
    MINGW*|MSYS*|CYGWIN*)
        if command -v powershell.exe >/dev/null 2>&1; then
            # Project only hardware properties, excluding owner/device identifiers.
            # shellcheck disable=SC2016 # PowerShell expands these variables.
            if ! windows_hardware=$(powershell.exe -NoProfile -NonInteractive -Command '
                $ErrorActionPreference = "Stop"
                [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
                $machine = Get-CimInstance Win32_ComputerSystem -Property Model,NumberOfLogicalProcessors,TotalPhysicalMemory
                $cpu = Get-CimInstance Win32_Processor -Property Name | Select-Object -First 1
                @{model_name=$machine.Model;cpu_model=$cpu.Name;
                  logical_cpus=$machine.NumberOfLogicalProcessors;
                  memory_bytes=$machine.TotalPhysicalMemory} | ConvertTo-Json -Compress
            ' 2>/dev/null); then
                windows_hardware='{}'
            fi
        fi
        ;;
esac

state_dir="$project_dir/.state"
input_dir="$state_dir/input"
mkdir -p "$input_dir"
chmod 700 "$state_dir" "$input_dir"
report_tmp=$(mktemp "$input_dir/.device-info.XXXXXX")
trap 'rm -f -- "$report_tmp"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Use the image's jq to escape host strings; no host jq installation is needed.
docker compose --project-directory "$compose_dir" run --rm --no-deps --build -T \
    --entrypoint jq client -n \
    --arg captured_at "$captured_at" \
    --arg system "$device_system" --arg release "$device_release" \
    --arg architecture "$device_architecture" --arg os_description "$os_description" \
    --arg model_name "$model_name" --arg model_identifier "$model_identifier" \
    --arg cpu_model "$cpu_model" --arg logical_cpus "$logical_cpus" \
    --arg memory_bytes "$memory_bytes" --arg windows_json "$windows_hardware" \
    'def text: if type == "string" and length > 0 then . else null end;
     def positive_integer:
       (try tonumber catch null) | if type == "number" and . > 0 and . == floor then . else null end;
     ($windows_json | fromjson? // {}) as $windows |
     {source:"host_setup_shell",captured_at:$captured_at,
      system:$system,release:$release,architecture:$architecture,
      os_description:$os_description,model_name:(($windows.model_name // $model_name) | text),
      model_identifier:($model_identifier | text),cpu_model:(($windows.cpu_model // $cpu_model) | text),
      logical_cpus:(($windows.logical_cpus // $logical_cpus) | positive_integer),
      memory_bytes:(($windows.memory_bytes // $memory_bytes) | positive_integer)}' > "$report_tmp"
chmod 600 "$report_tmp"
mv -- "$report_tmp" "$input_dir/device-info.json"
printf '%s\n' 'Machine configuration and model saved to .state/input/device-info.json.'
