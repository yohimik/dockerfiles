#!/bin/sh
set -eu
umask 077

die() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
    printf '%s\n' 'Usage: ./setup.sh [--github-key]' \
        'Read config/settings.sh, prepare local state, and start Docker cron.' \
        '--github-key creates/registers a dedicated GitHub write deploy key.'
}
provision_key=false
case "${1:-}" in
    '') ;;
    --github-key) provision_key=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 64; }

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
settings="$project_dir/config/settings.sh"
[ -f "$settings" ] || die 'Missing config/settings.sh.'
# Settings and job scripts are trusted shell code owned by this installation.
. "$settings"
GIT_URL=${GIT_URL:-}
state_dir="$project_dir/.state"
credentials="$state_dir/credentials"

# This script passes only a host path to Docker. Convert it explicitly on Git
# Bash/Cygwin; Compose resolves the relative bind mounts itself.
compose_dir="$project_dir"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) compose_dir=$(cygpath -m "$project_dir") ;;
esac
command -v docker >/dev/null 2>&1 || die 'Install Docker and Docker Compose first.'
docker compose version >/dev/null || die 'Docker Compose is unavailable.'
engine_type=$(docker info --format '{{.OSType}}') || die 'Start Docker before running setup.'
[ "$engine_type" = linux ] || die 'Use Docker Linux containers for this client.'

if [ "$provision_key" = true ]; then
    case "$GIT_URL" in
        git@github.com:*/*.git) ;;
        *) die '--github-key requires GIT_URL=git@github.com:OWNER/REPOSITORY.git in settings.sh.' ;;
    esac
    repository=${GIT_URL#git@github.com:}
    repository=${repository%.git}
    owner=${repository%%/*}
    repo=${repository#*/}
    # Validate before creating any files; dot/parent components must never
    # become paths or GitHub API endpoint components.
    case "$owner" in ''|*[!A-Za-z0-9-]*|-*|*-) die 'Invalid GitHub owner.' ;; esac
    case "$repo" in ''|.|..|*.git|*[!A-Za-z0-9_.-]*) die 'Invalid GitHub repository name.' ;; esac
    [ "${#owner}" -le 39 ] && [ "${#repo}" -le 100 ] || die 'GitHub repository name is too long.'
    command -v gh >/dev/null 2>&1 || die 'Install GitHub CLI to use --github-key.'
    command -v ssh-keygen >/dev/null 2>&1 || die 'Install OpenSSH to use --github-key.'
    gh auth status >/dev/null 2>&1 || die 'Sign in using gh auth login first.'
fi

mkdir -p "$credentials" "$state_dir/bridge/requests" "$state_dir/bridge/responses" \
    "$state_dir/input" "$state_dir/data"
chmod 700 "$state_dir" "$credentials"

if [ "$provision_key" = true ]; then
    key_dir="$state_dir/keys/$owner/$repo"
    mkdir -p "$key_dir"
    chmod 700 "$key_dir"
    key_file="$key_dir/id_ed25519"
    if [ ! -f "$key_file" ]; then
        ssh-keygen -q -t ed25519 -N '' -C 'laptop-cron-client' -f "$key_file"
    fi
    if [ ! -f "$key_file.pub" ]; then
        public_tmp="$key_file.pub.tmp"
        if ! ssh-keygen -y -P '' -f "$key_file" > "$public_tmp"; then
            rm -f "$public_tmp"
            die 'Could not derive the public key; unattended operation requires an unencrypted deploy key.'
        fi
        mv "$public_tmp" "$key_file.pub"
    fi
    chmod 600 "$key_file"
    public_key=$(awk 'NR == 1 { print $1 " " $2; exit }' "$key_file.pub")
    key_list=$(gh api --paginate "repos/$repository/keys" --jq '.[] | [.id, .key, .read_only] | @tsv') \
        || die 'Cannot inspect deploy keys; repository administration rights are required.'
    matching=$(printf '%s\n' "$key_list" | awk -F '\t' -v wanted="$public_key" \
        '{ split($2, fields, " "); if (fields[1] " " fields[2] == wanted) print $3 }')
    case "$matching" in
        false) ;;
        true) die 'This deploy key is read-only; configure write access before continuing.' ;;
        '') gh repo deploy-key add "$key_file.pub" --repo "$repository" \
                --title 'Laptop cron client' --allow-write ;;
        *) die 'Unexpected deploy key state; inspect the repository deploy keys.' ;;
    esac
    hosts_tmp="$credentials/known_hosts.tmp"
    trap 'rm -f "$hosts_tmp"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    gh api meta --jq '.ssh_keys[] | "github.com " + .' > "$hosts_tmp"
    [ -s "$hosts_tmp" ] || die 'GitHub returned no SSH host keys.'
    chmod 600 "$hosts_tmp"
    mv "$hosts_tmp" "$credentials/known_hosts"
    cp "$key_file" "$credentials/id_ed25519"
    chmod 600 "$credentials/id_ed25519"
    trap - EXIT HUP INT TERM
fi

case "$GIT_URL" in
    *@*:*|ssh://*)
        [ -s "$credentials/id_ed25519" ] && [ -s "$credentials/known_hosts" ] \
            || die 'Provide .state/credentials/id_ed25519 and known_hosts, or use --github-key for GitHub.'
        ;;
esac

"$project_dir/collect-device-info.sh"
docker compose --project-directory "$compose_dir" up -d --build --force-recreate
printf '%s\n' 'Docker cron started. Edit config/settings.sh, config/crontab, and jobs/*.sh to configure it.' \
    'Location jobs require an external host location provider; this setup installs no native helper.'
