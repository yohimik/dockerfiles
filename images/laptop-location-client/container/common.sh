#!/bin/sh
# Global settings are shell-compatible KEY=value assignments; jobs are trusted shell code.
fail() { printf '%s\n' "$*" >&2; exit 1; }

load_settings() {
    GIT_URL=''
    GIT_BRANCH=main
    GIT_AUTHOR_NAME='Laptop Location Client'
    GIT_AUTHOR_EMAIL=location-client@localhost
    TZ=Etc/UTC
    [ -r /config/settings.sh ] || fail 'Missing /config/settings.sh'
    # shellcheck source=/dev/null
    . /config/settings.sh
    case "$TZ" in ''|/*|*..*|*\\*) fail 'Invalid timezone' ;; esac
    [ -f "/usr/share/zoneinfo/$TZ" ] || fail 'Unknown timezone'
    export GIT_URL GIT_BRANCH GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL TZ
    export GIT_TERMINAL_PROMPT=0
    export GIT_SSH_COMMAND='ssh -F /app/ssh_config'
}

prepare_ssh() {
    # Called while holding the shared publishing lock, so jobs never rotate
    # credentials underneath another Git transport. Windows bind permissions
    # need not satisfy OpenSSH: the private working copies are always 0600.
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    for name in id_ed25519 known_hosts; do
        if [ -f "/credentials/$name" ]; then
            cp -- "/credentials/$name" "/root/.ssh/$name.tmp"
            chmod 600 "/root/.ssh/$name.tmp"
            mv -- "/root/.ssh/$name.tmp" "/root/.ssh/$name"
        else
            rm -f -- "/root/.ssh/$name" "/root/.ssh/$name.tmp"
        fi
    done
}

valid_destination() {
    printf '%s' "$1" | jq -eRs '
      length > 0 and (startswith("/") | not) and (contains("\\") | not)
      and (explode | all(. >= 32 and . != 127))
      and (split("/") | all(length > 0 and . != "." and . != ".." and ascii_downcase != ".git"))
    ' >/dev/null || fail 'Destination must be a safe relative filename'
}

load_job() {
    case "$1" in /config/jobs/*.sh) ;; *) fail 'Job must be a shell file under /config/jobs/' ;; esac
    job_path=$(realpath -e -- "$1")
    case "$job_path" in /config/jobs/*) ;; *) fail 'Job resolves outside /config/jobs/' ;; esac
    [ -f "$job_path" ] || fail 'Job configuration is not a regular file'
    JOB_NAME=''
    LOCATION_MODE=none
    LOCATION_FILE=location.json
    LOCATION_COMMAND=''
    FILES_LIST=''
    BEFORE_COMMAND=''
    TIMEOUT_SECONDS=300
    # shellcheck source=/dev/null
    . "$job_path"
    case "$JOB_NAME" in ''|*[!A-Za-z0-9_-]*) fail 'Set JOB_NAME using letters, digits, _ or -' ;; esac
    [ "${#JOB_NAME}" -le 64 ] || fail 'JOB_NAME is too long'
    case "$LOCATION_MODE" in bridge|command|none) ;; *) fail 'Invalid LOCATION_MODE' ;; esac
    case "$TIMEOUT_SECONDS" in ''|*[!0-9]*) fail 'TIMEOUT_SECONDS must be an integer' ;; esac
    [ "${#TIMEOUT_SECONDS}" -le 4 ] && [ "$TIMEOUT_SECONDS" -ge 5 ] && [ "$TIMEOUT_SECONDS" -le 3600 ] || fail 'TIMEOUT_SECONDS must be 5 through 3600'
    valid_destination "$LOCATION_FILE"
    if [ "$LOCATION_MODE" = command ]; then
        [ -n "$LOCATION_COMMAND" ] || fail 'Set LOCATION_COMMAND for command location mode'
    fi
    export JOB_NAME LOCATION_MODE LOCATION_FILE LOCATION_COMMAND FILES_LIST BEFORE_COMMAND TIMEOUT_SECONDS
    export GIT_URL GIT_BRANCH GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL TZ
}
