#!/bin/sh
set -eu
# This example describes the container, not the host laptop.
mkdir -p /data/generated
date -u +%FT%TZ > /data/generated/status.txt
uname -s >> /data/generated/status.txt
