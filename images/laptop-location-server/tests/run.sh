#!/bin/sh
# Build and exercise Python checks and live cron reloads without contacting GitHub.
set -eu
project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=${TEST_IMAGE:-laptop-location-server:test}
docker build -t "$image" "$project_dir"
sh "$project_dir/tests/cron-runtime.sh" "$image"
docker run --rm --network none --read-only \
    --tmpfs /tmp:mode=1777 --tmpfs /config --tmpfs /credentials \
    --tmpfs /data --tmpfs /var/run \
    --env PYTHONDONTWRITEBYTECODE=1 \
    -v "$project_dir/tests:/tests:ro" \
    -v "$project_dir/function:/function:ro" \
    --entrypoint /bin/sh "$image" -c '
        python3 -m unittest discover -s /function/tests -v &&
        python3 -m unittest discover -s /tests -p test_runtime.py -v
    '
