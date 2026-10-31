#!/bin/sh
# Internal worker: invoke /app/push.sh so configuration, locks and timeout apply.
set -eu
umask 077
. /app/common.sh
: "${JOB_NAME:?Run this worker through /app/push.sh}"
job_dir=$(mktemp -d /tmp/location-job.XXXXXX)
trap 'rm -rf -- "$job_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$job_dir/stage"
: > "$job_dir/paths"

snapshot() {
    source_file=$1
    target_file=$2
    valid_destination "$target_file"
    [ -f "$source_file" ] || fail 'A configured source is missing or not a regular file'
    [ ! -e "$job_dir/stage/$target_file" ] || fail 'Duplicate or overlapping destination'
    mkdir -p -- "$(dirname -- "$job_dir/stage/$target_file")"
    cp -- "$source_file" "$job_dir/stage/$target_file"
    printf '%s\n' "$target_file" >> "$job_dir/paths"
}

if [ -n "$BEFORE_COMMAND" ]; then
    sh -c "$BEFORE_COMMAND"
fi
if [ "$LOCATION_MODE" = bridge ]; then
    request_id=$(cat /proc/sys/kernel/random/uuid)
    requested_at=$(date +%s)
    jq -n --arg id "$request_id" --argjson at "$requested_at" \
        '{request_id:$id,requested_at_unix:$at}' > /bridge/requests/request.json.tmp
    chmod 644 /bridge/requests/request.json.tmp
    mv -- /bridge/requests/request.json.tmp /bridge/requests/request.json
    deadline=$((requested_at + 120))
    echo 'Requesting a fresh host location.'
    while :; do
        if [ -r /bridge/responses/response.json ] && \
            jq -e --arg id "$request_id" '.request_id == $id' /bridge/responses/response.json >/dev/null 2>&1; then
            cp -- /bridge/responses/response.json "$job_dir/response.json"
            break
        fi
        [ "$(date +%s)" -lt "$deadline" ] || fail 'No response from the host location bridge'
        sleep 1
    done
    if ! jq -e --arg id "$request_id" '.request_id == $id and .status == "ok"' "$job_dir/response.json" >/dev/null; then
        jq -r '.error // "Host location request failed"' "$job_dir/response.json" >&2
        exit 1
    fi
    jq '.location' "$job_dir/response.json" > "$job_dir/raw-location.json"
elif [ "$LOCATION_MODE" = command ]; then
    sh -c "$LOCATION_COMMAND" > "$job_dir/raw-location.json"
fi
if [ "$LOCATION_MODE" != none ]; then
    jq -se --arg at "$(date -u +%FT%TZ)" '
      select(length == 1) | .[0] | select(type == "object")
      | select((.source | type) == "string" and (.source | length) > 0)
      | select((.observed_at | type) == "string")
      | select(.observed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      | select((.observed_at | fromdateiso8601) >= now - 180 and (.observed_at | fromdateiso8601) <= now + 30)
      | select((.latitude | type) == "number" and .latitude >= -90 and .latitude <= 90)
      | select((.longitude | type) == "number" and .longitude >= -180 and .longitude <= 180)
      | select((.horizontal_accuracy_m | type) == "number" and (.horizontal_accuracy_m | isfinite) and .horizontal_accuracy_m >= 0)
      | . + {recorded_at:$at}
    ' "$job_dir/raw-location.json" > "$job_dir/location.json"
    cp -- "$job_dir/location.json" /data/location.json.tmp
    chmod 644 /data/location.json.tmp
    mv -- /data/location.json.tmp /data/location.json
    snapshot "$job_dir/location.json" "$LOCATION_FILE"
fi

if [ -n "$FILES_LIST" ]; then
    [ -f "$FILES_LIST" ] || fail 'FILES_LIST is missing or not a regular file'
    tab=$(printf '\t')
    cr=$(printf '\r')
    while IFS= read -r mapping || [ -n "$mapping" ]; do
        mapping=${mapping%"$cr"}
        case "$mapping" in ''|'#'*) continue ;; esac
        case "$mapping" in *"$tab"*) ;; *) fail 'Each file mapping needs TAB-separated source and destination' ;; esac
        source_file=${mapping%%"$tab"*}
        target_file=${mapping#*"$tab"}
        case "$target_file" in *"$tab"*) fail 'A file mapping must have exactly two fields' ;; esac
        case "$source_file" in /input/*|/data/*) ;; *) fail 'File sources must be under /input or /data' ;; esac
        resolved_source=$(realpath -e -- "$source_file")
        case "$resolved_source" in /input/*|/data/*) ;; *) fail 'File source resolves outside /input and /data' ;; esac
        snapshot "$resolved_source" "$target_file"
    done < "$FILES_LIST"
fi
[ -s "$job_dir/paths" ] || exit 0
[ -n "$GIT_URL" ] || fail 'Set GIT_URL in /config/settings.sh'
git check-ref-format "refs/heads/$GIT_BRANCH" >/dev/null
git init -q -b "$GIT_BRANCH" "$job_dir/repository"
cd "$job_dir/repository"
git config user.name "$GIT_AUTHOR_NAME"
git config user.email "$GIT_AUTHOR_EMAIL"
git config core.hooksPath /dev/null
git remote add -- origin "$GIT_URL"

apply_snapshot() {
    while IFS= read -r target_file; do
        remaining=$target_file
        parent=$job_dir/repository
        while case "$remaining" in */*) true ;; *) false ;; esac; do
            component=${remaining%%/*}
            remaining=${remaining#*/}
            parent=$parent/$component
            [ ! -L "$parent" ] || fail 'Remote destination parent is a symlink'
            mkdir -p -- "$parent"
        done
        target=$job_dir/repository/$target_file
        if [ -L "$target" ]; then rm -f -- "$target"; fi
        [ ! -d "$target" ] || fail 'Remote destination is a directory'
        cp -- "$job_dir/stage/$target_file" "$target"
        git --literal-pathspecs add -f -- "$target_file"
    done < "$job_dir/paths"
}

attempt=1
while [ "$attempt" -le 3 ]; do
    # Nested timeouts stay in the outer worker process group, so its deadline
    # also stops any outstanding Git transport processes.
    if timeout --foreground --kill-after=5 40 git fetch -q --prune origin; then
        if git show-ref --verify --quiet "refs/remotes/origin/$GIT_BRANCH"; then
            git checkout -q -B "$GIT_BRANCH" "refs/remotes/origin/$GIT_BRANCH"
        fi
        apply_snapshot
        if ! git diff --cached --quiet; then
            git commit -q -m "Update $JOB_NAME $(date -u +%FT%TZ)"
        fi
        if timeout --foreground --kill-after=5 40 git push -q origin "HEAD:refs/heads/$GIT_BRANCH"; then
            printf 'Pushed configured files (commit %s).\n' "$(git rev-parse --short HEAD)"
            exit 0
        fi
    fi
    printf 'Git attempt %s failed.\n' "$attempt" >&2
    attempt=$((attempt + 1))
    if [ "$attempt" -le 3 ]; then sleep 5; fi
done
exit 1
