#!/usr/bin/env bash
# Stop the stack.  ./down.sh        keep data
#                  ./down.sh -v     stop AND wipe volumes (Postgres, Splunk, state)
set -euo pipefail
cd "$(dirname "$0")"
docker compose --profile splunk down "$@"
