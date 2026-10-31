#!/bin/sh
fail() { printf '%s\n' "$*" >&2; exit 1; }
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

load_settings() {
    GITHUB_REPOSITORY=''
    INACTIVITY_DAYS=30
    TZ=Etc/UTC
    [ -r /config/settings.sh ] || fail 'Missing /config/settings.sh'
    # This is trusted, executable shell configuration, like the client settings.
    # shellcheck source=/dev/null
    . /config/settings.sh
    owner=${GITHUB_REPOSITORY%%/*}
    repository=${GITHUB_REPOSITORY#*/}
    case "$owner" in ''|*[!A-Za-z0-9-]*|-*|*-) fail 'Invalid GitHub owner' ;; esac
    case "$repository" in ''|.|..|*[!A-Za-z0-9_.-]*) fail 'Invalid GitHub repository name' ;; esac
    [ "$owner/$repository" = "$GITHUB_REPOSITORY" ] || fail 'Use GITHUB_REPOSITORY=OWNER/REPOSITORY'
    [ "${#owner}" -le 39 ] && [ "${#repository}" -le 100 ] || fail 'GitHub repository name is too long'
    case "$INACTIVITY_DAYS" in ''|0*|*[!0-9]*) fail 'INACTIVITY_DAYS must be a positive integer without leading zeros' ;; esac
    [ "${#INACTIVITY_DAYS}" -le 5 ] && [ "$INACTIVITY_DAYS" -le 36500 ] || fail 'INACTIVITY_DAYS must be 1 through 36500'
    case "$TZ" in ''|/*|*..*|*\\*) fail 'Invalid timezone' ;; esac
    [ -f "/usr/share/zoneinfo/$TZ" ] || fail 'Unknown timezone'
    export GITHUB_REPOSITORY INACTIVITY_DAYS TZ
}

is_completed() {
    [ -e /data/completed.json ] || return 1
    jq -e 'type == "object" and (.repository | type == "string")
        and (.repository_id | type == "number") and (.completed_at | type == "string")' \
        /data/completed.json >/dev/null || fail 'Invalid /data/completed.json; inspect it before restarting'
    jq -e --arg repository "$GITHUB_REPOSITORY" \
        '(.repository | ascii_downcase) == ($repository | ascii_downcase)' \
        /data/completed.json >/dev/null
}

remove_schedule() {
    if [ -f /tmp/crontabs/root ]; then
        # Use crontab so BusyBox notifies the running daemon of the removal.
        crontab -c /tmp/crontabs -r
    fi
}
