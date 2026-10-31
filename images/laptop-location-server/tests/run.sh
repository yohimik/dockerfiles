#!/bin/sh
# Build and exercise the real Alpine scripts without contacting GitHub.
set -eu
project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=${TEST_IMAGE:-laptop-location-server:test}
docker build -t "$image" "$project_dir"
docker run --rm --network none --read-only \
    --tmpfs /tmp:mode=1777 --tmpfs /config --tmpfs /credentials \
    --tmpfs /data --tmpfs /var/run \
    -v "$project_dir/tests:/tests:ro" \
    -v "$project_dir/tests/mock-curl.sh:/usr/local/bin/curl:ro" \
    -v "$project_dir/tests/mock-date.sh:/usr/local/bin/date:ro" \
    --entrypoint /bin/sh "$image" /tests/integration.sh
