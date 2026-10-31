#!/bin/sh
# Internal push worker. The caller holds the shared commit/push lock.
set -eu
umask 077
# shellcheck source=common.sh
. /app/common.sh
# shellcheck source=filenames.sh
. /app/filenames.sh
: "${REPOSITORY_DIR:?Run this worker through /app/push.sh}"
[ -n "$GIT_URL" ] || fail 'Set GIT_URL in /config/settings.sh'
git check-ref-format "refs/heads/$GIT_BRANCH" >/dev/null
if ! source_head=$(git -C "$REPOSITORY_DIR" rev-parse --verify HEAD 2>/dev/null); then
    printf '%s\n' 'No local commit to publish.'
    exit 0
fi
git_dir=$(git -C "$REPOSITORY_DIR" rev-parse --absolute-git-dir)
scope=$(printf '%s\000%s' "$GIT_URL" "$GIT_BRANCH" | sha256sum | cut -d ' ' -f 1)
state_dir="$git_dir/client-publish/$scope"
mkdir -p "$state_dir"
state_file="$state_dir/state.json"
journal_file="$state_dir/pending.json"
work_dir=$(mktemp -d /tmp/client-push.XXXXXX)
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -e "$state_file" ]; then
    jq -e 'type == "object" and (.attempt | type == "number" and . >= 0 and . < 2147483647 and . == floor)
        and (.published | type == "object")
        and (.published | all(type == "object" and (.mode == "100644" or .mode == "100755")
            and (.blob | type == "string" and test("^[0-9a-f]{40,64}$"))))' \
        "$state_file" >/dev/null || fail 'Invalid publication state; inspect the repository Git metadata'
    cp -- "$state_file" "$work_dir/state.json"
else
    printf '{"attempt":0,"published":{}}\n' > "$work_dir/state.json"
fi

save_state() {
    state_tmp=$(mktemp "$state_dir/.state.XXXXXX")
    cp -- "$work_dir/state.json" "$state_tmp"
    mv -- "$state_tmp" "$state_file"
}

confirm_files() {
    [ "$(jq length "$1")" -gt 0 ] || return 0
    jq --slurpfile confirmed "$1" 'reduce $confirmed[0][] as $file (.;
        .published[$file.path] = {blob:$file.blob,mode:$file.mode})' \
        "$work_dir/state.json" > "$work_dir/state.next"
    mv -- "$work_dir/state.next" "$work_dir/state.json"
    save_state
}

# NUL-delimited tree output keeps spaces and unusual filenames intact until
# validation. Only committed regular files are published, never working files.
git -C "$REPOSITORY_DIR" ls-tree -rz --full-tree "$source_head" > "$work_dir/tree"
jq -Rs 'split("\u0000") | map(select(length > 0)
    | capture("^(?<mode>[0-7]+) (?<type>[^ ]+) (?<blob>[0-9a-f]+)\t(?<path>[\\s\\S]*)$"))
    | map(select(.mode == "100644" or .mode == "100755"))' \
    "$work_dir/tree" > "$work_dir/source.json"

pending_files() {
    jq --slurpfile state "$work_dir/state.json" '[.[] | select(
        $state[0].published[.path] != {blob:.blob,mode:.mode})]' "$work_dir/source.json"
}
pending_files > "$work_dir/pending.json"
if [ "$(jq length "$work_dir/pending.json")" -eq 0 ] && [ ! -e "$journal_file" ]; then
    printf '%s\n' 'No committed file changes to publish.'
    exit 0
fi

attempt=$(jq -r '.attempt + 1' "$work_dir/state.json")
jq --argjson attempt "$attempt" '.attempt = $attempt' "$work_dir/state.json" > "$work_dir/state.next"
mv -- "$work_dir/state.next" "$work_dir/state.json"
save_state
model=$(device_model_slug)
printf 'Publishing committed files (model %s, attempt %s).\n' "$model" "$attempt"

tree_entry() {
    [ -n "$remote_head" ] || return 0
    git -C "$remote_dir" --literal-pathspecs ls-tree \
        --format='%(objectmode) %(objecttype) %(objectname)' "$remote_head" -- "$1"
}

