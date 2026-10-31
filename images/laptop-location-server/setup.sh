#!/bin/sh
set -eu
umask 077
die() { printf '%s\n' "$*" >&2; exit 1; }
[ "$#" -eq 0 ] || die 'Usage: ./setup.sh'
project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
compose_dir="$project_dir"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) compose_dir=$(cygpath -m "$project_dir") ;;
esac
command -v docker >/dev/null 2>&1 || die 'Install Docker and Docker Compose first.'
docker compose version >/dev/null || die 'Docker Compose is unavailable.'
engine_type=$(docker info --format '{{.OSType}}') || die 'Start Docker before running setup.'
[ "$engine_type" = linux ] || die 'Use Docker Linux containers for this server.'
mkdir -p "$project_dir/.state/credentials" "$project_dir/.state/data"
chmod 700 "$project_dir/.state" "$project_dir/.state/credentials"
[ -s "$project_dir/.state/credentials/github_token" ] \
    || die 'Put a GitHub token with repository Administration write permission in .state/credentials/github_token.'
chmod 600 "$project_dir/.state/credentials/github_token"
docker compose --project-directory "$compose_dir" up -d --build --force-recreate
printf '%s\n' 'Daily repository check started. See docker compose logs for results.'
