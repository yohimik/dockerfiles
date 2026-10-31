#!/bin/sh
set -eu
umask 077
. /app/common.sh
load_settings
mkdir -p /root/.ssh /tmp/crontabs /data/status
for name in id_ed25519 known_hosts; do
    if [ -f "/credentials/$name" ]; then
        cp -- "/credentials/$name" "/root/.ssh/$name"
        chmod 600 "/root/.ssh/$name"
    fi
done
cat > /root/.ssh/config <<'EOF'
Host *
    IdentityFile /root/.ssh/id_ed25519
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking yes
    UserKnownHostsFile /root/.ssh/known_hosts
    ConnectTimeout 15
    ServerAliveInterval 10
    ServerAliveCountMax 2
EOF
chmod 600 /root/.ssh/config
[ -r /config/crontab ] || fail 'Missing /config/crontab'
# Preserve a plain user crontab; schedules must use BusyBox numeric syntax.
cp -- /config/crontab /tmp/crontabs/root
chmod 600 /tmp/crontabs/root
printf 'Starting cron (timezone: %s).\n' "$TZ"
exec crond -f -c /tmp/crontabs -l 8 -L /dev/stdout