fetch_checkout() {
    remote_dir="$work_dir/remote-$1"
    mkdir "$remote_dir" || fail 'Cannot prepare publication checkout'
    git init -q -b "$GIT_BRANCH" "$remote_dir" || fail 'Cannot initialize publication checkout'
    git -C "$remote_dir" config user.name "$GIT_AUTHOR_NAME" || fail 'Cannot configure Git author'
    git -C "$remote_dir" config user.email "$GIT_AUTHOR_EMAIL" || fail 'Cannot configure Git author'
    git -C "$remote_dir" config core.hooksPath /dev/null || fail 'Cannot disable publication hooks'
    git -C "$remote_dir" config core.fileMode true || fail 'Cannot configure file modes'
    # Preserve committed bytes independently of attributes in the destination.
    printf '* -text -filter -ident -working-tree-encoding\n' > "$remote_dir/.git/info/attributes"
    git -C "$remote_dir" remote add -- origin "$GIT_URL" || fail 'Cannot configure publication remote'
    if ! timeout --foreground --kill-after=5 40 git -C "$remote_dir" fetch -q --prune origin; then
        return 1
    fi
    remote_head=$(git -C "$remote_dir" rev-parse --verify "refs/remotes/origin/$GIT_BRANCH" 2>/dev/null || :)
    if [ -n "$remote_head" ]; then
        git -C "$remote_dir" checkout -q -B "$GIT_BRANCH" "$remote_head" || fail 'Cannot check out the remote branch'
    fi
}

recover_journal() {
    [ -e "$journal_file" ] || return 0
    jq -e 'type == "object" and (.commit | type == "string" and test("^[0-9a-f]{40,64}$"))
        and (.files | type == "array" and all(type == "object"
            and (.path | type == "string") and (.target | type == "string")
            and (.mode == "100644" or .mode == "100755")
            and (.blob | type == "string" and test("^[0-9a-f]{40,64}$"))))' \
        "$journal_file" >/dev/null || fail 'Invalid pending publication journal'
    journal_commit=$(jq -r '.commit' "$journal_file")
    if [ -n "$remote_head" ] && git -C "$remote_dir" merge-base --is-ancestor "$journal_commit" "$remote_head" 2>/dev/null; then
        jq '.files' "$journal_file" > "$work_dir/confirmed.json"
    else
        : > "$work_dir/confirmed.jsonl"
        jq -c '.files[]' "$journal_file" > "$work_dir/journal.jsonl"
        while IFS= read -r row; do
            target=$(printf '%s' "$row" | jq -r .target)
            valid_destination "$target"
            expected=$(printf '%s' "$row" | jq -r '.mode + " blob " + .blob')
            if [ "$(tree_entry "$target")" = "$expected" ]; then
                printf '%s\n' "$row" >> "$work_dir/confirmed.jsonl"
            fi
        done < "$work_dir/journal.jsonl"
        jq -s '.' "$work_dir/confirmed.jsonl" > "$work_dir/confirmed.json"
    fi
    confirm_files "$work_dir/confirmed.json"
    if [ "$(jq length "$work_dir/confirmed.json")" -eq "$(jq '.files | length' "$journal_file")" ]; then
        rm -f -- "$journal_file"
    fi
}

safe_parent() {
    remainder=$1
    parent="$remote_dir"
    relative=''
    while case "$remainder" in */*) true ;; *) false ;; esac; do
        component=${remainder%%/*}
        remainder=${remainder#*/}
        parent="$parent/$component"
        relative=${relative:+$relative/}$component
        if [ -L "$parent" ] || { [ -e "$parent" ] && [ ! -d "$parent" ]; }; then return 1; fi
        entry=$(tree_entry "$relative")
        case "$entry" in ''|'040000 tree '*) ;; *) return 1 ;; esac
    done
}

