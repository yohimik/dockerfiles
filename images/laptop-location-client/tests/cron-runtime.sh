#!/bin/sh
# Start the real entrypoint with a harmless schedule and replace its mounted file.
set -eu
[ "$#" -eq 1 ] || { printf '%s\n' 'Usage: cron-runtime.sh IMAGE' >&2; exit 64; }
image=$1
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/client-cron-test.XXXXXX")
container_id=''
cleanup() {
    if [ -n "$container_id" ]; then docker rm -f "$container_id" >/dev/null 2>&1 || :; fi
    rm -rf -- "$fixture_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    if [ -n "$container_id" ]; then docker logs "$container_id" >&2 || :; fi
    exit 1
}

entrypoint=$(docker image inspect --format '{{index .Config.Entrypoint 0}}' "$image")
case "$entrypoint" in supercronic|/usr/bin/supercronic) ;; *) fail 'image entrypoint is not the cron runner' ;; esac
image_command=$(docker image inspect --format '{{json .Config.Cmd}}' "$image")
case "$image_command" in null|'[]') ;; *) fail 'image appends an unexpected command to cron' ;; esac

# Supercronic accepts seconds in its seven-field syntax. These fixture jobs only
# write inside container tmpfs; networking is disabled and no real jobs mount.
printf '%s\n' '* * * * * * * printf x >> /tmp/cron-initial' > "$fixture_dir/crontab"
docker run --rm --network none --entrypoint sh -v "$fixture_dir:/fixture" "$image" -c '
    chmod 666 /fixture/crontab
    chown 1000:1000 /fixture/crontab
'
container_id=$(docker run --detach --init --network none --read-only \
    --tmpfs /tmp:mode=1777 --tmpfs /var/run --tmpfs /data --tmpfs /root/.ssh \
    --env TZ=Asia/Dubai -v "$fixture_dir:/config:ro" "$image")

wait_for_file() {
    attempt=0
    until docker exec "$container_id" test -s "$1" >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 60 ] || fail "cron did not produce $1"
        [ "$(docker inspect --format '{{.State.Running}}' "$container_id")" = true ] \
            || fail 'cron container stopped unexpectedly'
        sleep 0.2
    done
}

wait_for_file /tmp/cron-initial
docker exec "$container_id" /app/healthcheck.sh || fail 'running cron failed its health check'
cron_pid=$(docker exec "$container_id" pgrep -x /usr/bin/supercronic)
docker exec "$container_id" sh -c '
    [ "$(stat -c %u /config/crontab)" = 1000 ] &&
    [ "$(date +%z)" = +0400 ] &&
    [ ! -e /app/entrypoint.sh ]
' || fail 'cron ignored a nonroot-owned file, timezone is wrong, or the startup wrapper remains'
printf '%s\n' 'PASS: direct cron entrypoint reads a nonroot-owned schedule with a read-only filesystem and runtime timezone'

printf '%s\n' '* * * * * * * printf x >> /tmp/cron-inplace' > "$fixture_dir/crontab"
wait_for_file /tmp/cron-inplace
[ "$(docker exec "$container_id" pgrep -x /usr/bin/supercronic)" = "$cron_pid" ] \
    || fail 'an in-place schedule change restarted the cron process'
printf '%s\n' 'PASS: in-place mounted-crontab edits take effect without restarting cron'

# Editors commonly save by replacing the old inode. The watcher must follow
# that replacement, rather than continuing to watch a removed crontab file.
printf '%s\n' '* * * * * * * printf x >> /tmp/cron-updated' > "$fixture_dir/crontab.new"
mv "$fixture_dir/crontab.new" "$fixture_dir/crontab"
wait_for_file /tmp/cron-updated
old_count=$(docker exec "$container_id" sh -c 'wc -c < /tmp/cron-inplace')
sleep 2
[ "$(docker exec "$container_id" sh -c 'wc -c < /tmp/cron-inplace')" = "$old_count" ] \
    || fail 'reloading the mounted schedule left the old job running'
[ "$(docker exec "$container_id" pgrep -x /usr/bin/supercronic)" = "$cron_pid" ] \
    || fail 'an atomic schedule change restarted the cron process'
printf '%s\n' 'PASS: atomic mounted-crontab replacement changes running jobs without restart or rebuild'

printf '%s\n' '* * * * * * * printf x >> /tmp/cron-after-replace' > "$fixture_dir/crontab"
wait_for_file /tmp/cron-after-replace
[ "$(docker exec "$container_id" pgrep -x /usr/bin/supercronic)" = "$cron_pid" ] \
    || fail 'a later schedule change restarted the cron process'
printf '%s\n' 'PASS: later edits remain visible after the watched crontab inode was replaced'

docker stop --time 5 "$container_id" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container_id")" = 0 ] \
    || fail 'cron did not stop cleanly on SIGTERM'
printf '%s\n' 'PASS: the cron entrypoint handles container shutdown cleanly' \
    '' '5 cron runtime checks passed.'
