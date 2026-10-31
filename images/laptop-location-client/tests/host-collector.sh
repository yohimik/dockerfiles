#!/bin/sh
# Exercise host collection with synthetic commands; never inspect real hardware.
set -eu
test_dir=$(mktemp -d '/tmp/host collector.XXXXXX')
trap 'rm -rf -- "$test_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
project="$test_dir/project with spaces"
mkdir -p "$project" "$test_dir/bin"
cp /defaults/collect-device-info.sh "$project/collect-device-info.sh"
REAL_JQ=$(command -v jq)
export REAL_JQ
cat > "$test_dir/bin/docker" <<'EOF'
#!/bin/sh
set -eu
if [ "$*" = 'compose version' ]; then exit 0; fi
if [ "${MOCK_DOCKER_FAIL:-0}" = 1 ]; then printf '{incomplete'; exit 42; fi
while [ "$#" -gt 0 ] && [ "$1" != -n ]; do shift; done
[ "$#" -gt 0 ] || exit 90
exec "$REAL_JQ" "$@"
EOF
cat > "$test_dir/bin/uname" <<'EOF'
#!/bin/sh
case "$*" in
    -s) printf '%s\n' "${MOCK_SYSTEM:-Darwin}" ;;
    -r) printf '%s\n' 'test-release' ;;
    -m) printf '%s\n' 'test-architecture' ;;
    -srm) printf '%s\n' 'Test OS test-architecture' ;;
    *) exit 90 ;;
esac
EOF
cat > "$test_dir/bin/sysctl" <<'EOF'
#!/bin/sh
[ "${MOCK_MISSING:-0}" = 0 ] || exit 1
case "$*" in
    '-n hw.model') printf '%s\n' 'TestModel1,1' ;;
    '-n machdep.cpu.brand_string') printf '%s\n' 'Test "quoted" CPU' ;;
    '-n hw.logicalcpu') printf '%s\n' 12 ;;
    '-n hw.memsize') printf '%s\n' 34359738368 ;;
    *) exit 90 ;;
esac
EOF
cat > "$test_dir/bin/sw_vers" <<'EOF'
#!/bin/sh
case "$*" in
    -productName) printf '%s\n' 'Test macOS' ;;
    -productVersion) printf '%s\n' '42.0' ;;
    *) exit 90 ;;
esac
EOF
cat > "$test_dir/bin/system_profiler" <<'EOF'
#!/bin/sh
[ "${MOCK_MISSING:-0}" = 0 ] || exit 1
printf '%s\n' 'Hardware:' '    Model Name: TestBook Pro' \
    '    Serial Number: MUST_NOT_APPEAR' '    Hardware UUID: MUST_NOT_APPEAR'
EOF
cat > "$test_dir/bin/cygpath" <<'EOF'
#!/bin/sh
printf '%s\n' "$2"
EOF
cat > "$test_dir/bin/powershell.exe" <<'EOF'
#!/bin/sh
printf '%s\n' '{"model_name":"Test Windows Model","cpu_model":"Test CPU","logical_cpus":8,"memory_bytes":17179869184,"serial_number":"MUST_NOT_APPEAR"}'
EOF
chmod 755 "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"
report="$project/.state/input/device-info.json"
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$test_dir/collector.log" >&2; exit 1; }
collect() { sh "$project/collect-device-info.sh" > "$test_dir/collector.log" 2>&1 || fail 'mock collection failed'; }
assert_whitelist() {
    jq -e 'keys == (["source","captured_at","system","release","architecture","os_description",
        "model_name","model_identifier","cpu_model","logical_cpus","memory_bytes"] | sort)' \
        "$report" >/dev/null || fail 'collector included unexpected metadata'
    if grep -q MUST_NOT_APPEAR "$report"; then fail 'collector exposed serial or UUID'; fi
    [ "$(stat -c %a "$report")" = 600 ] || fail 'machine metadata is not private on disk'
}

collect
assert_whitelist
jq -e '.source == "host_setup_shell" and .system == "Darwin"
    and .model_name == "TestBook Pro" and .model_identifier == "TestModel1,1"
    and .cpu_model == "Test \"quoted\" CPU" and .logical_cpus == 12 and .memory_bytes == 34359738368' \
    "$report" >/dev/null || fail 'mock macOS fields were lost or incorrectly escaped'
printf '%s\n' 'PASS: host collector whitelists machine fields, escapes text, and excludes serial/UUID'

MOCK_MISSING=1 collect
assert_whitelist
jq -e '[.model_name,.model_identifier,.cpu_model,.logical_cpus,.memory_bytes] | all(. == null)' \
    "$report" >/dev/null || fail 'unavailable machine fields should be null'
printf '%s\n' 'PASS: unavailable hardware details remain null'

MOCK_SYSTEM=MINGW64_NT-10.0 collect
assert_whitelist
jq -e '.model_name == "Test Windows Model" and .cpu_model == "Test CPU"
    and .logical_cpus == 8 and .memory_bytes == 17179869184' "$report" >/dev/null \
    || fail 'mock Windows machine projection was incorrect'
printf '%s\n' 'PASS: Windows hardware output is projected to the same allowed fields'

cp "$report" "$test_dir/previous.json"
if MOCK_DOCKER_FAIL=1 sh "$project/collect-device-info.sh" > "$test_dir/collector.log" 2>&1; then
    fail 'failed collector renderer unexpectedly succeeded'
fi
cmp "$report" "$test_dir/previous.json" || fail 'failed collection replaced the prior report'
[ -z "$(find "$project/.state/input" -name '.device-info.*' -print)" ] || fail 'failed collection left temporary metadata'
printf '%s\n' 'PASS: failed collection preserves previous metadata and removes partial output' \
    '' '4 host collector checks passed.'
