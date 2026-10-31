#!/bin/sh
set -eu
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=common.sh
. /app/common.sh
load_settings
mkdir -p /tmp/crontabs /data
chmod 700 /tmp/crontabs
if is_completed; then
    remove_schedule
    log "Already completed for $GITHUB_REPOSITORY; daily job stays removed."
else
    [ -s /credentials/github_token ] || fail 'Provide /credentials/github_token with repository administration access'
    [ -r /config/crontab ] || fail 'Missing /config/crontab'
    crontab -c /tmp/crontabs /config/crontab
    log "Starting daily checks for $GITHUB_REPOSITORY (timezone: $TZ)."
fi
exec crond -f -c /tmp/crontabs -l 8 -L /dev/stdout
