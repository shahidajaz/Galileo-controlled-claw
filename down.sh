#!/usr/bin/env bash
# Tear down the stack, three levels:
#   ./down.sh            Stop:  stop containers, keep everything (data + model). Fast restart.
#   ./down.sh --reset    Reset: stop + clear state (governance, agent, creds). KEEP the model.
#   ./down.sh --wipe     Wipe:  stop + delete EVERYTHING, including the downloaded model.
set -uo pipefail
cd "$(dirname "$0")"
DOWN=(docker compose -f compose.yml --profile models --profile splunk --profile splunk-hec --profile splunk-o11y down --remove-orphans)

case "${1:---stop}" in
  --stop|"")
    "${DOWN[@]}"; echo "Stopped. Kept all data and the model." ;;
  --reset)
    "${DOWN[@]}"
    for v in $(docker volume ls -q --filter "name=^galileo-governed_" 2>/dev/null | grep -v 'ollamamodels'); do
      docker volume rm "$v" >/dev/null 2>&1 && echo "  cleared $v"
    done
    echo "Reset. State cleared; the model is kept." ;;
  --wipe|--wipe-all|-v)
    "${DOWN[@]}" --volumes --rmi local
    docker image rm -f "${AC_BASE_IMAGE:-openclaw-ac-base:8.2.0}" >/dev/null 2>&1 || true
    echo "Wiped everything: containers, volumes, the model, and this project's images." ;;
  *)
    echo "usage: down.sh [--stop | --reset | --wipe]"; exit 1 ;;
esac
