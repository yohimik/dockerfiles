#!/bin/sh
# Separate local commits from real local Git pushes; never use the network.
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
fixture=/tmp/file-conflict-test
remote=$fixture/remote.git
seed=$fixture/seed
local_repository=/data/repository
passed=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$fixture/job.log" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$*"; }
trap 'rm -f /usr/local/bin/git' EXIT

# Delegate to real Git, optionally advancing a local bare remote immediately
# before publication. The resulting non-fast-forward rejection is real.
cat > /usr/local/bin/git <<'SHIM'
#!/bin/sh
set -eu
fixture=/tmp/file-conflict-test
is_client_push=false
push_directory=$PWD
git_command=${1:-}
if [ "$git_command" = -C ]; then
    push_directory=$2
    git_command=${3:-}
fi
if [ "$git_command" = push ]; then
    for argument do
        if [ "$argument" = origin ]; then is_client_push=true; fi
    done
fi
if [ "$is_client_push" = false ]; then exec /usr/bin/git "$@"; fi
attempt=$(cat "$fixture/pushes")
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$fixture/pushes"
/usr/bin/git -C "$push_directory" ls-tree -r --name-only HEAD > "$fixture/attempt-$attempt.files"
if [ "$attempt" = 1 ] && [ -f "$fixture/reject-once" ]; then
    printf '%s\n' 'Simulated transport rejection without a remote change.' >&2
    exit 1
fi
if [ -f "$fixture/race-$attempt" ]; then
    /usr/bin/git --git-dir "$fixture/remote.git" update-ref refs/heads/main "$(cat "$fixture/race-$attempt")"
fi
if /usr/bin/git "$@"; then
    if [ "$attempt" = 1 ] && [ -f "$fixture/lose-ack" ]; then
        printf '%s\n' 'Simulated lost acknowledgment after successful local push.' >&2
        exit 1
    fi
    exit 0
else
    exit $?
fi
SHIM
chmod 755 /usr/local/bin/git

reset_case() {
    for directory in /config /jobs /input /credentials /data /deployment; do
        find "$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- '{}' +
    done
    rm -rf "$fixture"
    mkdir -p "$fixture"
    cp -R /defaults/config/. /config/
    cp -R /defaults/jobs/. /jobs/
    cp /defaults/compose.yaml /defaults/Dockerfile /deployment/
    cat >> /config/settings.sh <<'SETTINGS'
GIT_URL='/tmp/file-conflict-test/remote.git'
GIT_BRANCH='main'
GIT_AUTHOR_NAME='Conflict Test'
GIT_AUTHOR_EMAIL='conflict-test@localhost'
REPOSITORY_DIR='/data/repository'
PUSH_TIMEOUT_SECONDS=30
SETTINGS
    cat > /config/jobs/conflicts.sh <<'JOB'
JOB_NAME='conflicts'
LOCATION_MODE='none'
FILES_LIST='/config/conflicts.tsv'
BEFORE_COMMAND=''
TIMEOUT_SECONDS=60
JOB
    printf '%s\n' '{"model_name":"MacBook Pro"}' > /config/device.json
    printf '/input/report.json\treport.json\n/input/notes.txt\tnotes.txt\n' > /config/conflicts.tsv
    printf '%s\n' 'committed report' > /input/report.json
    printf '%s\n' 'committed notes' > /input/notes.txt
    git init -q --bare -b main "$remote"
    git init -q -b main "$seed"
    git -C "$seed" config user.name 'Conflict Test'
    git -C "$seed" config user.email 'conflict-test@localhost'
    printf '%s\n' 'keep existing content' > "$seed/keep.txt"
    git -C "$seed" add .
    git -C "$seed" commit -qm baseline
    git -C "$seed" push -q "$remote" HEAD:refs/heads/main
    printf '%s\n' 0 > "$fixture/pushes"
    : > "$fixture/job.log"
}

race_commit() {
    git -C "$seed" add -A
    git -C "$seed" commit -qm "Competing update $1"
    git -C "$seed" rev-parse HEAD > "$fixture/race-$1"
    git -C "$seed" push -q "$remote" "HEAD:refs/test-races/$1"
}
commit_files() {
    /app/commit.sh /config/jobs/conflicts.sh > "$fixture/job.log" 2>&1 \
        || fail 'local file capture and commit unexpectedly failed'
}
publish() {
    /app/push.sh > "$fixture/job.log" 2>&1 || fail 'publishing pending committed files unexpectedly failed'
}
assert_content() {
    actual=$(git --git-dir "$remote" show "main:$1") || fail "missing remote file $1"
    [ "$actual" = "$2" ] || fail "wrong remote content at $1"
}
assert_absent() {
    if git --git-dir "$remote" cat-file -e "main:$1" 2>/dev/null; then
        fail "unexpected remote file $1"
    fi
}

