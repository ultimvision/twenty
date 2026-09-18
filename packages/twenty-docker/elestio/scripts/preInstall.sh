#!/bin/bash
set -e

# The twenty image runs as uid 1000, and a bind mount created by Docker would be
# owned by root, leaving local file storage unwritable.
mkdir -p ./storage/server-local-data ./storage/db
chown -R 1000:1000 ./storage/server-local-data
