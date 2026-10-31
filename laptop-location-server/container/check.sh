#!/bin/sh
set -eu
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=common.sh
. /app/common.sh
load_settings
mkdir -p /data
exec 9>/data/check.lock
if ! flock -n 9; then
    log 'Another check is running; skipping.'
    exit 0
fi
if is_completed; then
    remove_schedule
    log "Already completed for $GITHUB_REPOSITORY."
    exit 0
fi

work_dir=$(mktemp -d /tmp/repository-check.XXXXXX)
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
[ -r /credentials/github_token ] || fail 'Missing /credentials/github_token'
token=$(cat /credentials/github_token)
case "$token" in ''|*[!A-Za-z0-9_]*) fail 'github_token must contain one GitHub API token' ;; esac
# Keep the token out of curl arguments and logs.
printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2026-03-10\n' \
    "$token" > "$work_dir/headers"
unset token
endpoint="https://api.github.com/repos/$GITHUB_REPOSITORY"

request() {
    curl --fail --silent --show-error --proto '=https' \
        --connect-timeout 15 --max-time 60 --header "@$work_dir/headers" \
        --output "$work_dir/repository.json" "$@" "$endpoint" \
        || fail 'GitHub API request failed; daily job retained'
    # Do not follow redirects: a rename/transfer needs an explicit config update.
    jq -e --arg repository "$GITHUB_REPOSITORY" '
        type == "object"
        and (.id | type == "number" and . > 0 and . == floor)
        and (.full_name | type == "string")
        and ((.full_name | ascii_downcase) == ($repository | ascii_downcase))
        and (.private | type == "boolean")
        and ((.visibility == "public" and .private == false)
             or ((.visibility == "private" or .visibility == "internal") and .private == true))
    ' "$work_dir/repository.json" >/dev/null || fail 'Unexpected GitHub repository response; daily job retained'
}

mark_completed() {
    jq -n --arg repository "$GITHUB_REPOSITORY" \
        --argjson id "$(jq -r '.id' "$work_dir/repository.json")" \
        --arg at "$(date -u +%FT%TZ)" \
        '{repository:$repository,repository_id:$id,completed_at:$at}' > /data/completed.json.tmp
    mv -- /data/completed.json.tmp /data/completed.json
    remove_schedule
    log "$GITHUB_REPOSITORY is public; daily cron job removed."
}

is_public() {
    jq -e '.visibility == "public" and .private == false' "$work_dir/repository.json" >/dev/null
}

is_inactive() {
    pushed_at=$(jq -er '.pushed_at | strings | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
        "$work_dir/repository.json") || fail 'Missing or invalid pushed_at; daily job retained'
    pushed_epoch=$(date -u -d "$pushed_at" +%s) || fail 'Invalid pushed_at date; daily job retained'
    now=$(date -u +%s)
    [ "$pushed_epoch" -le "$now" ] || fail 'pushed_at is in the future; daily job retained'
    age=$((now - pushed_epoch))
    if [ "$age" -le "$((INACTIVITY_DAYS * 86400))" ]; then
        log "$GITHUB_REPOSITORY last pushed at $pushed_at; within $INACTIVITY_DAYS days."
        return 1
    fi
}

request --request GET
if is_public; then mark_completed; exit 0; fi
if ! is_inactive; then exit 0; fi
repository_id=$(jq -r '.id' "$work_dir/repository.json")
# Recheck immediately before the change in case a push arrived during this run.
# GitHub has no atomic 'publish only if pushed_at is unchanged' API.
request --request GET
[ "$(jq -r '.id' "$work_dir/repository.json")" = "$repository_id" ] \
    || fail 'Repository identity changed during the check; daily job retained'
if is_public; then mark_completed; exit 0; fi
if ! is_inactive; then exit 0; fi
log "$GITHUB_REPOSITORY last pushed at $pushed_at, more than $INACTIVITY_DAYS days ago; making it public."
request --request PATCH --header 'Content-Type: application/json' --data '{"visibility":"public"}'
[ "$(jq -r '.id' "$work_dir/repository.json")" = "$repository_id" ] \
    || fail 'Repository identity changed in the update response; daily job retained'
is_public || fail 'GitHub did not confirm public visibility; daily job retained'
mark_completed
