#!/bin/sh
# Sourced after common.sh by the push worker.
device_model_slug() (
    DEVICE_INFO_FILE=/config/device.json
    HOST_INFO_FILE=/input/device-info.json
    if [ -f /config/device-report.sh ]; then
        # shellcheck source=/dev/null
        . /config/device-report.sh
    fi
    model=''
    for info in "$DEVICE_INFO_FILE" "$HOST_INFO_FILE"; do
        [ -n "$info" ] || continue
        case "$info" in /config/*|/input/*) ;; *) fail 'Model metadata must be under /config or /input' ;; esac
        [ -e "$info" ] || continue
        resolved=$(realpath -e -- "$info")
        case "$resolved" in /config/*|/input/*) ;; *) fail 'Model metadata resolves outside /config or /input' ;; esac
        [ -f "$resolved" ] || fail 'Model metadata must be a regular JSON file'
        model=$(jq -ser 'select(length == 1) | .[0] | select(type == "object")
            | (.model_name // "") | select(type == "string")' "$resolved") \
            || fail 'Invalid model metadata'
        [ -z "$model" ] || break
    done
    jq -nr --arg model "$model" '$model | gsub("[^A-Za-z0-9]+"; "-")
        | sub("^-+"; "") | .[0:48] | sub("-+$"; "")
        | if length == 0 then "device" else . end'
)

filename_with_attempt() (
    path=$1
    model=$2
    counter=$3
    valid_destination "$path"
    case "$model" in ''|*[!A-Za-z0-9-]*) fail 'Invalid model filename component' ;; esac
    case "$counter" in ''|0*|*[!0-9]*) fail 'Invalid push attempt counter' ;; esac
    directory=${path%/*}
    if [ "$directory" = "$path" ]; then directory=''; else directory=$directory/; fi
    name=${path##*/}
    stem=$name
    extension=''
    case "$name" in ?*.*) stem=${name%.*}; extension=.${name##*.} ;; esac
    suffix=-$model-$counter$extension
    suffix_bytes=$(printf '%s' "$suffix" | wc -c)
    available=$((255 - suffix_bytes))
    [ "$available" -gt 0 ] || fail 'File extension leaves no room for the model and attempt'
    stem=$(printf '%s' "$stem" | jq -Rrs --argjson bytes "$available" 'until(utf8bytelength <= $bytes; .[:-1])')
    [ -n "$stem" ] || fail 'Filename is too long to add the model and attempt'
    printf '%s%s%s\n' "$directory" "$stem" "$suffix"
)
