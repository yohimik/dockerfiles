#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cron_pid=''
passed=0
stop_cron() {
    if [ -n "$cron_pid" ]; then
        kill "$cron_pid" 2>/dev/null || :
        wait "$cron_pid" 2>/dev/null || :
        cron_pid=''
    fi
}
trap stop_cron EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; cat /tmp/check.log /tmp/cron.log >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$*"; }
reset_case() {
    stop_cron
    rm -rf /tmp/api /tmp/crontabs /data/*
    mkdir -p /tmp/api /tmp/crontabs
    cat > /config/settings.sh <<'EOF'
GITHUB_REPOSITORY='test-owner/test-repo'
INACTIVITY_DAYS=30
TZ='Etc/UTC'
EOF
    printf '%s\n' '0 0 * * * /app/check.sh >>/proc/1/fd/1 2>>/proc/1/fd/2' > /config/crontab
    printf '%s\n' 'test_only_token' > /credentials/github_token
    printf '%s\n' 200 > /tmp/api/get-status
    printf '%s\n' 200 > /tmp/api/patch-status
    : > /tmp/api/requests
    : > /tmp/check.log
    : > /tmp/cron.log
}
repository() {
    pushed_at=$(/bin/date -u -d "@$((2000000000 - $1))" +%FT%TZ)
    jq -n --arg pushed_at "$pushed_at" \
        '{id:123,full_name:"test-owner/test-repo",private:true,visibility:"private",pushed_at:$pushed_at}' \
        > /tmp/api/get.json
    jq '.private = false | .visibility = "public"' /tmp/api/get.json > /tmp/api/patch.json
}
start_cron() {
    /app/entrypoint.sh > /tmp/cron.log 2>&1 &
    cron_pid=$!
    tries=0
    while ! pgrep -x crond >/dev/null; do
        kill -0 "$cron_pid" 2>/dev/null || fail 'entrypoint exited'
        tries=$((tries + 1))
        [ "$tries" -lt 50 ] || fail 'cron did not start'
        sleep 0.1
    done
}
check_ok() { /app/check.sh > /tmp/check.log 2>&1 || fail 'check unexpectedly failed'; }
check_error() { if /app/check.sh > /tmp/check.log 2>&1; then fail 'invalid response unexpectedly succeeded'; fi; }
assert_scheduled() {
    crontab -c /tmp/crontabs -l | grep -q /app/check.sh || fail 'scheduled check was removed'
    [ ! -e /data/completed.json ] || fail 'failure incorrectly recorded completion'
    if grep -q PATCH /tmp/api/requests; then fail 'unexpected visibility change'; fi
}
assert_completed() {
    [ -s /data/completed.json ] || fail 'missing durable completion record'
    if crontab -c /tmp/crontabs -l 2>/dev/null | grep -q /app/check.sh; then
        fail 'cron check remains after success'
    fi
    kill -0 "$cron_pid" || fail 'cron stopped instead of removing its job'
}

reset_case
repository 86400
start_cron
check_ok
assert_scheduled
pass 'a recent push leaves the repository private and job installed'

reset_case
repository 2592000
start_cron
check_ok
assert_scheduled
pass 'exactly 30 days does not trigger publication'

reset_case
repository 2592001
start_cron
check_ok
assert_completed
[ "$(grep -c PATCH /tmp/api/requests)" -eq 1 ] || fail 'expected one PATCH'
jq -e '.visibility == "public" or .private == false' /tmp/api/request-body >/dev/null || fail 'wrong visibility request'
pass 'older than 30 days publishes and removes the daily job'

request_count=$(wc -l < /tmp/api/requests)
check_ok
[ "$(wc -l < /tmp/api/requests)" -eq "$request_count" ] || fail 'completed check contacted API again'
stop_cron
rm -f /credentials/github_token
start_cron
assert_completed
[ "$(wc -l < /tmp/api/requests)" -eq "$request_count" ] || fail 'restart contacted API after completion'
pass 'completion survives restart without credentials or another API request'

reset_case
repository 2592001
printf '%s\n' 403 > /tmp/api/patch-status
start_cron
check_error
crontab -c /tmp/crontabs -l | grep -q /app/check.sh || fail 'PATCH failure removed cron'
[ ! -e /data/completed.json ] || fail 'PATCH failure recorded completion'
printf '%s\n' 200 > /tmp/api/patch-status
check_ok
assert_completed
pass 'a failed visibility update retains cron and a later run retries'

reset_case
repository 2592001
printf '%s\n' 401 > /tmp/api/get-status
start_cron
check_error
assert_scheduled
pass 'a repository API failure leaves the job installed'

for invalid_push in null '"not-a-date"' '"2030-02-31T00:00:00Z"'; do
    reset_case
    repository 2592001
    jq --argjson at "$invalid_push" '.pushed_at = $at' /tmp/api/get.json > /tmp/api/invalid.json
    mv /tmp/api/invalid.json /tmp/api/get.json
    start_cron
    check_error
    assert_scheduled
    pass "invalid last-push timestamp $invalid_push never publishes"
done

reset_case
repository -86400
start_cron
check_error
assert_scheduled
pass 'a future last-push timestamp never publishes'

reset_case
repository 2592001
printf '%s\n' '{bad-json' > /tmp/api/get.json
start_cron
check_error
assert_scheduled
pass 'malformed API output never publishes'

reset_case
repository 86400
jq '.pushed_at = null' /tmp/api/patch.json > /tmp/api/get.json
start_cron
check_ok
assert_completed
if grep -q PATCH /tmp/api/requests; then fail 'already-public repository was patched'; fi
pass 'an already-public repository retires its check without a PATCH'

reset_case
repository 2592001
recent=$(/bin/date -u -d '@2000000000' +%FT%TZ)
jq --arg at "$recent" '.pushed_at = $at' /tmp/api/get.json > /tmp/api/get-second.json
start_cron
check_ok
assert_scheduled
pass 'a push arriving before the final recheck cancels publication'

reset_case
repository 2592001
jq '.id = 999' /tmp/api/get.json > /tmp/api/get-second.json
start_cron
check_error
assert_scheduled
pass 'repository identity changing during the recheck cancels publication'

reset_case
repository 2592001
jq '.full_name = "test-owner/wrong-repo"' /tmp/api/get.json > /tmp/api/invalid.json
mv /tmp/api/invalid.json /tmp/api/get.json
start_cron
check_error
assert_scheduled
pass 'a response for another repository never publishes'

reset_case
repository 2592001
cp /tmp/api/get.json /tmp/api/patch.json
start_cron
check_error
crontab -c /tmp/crontabs -l | grep -q /app/check.sh || fail 'unconfirmed update removed cron'
[ ! -e /data/completed.json ] || fail 'unconfirmed update recorded completion'
pass 'HTTP success without confirmed public visibility retains the job'

reset_case
repository 2592001
touch /tmp/api/block-get
start_cron
/app/check.sh > /tmp/first-check.log 2>&1 &
first_check=$!
attempts=0
while [ ! -e /tmp/api/get-entered ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 50 ] || fail 'first concurrent check did not start'
    sleep 0.1
done
check_ok
[ "$(wc -l < /tmp/api/requests)" -eq 1 ] || fail 'overlapping check called API'
rm /tmp/api/block-get
wait "$first_check" || { cat /tmp/first-check.log >&2; fail 'first concurrent check failed'; }
assert_completed
[ "$(grep -c PATCH /tmp/api/requests)" -eq 1 ] || fail 'overlapping checks made multiple updates'
pass 'overlapping checks perform only one visibility update'

printf '\n%s integration checks passed.\n' "$passed"
