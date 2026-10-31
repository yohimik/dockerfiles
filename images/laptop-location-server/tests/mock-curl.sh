#!/bin/sh
# Only fixture responses are available; the test container has no network.
set -eu
method=GET
output=''
write_out=''
body=''
url=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --request|-X) method=$2; shift 2 ;;
        --output|-o) output=$2; shift 2 ;;
        --write-out|-w) write_out=$2; shift 2 ;;
        --data|--data-raw|--data-binary|-d) body=$2; shift 2 ;;
        --header|-H|--config|-K|--connect-timeout|--max-time|--retry|--retry-delay|--proto|--tlsv1.2)
            if [ "$1" = --tlsv1.2 ]; then shift; else shift 2; fi ;;
        --fail|--fail-with-body|--silent|--show-error|-s|-S|-sS|-f|-fsS|--location|-L)
            shift ;;
        https://api.github.com/repos/test-owner/test-repo) url=$1; shift ;;
        *) printf 'Unexpected mock curl argument: %s\n' "$1" >&2; exit 90 ;;
    esac
done
[ -n "$url" ] || exit 91
printf '%s\n' "$method" >> /tmp/api/requests
case "$method" in
    GET)
        status=$(cat /tmp/api/get-status)
        if [ -f /tmp/api/block-get ]; then
            touch /tmp/api/get-entered
            attempts=0
            while [ -f /tmp/api/block-get ]; do
                attempts=$((attempts + 1))
                [ "$attempts" -lt 100 ] || exit 28
                sleep 0.1
            done
        fi
        if [ -f /tmp/api/patched ]; then
            response=/tmp/api/patch.json
        elif [ -f /tmp/api/get-second.json ] && [ "$(grep -c GET /tmp/api/requests)" -gt 1 ]; then
            response=/tmp/api/get-second.json
        else
            response=/tmp/api/get.json
        fi
        ;;
    PATCH)
        printf '%s\n' "$body" > /tmp/api/request-body
        status=$(cat /tmp/api/patch-status)
        response=/tmp/api/patch.json
        if [ "$status" = 200 ]; then touch /tmp/api/patched; fi
        ;;
    *) exit 92 ;;
esac
if [ -n "$output" ]; then cat "$response" > "$output"; else cat "$response"; fi
if [ -n "$write_out" ]; then printf '%s' "$status"; fi
case "$status" in 2??) ;; *) exit 22 ;; esac
