#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
passed=0
remote=/tmp/device-report-test/remote.git
fail() { printf 'FAIL: %s\n' "$*" >&2; cat /tmp/publish.log >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$*"; }
head_commit() { git --git-dir "$remote" rev-parse refs/heads/main; }
reset_case() {
    for directory in /config /jobs /input /credentials /data /deployment; do
        find "$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- '{}' +
    done
    rm -rf /tmp/device-report-test
    mkdir -p /tmp/device-report-test
    cp -R /defaults/config/. /config/
    cp -R /defaults/jobs/. /jobs/
    cp /defaults/compose.yaml /defaults/Dockerfile /deployment/
    cat >> /config/settings.sh <<'EOF'
GIT_URL='/tmp/device-report-test/remote.git'
GIT_BRANCH='main'
GIT_AUTHOR_NAME='Report Test'
GIT_AUTHOR_EMAIL='report-test@localhost'
EOF
    printf '%s\n' '{"model_name":"Configured laptop"}' > /config/device.json
    printf '\nTIMEOUT_SECONDS=5\n' >> /config/jobs/device.sh
    printf '%s\n' 'credential_secret_should_never_be_published' > /credentials/github_token
    printf '%s\n' 'input_secret_should_never_be_published' > /input/unrelated-secret.txt
    git init -q --bare -b main "$remote"
    git init -q -b main /tmp/device-report-test/seed
    git -C /tmp/device-report-test/seed config user.name 'Report Test'
    git -C /tmp/device-report-test/seed config user.email 'report-test@localhost'
    printf '%s\n' 'Existing repository file' > /tmp/device-report-test/seed/keep.txt
    git -C /tmp/device-report-test/seed add keep.txt
    git -C /tmp/device-report-test/seed commit -qm seed
    git -C /tmp/device-report-test/seed push -q "$remote" main
    : > /tmp/publish.log
}
publish() {
    /app/push.sh /config/jobs/device.sh > /tmp/publish.log 2>&1 || fail 'report publishing unexpectedly failed'
}
read_report() {
    git --git-dir "$remote" show "main:${1:-device/client-info-Configured-laptop-1.json}" > /tmp/report.json \
        || fail 'report was not committed at the configured destination'
}
assert_no_secrets() {
    if grep -q 'credential_secret_should_never_be_published\|input_secret_should_never_be_published' /tmp/report.json; then
        fail 'report captured unrelated credentials or input files'
    fi
    jq -e '.configuration == null or (.configuration.files | all(.path | (startswith("credentials/") or startswith("input/")) | not))' \
        /tmp/report.json >/dev/null || fail 'snapshot traversed outside config and jobs'
}
expect_failure() {
    previous_commit=$(head_commit)
    if /app/push.sh /config/jobs/device.sh > /tmp/publish.log 2>&1; then
        fail 'invalid report input unexpectedly published'
    fi
    [ "$(head_commit)" = "$previous_commit" ] || fail 'invalid report input changed the remote commit'
}

reset_case
printf '\nINCLUDE_CONFIGURATION=true\nINCLUDE_CONTAINER_INFO=true\n' >> /config/device-report.sh
printf '%s\n' '{"model_name":"Configured laptop","custom":{"team":"engineering"}}' > /config/device.json
mkdir -p /config/custom /jobs/nested
printf 'first line\nsecond "quoted" line\n' > '/config/custom/quoted"name.txt'
printf '#!/bin/sh\nprintf "custom job\\n"\n' > /jobs/nested/custom.sh
printf '%s\n' 'included hidden setting' > /config/.hidden
printf '%s\n' '{"model_name":"Host laptop","model_identifier":"HostModel1","system":"host-os","release":"1.0","architecture":"arm64","cpu_model":"Host CPU","logical_cpus":8,"memory_bytes":17179869184,"hostname":"excluded_host_name","serial":"excluded_host_serial"}' > /input/device-info.json
publish
read_report
if git --git-dir "$remote" cat-file -e main:device/client-info.json 2>/dev/null; then
    fail 'report was published without the default model and attempt suffix'
fi
jq -e '.schema_version == 1 and (.recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and .device.model_name == "Configured laptop"
    and .device.model_identifier == "HostModel1"
    and .device.system == "host-os" and .device.architecture == "arm64"
    and .device.cpu_model == "Host CPU" and .device.logical_cpus == 8
    and .device.memory_bytes == 17179869184
    and (.device | has("custom") or has("hostname") or has("serial") | not)
    and .container_runtime.source == "container"' /tmp/report.json >/dev/null || fail 'device report structure or metadata is incorrect'
jq -e --rawfile expected '/config/custom/quoted"name.txt' \
    '.configuration.files | any(.path == "config/custom/quoted\"name.txt" and .content == $expected)' \
    /tmp/report.json >/dev/null || fail 'quoted filename or verbatim content was not preserved'
jq -e --rawfile expected /jobs/nested/custom.sh \
    '.configuration.files | any(.path == "jobs/nested/custom.sh" and .content == $expected)' \
    /tmp/report.json >/dev/null || fail 'custom job script missing from configuration'
jq -e --rawfile expected /config/settings.sh \
    '.configuration.files | any(.path == "config/settings.sh" and .content == $expected)' \
    /tmp/report.json >/dev/null || fail 'full settings text missing from configuration'
for descriptor in compose.yaml Dockerfile; do
    jq -e --arg path "deployment/$descriptor" --rawfile expected "/deployment/$descriptor" \
        '.configuration.files | any(.path == $path and .content == $expected)' \
        /tmp/report.json >/dev/null || fail 'deployment descriptor missing from configuration'
done
jq -e '.configuration.files | any(.path == "config/.hidden")' /tmp/report.json >/dev/null || fail 'hidden config file was omitted'
[ "$(git --git-dir "$remote" show main:keep.txt)" = 'Existing repository file' ] || fail 'publishing overwrote unrelated repository data'
assert_no_secrets
if grep -q 'excluded_host_name\|excluded_host_serial' /tmp/report.json; then
    fail 'host identifiers leaked into the machine report'
fi
pass 'device and host metadata, complete configuration, and custom scripts publish without credentials'

first_time=$(jq -r .recorded_at /tmp/report.json)
first_commit=$(head_commit)
sleep 1
publish
read_report device/client-info-Configured-laptop-2.json
[ "$(jq -r .recorded_at /tmp/report.json)" != "$first_time" ] || fail 'report timestamp did not refresh'
[ "$(head_commit)" != "$first_commit" ] || fail 'fresh report was not pushed'
git --git-dir "$remote" show main:device/client-info-Configured-laptop-1.json > /tmp/first-report.json
[ "$(jq -r .recorded_at /tmp/first-report.json)" = "$first_time" ] || fail 'later push replaced the previous attempt report'
pass 'a later changed report advances the attempt filename and preserves the previous report'

reset_case
publish
read_report
jq -e '.device.model_name == "Configured laptop"
    and .configuration == null and .container_runtime == null
    and (.device | del(.model_name) | all(. == null))' /tmp/report.json >/dev/null \
    || fail 'optional missing host metadata was not represented as null'
pass 'default report includes model information without config snapshots or container details'

reset_case
printf '%s\n' '{"model_name":"","cpu_model":"Configured CPU","memory_bytes":null}' > /config/device.json
printf '%s\n' '{"model_name":"Detected model","cpu_model":"Detected CPU","logical_cpus":8,"memory_bytes":17179869184,"hostname":"excluded_host_name","serial":"excluded_host_serial","token":"input_secret_should_never_be_published"}' > /input/device-info.json
publish
read_report device/client-info-Detected-model-1.json
jq -e '.configuration == null and .container_runtime == null
    and .device.model_name == "Detected model" and .device.cpu_model == "Configured CPU"
    and .device.logical_cpus == 8 and .device.memory_bytes == 17179869184
    and (.device | has("hostname") or has("serial") or has("token") | not)' \
    /tmp/report.json >/dev/null || fail 'default machine-field merging or filtering is incorrect'
assert_no_secrets
pass 'default reports merge detected machine fields with nonempty overrides and discard unrelated metadata'

reset_case
printf '\nINCLUDE_CONFIGURATION=false\nINCLUDE_CONTAINER_INFO=false\n' >> /config/device-report.sh
publish
read_report
jq -e '.configuration == null and .container_runtime == null and .device.model_name == "Configured laptop"' \
    /tmp/report.json >/dev/null || fail 'report inclusion options were ignored'
assert_no_secrets
pass 'configuration and container information can be disabled'

reset_case
printf '/data/generated/device-report.json\treports/custom-device.json\n' > /config/device-files.tsv
publish
read_report reports/custom-device-Configured-laptop-1.json
if git --git-dir "$remote" cat-file -e main:device/client-info-Configured-laptop-1.json 2>/dev/null; then
    fail 'report was also written to its old destination'
fi
pass 'the publishing destination follows the configurable file mapping'

for invalid_json in '{broken' '[]' 'null' '"not an object"'; do
    reset_case
    printf '%s\n' "$invalid_json" > /config/device.json
    expect_failure
    pass "invalid configured device JSON $invalid_json never commits"
done

for invalid_json in '{broken' '[]' 'null'; do
    reset_case
    printf '%s\n' "$invalid_json" > /input/device-info.json
    expect_failure
    pass "invalid supplied host JSON $invalid_json never commits"
done

for invalid_machine in '{"logical_cpus":"eight"}' '{"memory_bytes":-1}'; do
    reset_case
    printf '%s\n' "$invalid_machine" > /input/device-info.json
    expect_failure
    pass "invalid machine counts $invalid_machine never commit"
done

reset_case
printf '\nINCLUDE_CONFIGURATION=true\n' >> /config/device-report.sh
ln -s /credentials/github_token /config/leaked-secret
expect_failure
pass 'symlinked configuration cannot expose credentials or create a commit'

reset_case
printf '\nINCLUDE_CONFIGURATION=true\n' >> /config/device-report.sh
mkdir -p /jobs/nested
ln -s /input/unrelated-secret.txt /jobs/nested/leaked-secret
expect_failure
pass 'symlinked custom jobs cannot expose unrelated input or create a commit'

reset_case
printf '\nINCLUDE_CONFIGURATION=true\n' >> /config/device-report.sh
mkfifo /config/custom-pipe
expect_failure
pass 'nonregular configuration files fail without committing or hanging'

reset_case
publish
read_report
cp /data/generated/device-report.json /tmp/previous-report.json
printf '%s\n' '{broken' > /input/device-info.json
expect_failure
cmp /data/generated/device-report.json /tmp/previous-report.json || fail 'failed report generation replaced the previous report'
pass 'failed generation preserves the previous complete report and remote commit'

reset_case
printf '\nINCLUDE_CONFIGURATION=true\n' >> /config/device-report.sh
newline_name=$(printf 'line\nbreak.txt')
printf '%s\n' 'newline filename content' > "/config/$newline_name"
previous_commit=$(head_commit)
if /app/push.sh /config/jobs/device.sh > /tmp/publish.log 2>&1; then
    read_report
    jq -e --arg path "config/$newline_name" --rawfile expected "/config/$newline_name" \
        '.configuration.files | any(.path == $path and .content == $expected)' \
        /tmp/report.json >/dev/null || fail 'newline filename was silently split or corrupted'
else
    [ "$(head_commit)" = "$previous_commit" ] || fail 'rejected newline filename still changed the repository'
fi
pass 'newline filenames are either preserved exactly or rejected before publication'

reset_case
printf '%s\n' 'test-only-private-key' > /credentials/id_ed25519
printf '%s\n' 'test-only-known-hosts' > /credentials/known_hosts
chmod 666 /credentials/id_ed25519 /credentials/known_hosts
publish
cmp /credentials/id_ed25519 /root/.ssh/id_ed25519 || fail 'job did not prepare its SSH key'
cmp /credentials/known_hosts /root/.ssh/known_hosts || fail 'job did not prepare its known hosts'
[ "$(stat -c %a /root/.ssh)" = 700 ] || fail 'SSH directory permissions are not private'
for credential in id_ed25519 known_hosts; do
    [ "$(stat -c %a "/root/.ssh/$credential")" = 600 ] || fail 'SSH credential permissions are not private'
done
ssh_command=$(sh -c '. /app/common.sh; load_settings; printf "%s" "$GIT_SSH_COMMAND"')
[ "$ssh_command" = 'ssh -F /app/ssh_config' ] || fail 'Git does not use the static SSH configuration'
ssh -G -F /app/ssh_config git@github.com > /tmp/ssh-settings.txt 2>/dev/null
grep -Eq '^stricthostkeychecking (yes|true)$' /tmp/ssh-settings.txt || fail 'SSH host verification is not strict'
grep -qx 'batchmode yes' /tmp/ssh-settings.txt || fail 'SSH could prompt interactively'
grep -qx 'identitiesonly yes' /tmp/ssh-settings.txt || fail 'SSH could use unrelated identities'
grep -qx 'identityfile /root/.ssh/id_ed25519' /tmp/ssh-settings.txt || fail 'SSH does not use the prepared key'
grep -qx 'userknownhostsfile /root/.ssh/known_hosts' /tmp/ssh-settings.txt || fail 'SSH does not use the prepared host keys'
pass 'publishing prepares private SSH credentials and uses strict static SSH settings'

printf '%s\n' 'rotated-test-only-private-key' > /credentials/id_ed25519
printf '%s\n' 'rotated-test-only-known-hosts' > /credentials/known_hosts
# Ensure this invocation has a changed local commit even within the same second.
printf '%s\n' '{"model_name":"Configured laptop","model_identifier":"credential-rotation"}' > /config/device.json
publish
cmp /credentials/id_ed25519 /root/.ssh/id_ed25519 || fail 'job did not refresh its rotated SSH key'
cmp /credentials/known_hosts /root/.ssh/known_hosts || fail 'job did not refresh its rotated host keys'
pass 'the next publishing job refreshes rotated credentials without restarting cron'

rm /credentials/id_ed25519 /credentials/known_hosts
printf '%s\n' '{"model_name":"Configured laptop","model_identifier":"credential-removal"}' > /config/device.json
publish
if [ -e /root/.ssh/id_ed25519 ] || [ -e /root/.ssh/known_hosts ]; then
    fail 'job retained credentials that were removed from the mounted source'
fi
pass 'removed credential sources do not leave stale keys in the runtime directory'

printf '\n%s client integration checks passed.\n' "$passed"