reset_case
remote_head=$(git --git-dir "$remote" rev-parse refs/heads/main)
mkdir -p "$local_repository"
printf '%s\n' 'user-added file' > "$local_repository/extra.txt"
printf '%s\n' '*.secret' > "$local_repository/.gitignore"
printf '%s\n' 'must stay ignored' > "$local_repository/private.secret"
# A nonexistent destination proves the local commit job needs no remote access.
printf '\nGIT_URL="/tmp/nonexistent-conflict-remote.git"\n' >> /config/settings.sh
commit_files
[ "$(git -C "$local_repository" show HEAD:report.json)" = 'committed report' ] || fail 'capture was not committed locally'
[ "$(git -C "$local_repository" show HEAD:extra.txt)" = 'user-added file' ] || fail 'local commit omitted user-added repository files'
[ "$(git -C "$local_repository" show HEAD:.gitignore)" = '*.secret' ] || fail 'local commit omitted .gitignore'
if git -C "$local_repository" cat-file -e HEAD:private.secret 2>/dev/null; then fail 'local commit ignored .gitignore'; fi
[ "$(git --git-dir "$remote" rev-parse refs/heads/main)" = "$remote_head" ] || fail 'commit job changed the remote'
[ "$(cat "$fixture/pushes")" = 0 ] || fail 'commit job attempted a push'
pass 'the commit job captures files and commits all nonignored repository files without remote access'

reset_case
commit_files
local_head=$(git -C "$local_repository" rev-parse HEAD)
printf '%s\n' 'uncommitted report' > "$local_repository/report.json"
printf '%s\n' 'not committed yet' > "$local_repository/extra.txt"
publish
assert_content report-MacBook-Pro-1.json 'committed report'
assert_content notes-MacBook-Pro-1.txt 'committed notes'
assert_content keep.txt 'keep existing content'
assert_absent extra-MacBook-Pro-1.txt
assert_absent report.json
[ "$(cat "$local_repository/report.json")" = 'uncommitted report' ] || fail 'push changed the local worktree'
[ "$(git -C "$local_repository" rev-parse HEAD)" = "$local_head" ] || fail 'push made a local capture commit'
printf '%s\n' 'second committed report' > /input/report.json
commit_files
publish
assert_content report-MacBook-Pro-1.json 'committed report'
assert_content report-MacBook-Pro-2.json 'second committed report'
assert_content extra-MacBook-Pro-2.txt 'not committed yet'
assert_absent notes-MacBook-Pro-2.txt
pass 'push publishes only committed changes, retains earlier attempt filenames, and increments its next invocation'

reset_case
commit_files
printf '%s\n' 'remote competitor' > "$seed/report-MacBook-Pro-1.json"
race_commit 1
if /app/push.sh > "$fixture/job.log" 2>&1; then
    fail 'a partial publication did not report pending conflicts'
fi
assert_content report-MacBook-Pro-1.json 'remote competitor'
assert_content notes-MacBook-Pro-1.txt 'committed notes'
assert_absent report-MacBook-Pro-2.json
[ "$(cat "$fixture/pushes")" = 2 ] || fail 'partial publication did not retry after the rejected push'
grep -Fxq report-MacBook-Pro-1.json "$fixture/attempt-1.files" || fail 'initial push did not try its normal attempt filename'
local_head=$(git -C "$local_repository" rev-parse HEAD)
publish
assert_content report-MacBook-Pro-1.json 'remote competitor'
assert_content report-MacBook-Pro-2.json 'committed report'
assert_absent notes-MacBook-Pro-2.txt
[ "$(git -C "$local_repository" rev-parse HEAD)" = "$local_head" ] || fail 'retry unexpectedly recaptured files'
pass 'a rejected overlapping push publishes nonconflicting files and keeps only the conflict pending for attempt two'

reset_case
printf '%s\n' 'another device already used this name' > "$seed/report-MacBook-Pro-1.json"
git -C "$seed" add .
git -C "$seed" commit -qm 'Existing occupied publication name'
git -C "$seed" push -q "$remote" HEAD:refs/heads/main
commit_files
if /app/push.sh > "$fixture/job.log" 2>&1; then
    fail 'an occupied attempt filename did not remain pending'
