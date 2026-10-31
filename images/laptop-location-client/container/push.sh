#!/bin/sh
set -eu
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=common.sh
. /app/common.sh
[ "$#" -eq 1 ] || fail 'Usage: /app/push.sh /config/jobs/name.sh'
load_settings
load_job "$1"
mkdir -p /data/status
exec 8>"/data/status/$JOB_NAME.lock"
if ! flock -n 8; then
    printf 'Job %s is already running or queued; skipping.\n' "$JOB_NAME"
    exit 0
fi
exec 9>/data/update.lock
if ! flock -w 3600 9; then
    fail "Job $JOB_NAME timed out waiting for another job"
fi
prepare_ssh
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s Starting %s.\n' "$(date -u +%FT%TZ)" "$JOB_NAME"
# Only this parent holds locks; commands and their descendants cannot retain them.
if timeout --kill-after=5 "$TIMEOUT_SECONDS" /app/publish.sh 8>&- 9>&-; then
    code=0
else
    code=$?
fi
jq -n --arg job "$JOB_NAME" --argjson code "$code" --arg at "$(date -u +%FT%TZ)" \
    '{job:$job,exit_code:$code,finished_at:$at}' > "/data/status/$JOB_NAME.json.tmp"
chmod 644 "/data/status/$JOB_NAME.json.tmp"
mv -- "/data/status/$JOB_NAME.json.tmp" "/data/status/$JOB_NAME.json"
printf '%s Job %s finished (exit %s).\n' "$(date -u +%FT%TZ)" "$JOB_NAME" "$code"
exit "$code"
