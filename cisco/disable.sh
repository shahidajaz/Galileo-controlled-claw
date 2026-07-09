#!/usr/bin/env bash
# Turn Cisco AI Defense back off: detach + disable the control (leaves the evaluator
# installed but unused, so no content egresses). The regex + steer controls keep working.
set -uo pipefail
STACK_DIR="${STACK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$STACK_DIR"; [ -f .env ] || { echo "no .env"; exit 1; }
set -a; . ./.env 2>/dev/null; set +a
AC_PORT="${AC_PORT:-8181}"; ADMIN="${AC_ADMIN_KEY:-}"
AGENT_NAMES="${AGENT_NAMES:-openclaw-agent:main}"

CID=$(curl -s "http://127.0.0.1:${AC_PORT}/api/v1/controls" -H "X-API-Key: ${ADMIN}" \
  | tr '{' '\n' | grep 'openclaw-cisco-aidefense' \
  | sed -n 's/.*"\(id\|control_id\)":[[:space:]]*"\{0,1\}\([^",}]*\).*/\2/p' | head -1)
[ -z "$CID" ] && { echo "[cisco] no openclaw-cisco-aidefense control found; already off."; exit 0; }

IFS=','; for a in $AGENT_NAMES; do a="$(echo "$a" | xargs)"
  st=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
    "http://127.0.0.1:${AC_PORT}/api/v1/agents/${a}/controls/${CID}" -H "X-API-Key: ${ADMIN}")
  echo "[cisco] detached from ${a}: HTTP ${st}"
done; unset IFS

# Disable the control too (belt and suspenders), so it cannot fire even if reattached.
curl -s -o /dev/null -X PUT "http://127.0.0.1:${AC_PORT}/api/v1/controls/${CID}/data" \
  -H "X-API-Key: ${ADMIN}" -H "Content-Type: application/json" \
  -d '{"data":{"enabled":false,"execution":"server","scope":{"step_types":["llm"],"stages":["pre"]},"condition":{"selector":{"path":"input"},"evaluator":{"name":"regex","config":{"pattern":"(?!x)x"}}},"action":{"decision":"observe"}}}'
echo "[cisco] Cisco AI Defense OFF. No content egresses. Re-enable with cisco/enable.sh."