fi
assert_content report-MacBook-Pro-1.json 'another device already used this name'
assert_content notes-MacBook-Pro-1.txt 'committed notes'
publish
assert_content report-MacBook-Pro-2.json 'committed report'
assert_absent notes-MacBook-Pro-2.txt
pass 'an existing publication filename is preserved and only its pending source retries under the next counter'

reset_case
commit_files
touch "$fixture/reject-once"
publish
assert_content report-MacBook-Pro-1.json 'committed report'
assert_content notes-MacBook-Pro-1.txt 'committed notes'
assert_absent report-MacBook-Pro-2.json
[ "$(cat "$fixture/pushes")" = 2 ] || fail 'transport failure did not retry'
pass 'a transient push failure retries the same invocation counter without inventing conflicts'

reset_case
commit_files
touch "$fixture/lose-ack"
publish
assert_content report-MacBook-Pro-1.json 'committed report'
assert_content notes-MacBook-Pro-1.txt 'committed notes'
publish
assert_absent report-MacBook-Pro-2.json
assert_absent notes-MacBook-Pro-2.txt
pass 'a successful push with a lost acknowledgment does not leave already-published files pending'

reset_case
long_prefix=$(printf '%245s' '' | tr ' ' a)
long_source_a=${long_prefix}a.txt
long_source_b=${long_prefix}b.txt
printf '/input/report.json\t%s\n/input/notes.txt\t%s\n' "$long_source_a" "$long_source_b" > /config/conflicts.tsv
printf '%s\n' 'identical long-name content' > /input/report.json
cp /input/report.json /input/notes.txt
commit_files
touch "$fixture/lose-ack"
if /app/push.sh > "$fixture/job.log" 2>&1; then
    fail 'a truncated filename alias was incorrectly confirmed after a lost acknowledgment'
fi
git --git-dir "$remote" ls-tree -r --name-only main > "$fixture/remote-files"
first_target=$(grep -- '-MacBook-Pro-1\.txt$' "$fixture/remote-files")
[ "$(printf '%s\n' "$first_target" | wc -l)" -eq 1 ] || fail 'first attempt did not publish exactly one truncated target'
[ "$(printf '%s' "$first_target" | wc -c)" -le 255 ] || fail 'generated filename exceeded the filesystem limit'
assert_content "$first_target" 'identical long-name content'
publish
second_target=${first_target%-1.txt}-2.txt
assert_content "$first_target" 'identical long-name content'
assert_content "$second_target" 'identical long-name content'
pass 'colliding truncated names remain separately pending after a lost acknowledgment and publish on the next attempt'

reset_case
commit_files
printf '%s\n' 'committed report' > "$seed/report-MacBook-Pro-1.json"
race_commit 1
publish
assert_content report-MacBook-Pro-1.json 'committed report'
assert_content notes-MacBook-Pro-1.txt 'committed notes'
publish
assert_absent report-MacBook-Pro-2.json
assert_absent notes-MacBook-Pro-2.txt
pass 'identical concurrent contents are accepted without leaving a false conflict pending'

reset_case
git --git-dir "$remote" update-ref -d refs/heads/main
commit_files
publish
assert_content report-MacBook-Pro-1.json 'committed report'
assert_content notes-MacBook-Pro-1.txt 'committed notes'
pass 'the first push can create an empty destination branch'

reset_case
printf '%s\n' '{}' > /config/device.json
commit_files
publish
assert_content report-device-1.json 'committed report'
assert_content notes-device-1.txt 'committed notes'
pass 'an unavailable model name uses a safe device suffix'

reset_case
printf '%s\n' '{"model_name":""}' > /config/custom-device.json
printf '%s\n' '{"model_name":"ThinkPad / X1..Carbon"}' > /input/custom-host.json
cat >> /config/device-report.sh <<'MODEL'
DEVICE_INFO_FILE='/config/custom-device.json'
HOST_INFO_FILE='/input/custom-host.json'
MODEL
commit_files
publish
assert_content report-ThinkPad-X1-Carbon-1.json 'committed report'
pass 'custom device metadata paths and host fallback produce a filename-safe model suffix'

reset_case
printf '/input/report.json\tarchive.tar.gz\n/input/notes.txt\t.env\n' > /config/conflicts.tsv
commit_files
publish
assert_content archive.tar-MacBook-Pro-1.gz 'committed report'
assert_content .env-MacBook-Pro-1 'committed notes'
pass 'model and attempt preserve the last extension and handle dotfiles'

printf '\n%s commit/push conflict checks passed.\n' "$passed"
