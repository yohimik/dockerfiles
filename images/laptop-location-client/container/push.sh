#!/bin/sh
set -eu
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=common.sh
. /app/common.sh
[ "$#" -le 1 ] || fail 'Usage: /app/push.sh [/config/jobs/name.sh]'
# Convenience for a manual one-job capture and push; cron passes no argument.
if [ "$#" -eq 1 ]; then /app/commit.sh "$1"; fi
load_settings
mkdir -p /data/status
exec 9>/data/update.lock
flock -w 3600 9 || fail 'Push timed out waiting for the repository lock'
prepare_ssh
if timeout --kill-after=5 "$PUSH_TIMEOUT_SECONDS" /app/publish-commits.sh 9>&-; then
    code=0
else
    code=$?
fi
jq -n --argjson code "$code" --arg at "$(date -u +%FT%TZ)" \
    '{exit_code:$code,finished_at:$at}' > /data/status/push.json.tmp
mv -- /data/status/push.json.tmp /data/status/push.json
exit "$code"
