#!/bin/sh
set -eu
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=common.sh
. /app/common.sh
[ "$#" -le 1 ] || fail 'Usage: /app/commit.sh [/config/jobs/name.sh]'
load_settings
mkdir -p /data/status
exec 9>/data/update.lock
flock -w 3600 9 || fail 'Commit timed out waiting for the repository lock'
prepare_repository
job_list=$(mktemp /tmp/commit-jobs.XXXXXX)
trap 'rm -f -- "$job_list"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$#" -eq 1 ]; then
    printf '%s\n' "$1" > "$job_list"
else
    [ -f "$COMMIT_JOBS_FILE" ] || fail 'Missing COMMIT_JOBS_FILE'
    cp -- "$COMMIT_JOBS_FILE" "$job_list"
fi
result=0
cr=$(printf '\r')
while IFS= read -r job || [ -n "$job" ]; do
    job=${job%"$cr"}
    case "$job" in ''|'#'*) continue ;; esac
    load_job "$job"
    printf '%s Capturing %s.\n' "$(date -u +%FT%TZ)" "$JOB_NAME"
    if timeout --kill-after=5 "$TIMEOUT_SECONDS" /app/capture.sh 9>&-; then
        code=0
    else
        code=$?
        result=1
    fi
    jq -n --arg job "$JOB_NAME" --argjson code "$code" --arg at "$(date -u +%FT%TZ)" \
        '{job:$job,exit_code:$code,finished_at:$at}' > "/data/status/$JOB_NAME.json.tmp"
    mv -- "/data/status/$JOB_NAME.json.tmp" "/data/status/$JOB_NAME.json"
    printf '%s Capture %s finished (exit %s).\n' "$(date -u +%FT%TZ)" "$JOB_NAME" "$code"
done < "$job_list"

# Include manually added/generated files, modifications, and deletions.
# Git ignore rules still apply. No fetch, pull, or push happens in this job.
git -C "$REPOSITORY_DIR" --literal-pathspecs add -A -- .
if ! git -C "$REPOSITORY_DIR" diff --cached --quiet; then
    git -C "$REPOSITORY_DIR" commit -q -m "Capture files $(date -u +%FT%TZ)"
    printf 'Committed repository files (%s).\n' "$(git -C "$REPOSITORY_DIR" rev-parse --short HEAD)"
else
    printf '%s\n' 'No file changes to commit.'
fi
exit "$result"
