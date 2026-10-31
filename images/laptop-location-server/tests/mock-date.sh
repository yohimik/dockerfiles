#!/bin/sh
set -eu
if [ "$*" = '+%s' ] || [ "$*" = '-u +%s' ]; then
    printf '%s\n' 2000000000
else
    exec /bin/date "$@"
fi