retry=1
previous_remote=''
printf '{}\n' > "$work_dir/claimed-targets.json"
while [ "$retry" -le 3 ]; do
    if ! fetch_checkout "$retry"; then
        printf 'Git fetch failed; committed files remain queued (try %s).\n' "$retry" >&2
        retry=$((retry + 1))
        continue
    fi
    if [ -n "$previous_remote" ] && [ -z "$remote_head" ]; then
        fail 'Remote branch was deleted; committed files remain queued'
    fi
    previous_remote=$remote_head
    recover_journal
    pending_files > "$work_dir/pending.json"
    jq -c '.[]' "$work_dir/pending.json" > "$work_dir/pending.jsonl"
    : > "$work_dir/applied.jsonl"
    : > "$work_dir/confirmed.jsonl"
    while IFS= read -r row; do
        if ! printf '%s' "$row" | jq -e '.path | explode | all(. >= 32 and . != 127)' >/dev/null; then
            printf '%s\n' 'Skipping a committed path containing control characters; it remains queued.' >&2
            continue
        fi
        path=$(printf '%s' "$row" | jq -r .path)
        if ! (valid_destination "$path") >/dev/null 2>&1; then
            printf 'Skipping unsupported committed path: %s\n' "$path" >&2
            continue
        fi
        if ! target=$(filename_with_attempt "$path" "$model" "$attempt"); then
            printf 'Skipping a filename that cannot include the model and attempt: %s\n' "$path" >&2
            continue
        fi
        claimant=$(jq -r --arg target "$target" '.[$target] // empty' "$work_dir/claimed-targets.json")
        if [ -n "$claimant" ] && [ "$claimant" != "$path" ]; then
            printf 'Skipping a duplicate generated filename: %s; source remains queued.\n' "$target" >&2
            continue
        fi
        if [ -z "$claimant" ]; then
            jq --arg target "$target" --arg path "$path" '.[$target] = $path' \
                "$work_dir/claimed-targets.json" > "$work_dir/claimed-targets.next"
            mv -- "$work_dir/claimed-targets.next" "$work_dir/claimed-targets.json"
        fi
        blob=$(printf '%s' "$row" | jq -r .blob)
        mode=$(printf '%s' "$row" | jq -r .mode)
        row=$(printf '%s' "$row" | jq -c --arg target "$target" '. + {target:$target}')
        entry=$(tree_entry "$target")
        if [ "$entry" = "$mode blob $blob" ]; then
            printf '%s\n' "$row" >> "$work_dir/confirmed.jsonl"
            continue
        fi
        if [ -n "$entry" ] || [ -e "$remote_dir/$target" ] || [ -L "$remote_dir/$target" ] || ! safe_parent "$target"; then
            printf 'Skipping conflicting remote path: %s; source remains queued.\n' "$target" >&2
            continue
        fi
        mkdir -p -- "$(dirname -- "$remote_dir/$target")"
        git -C "$REPOSITORY_DIR" cat-file blob "$blob" > "$remote_dir/$target"
        case "$mode" in 100755) chmod 755 "$remote_dir/$target" ;; *) chmod 644 "$remote_dir/$target" ;; esac
        git -C "$remote_dir" --literal-pathspecs add -f -- "$target"
        printf '%s\n' "$row" >> "$work_dir/applied.jsonl"
    done < "$work_dir/pending.jsonl"
    jq -s '.' "$work_dir/confirmed.jsonl" > "$work_dir/confirmed.json"
    confirm_files "$work_dir/confirmed.json"
    if [ ! -s "$work_dir/applied.jsonl" ]; then break; fi
    git -C "$remote_dir" commit -q -m "Publish $model attempt $attempt $(date -u +%FT%TZ)"
    publication_commit=$(git -C "$remote_dir" rev-parse HEAD)
    journal_tmp=$(mktemp "$state_dir/.pending.XXXXXX")
    jq -s --arg commit "$publication_commit" '{commit:$commit,files:.}' "$work_dir/applied.jsonl" > "$journal_tmp"
    mv -- "$journal_tmp" "$journal_file"
    if timeout --foreground --kill-after=5 40 git -C "$remote_dir" push -q origin "HEAD:refs/heads/$GIT_BRANCH"; then
        jq -s '.' "$work_dir/applied.jsonl" > "$work_dir/confirmed.json"
        confirm_files "$work_dir/confirmed.json"
        rm -f -- "$journal_file"
        printf 'Published committed files (attempt %s, commit %s).\n' "$attempt" "$publication_commit"
        break
    fi
    printf 'Git push failed; checking the latest remote before retry %s.\n' "$((retry + 1))" >&2
    retry=$((retry + 1))
done

pending_files > "$work_dir/pending.json"
remaining=$(jq length "$work_dir/pending.json")
if [ "$remaining" -gt 0 ]; then
    printf '%s committed file(s) remain queued for a later push attempt.\n' "$remaining" >&2
    exit 1
fi
