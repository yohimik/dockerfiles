#!/bin/sh
# Exercise report generation and Git publishing entirely inside an isolated image.
set -eu
project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=${TEST_IMAGE:-laptop-location-client:device-report-test}
docker build -t "$image" "$project_dir"
sh "$project_dir/tests/cron-runtime.sh" "$image"
docker run --rm --network none --read-only \
    --tmpfs /tmp:mode=1777,exec --tmpfs /config --tmpfs /jobs --tmpfs /input --tmpfs /deployment \
    --tmpfs /credentials --tmpfs /data --tmpfs /root/.ssh --tmpfs /var/run \
    -v "$project_dir/tests:/tests:ro" \
    -v "$project_dir/config:/defaults/config:ro" \
    -v "$project_dir/jobs:/defaults/jobs:ro" \
    -v "$project_dir/compose.yaml:/defaults/compose.yaml:ro" \
    -v "$project_dir/Dockerfile:/defaults/Dockerfile:ro" \
    -v "$project_dir/collect-device-info.sh:/defaults/collect-device-info.sh:ro" \
    --entrypoint /bin/sh "$image" -c 'sh /tests/integration.sh && sh /tests/host-collector.sh'
