#!/usr/bin/env bash
# Enable Cisco AI Defense as an Agent Control evaluator — OFF BY DEFAULT.
#
# Cisco AI Defense is a launch-partner evaluator that ships (as source) inside the
# Agent Control server image at /app/evaluators/contrib/cisco. It is a semantic
# guardrail (better than the OSS regex evaluators), wired natively into Agent
# Control's own deny/steer engine. This script installs it into the server venv,
# then creates ONE fail-closed control backed by it and attaches it to the agent(s).
#
# PRIVACY: this evaluator calls Cisco AI Defense's CLOUD API — governed prompt
# content leaves the box to *.aidefense.security.cisco.com. That is why it is
# off by default and gated on a key. Do NOT enable it on a stack that must stay
# fully local; for a Cisco-facing demo it is the vendor-native story.
#
# Flip on:  set CISCO_AI_DEFENSE_API_KEY (and optionally CISCO_AI_DEFENSE_REGION)
#           in .env, then run this script. Flip off: cisco/disable.sh.
#
# Env / args (all optional, sensible defaults):
#   STACK_DIR      dir holding .env + the compose file   (default: this repo)
#   COMPOSE_FILE   compose file name                     (default: compose.yml)
#   SERVICE        the Agent Control server service name (default: server)
#   AGENT_NAMES    comma list of agents to attach to     (default: openclaw-agent:main)
set -uo pipefail

STACK_DIR="${STACK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yml}"
SERVICE="${SERVICE:-server}"
cd "$STACK_DIR"
[ -f .env ] || { echo "no .env in $STACK_DIR"; exit 1; }
set -a; . ./.env 2>/dev/null; set +a

KEY="${CISCO_AI_DEFENSE_API_KEY:-}"
REGION="${CISCO_AI_DEFENSE_REGION:-us}"
AGENT_NAMES="${AGENT_NAMES:-openclaw-agent:main}"
AC_PORT="${AC_PORT:-8181}"
ADMIN="${AC_ADMIN_KEY:-}"
DC="docker compose -f $COMPOSE_FILE"

if [ -z "$KEY" ]; then
  echo "[cisco] CISCO_AI_DEFENSE_API_KEY is blank -> Cisco AI Defense stays OFF (local stack unchanged)."
  echo "[cisco] To enable: set CISCO_AI_DEFENSE_API_KEY in $STACK_DIR/.env and re-run this script."
  exit 0
fi

echo "[cisco] enabling Cisco AI Defense (region=$REGION). NOTE: governed content will egress to Cisco cloud."

# 1) Make sure the API key is in the server process env (compose reads it from .env).
echo "[cisco] 1/5 refreshing $SERVICE with AI_DEFENSE_API_KEY present..."
$DC up -d "$SERVICE" >/dev/null 2>&1 || { echo "[cisco] compose up $SERVICE failed"; exit 1; }

# 2) Install the contrib evaluator into the server's uv venv (idempotent).
echo "[cisco] 2/5 installing the cisco.ai_defense evaluator into the server venv..."
$DC exec -T "$SERVICE" sh -c 'VIRTUAL_ENV=/app/.venv uv pip install --no-deps /app/evaluators/contrib/cisco' \
  >/dev/null 2>&1 || { echo "[cisco] evaluator install failed (needs pypi egress at first run for hatchling)"; exit 1; }

# 3) Restart the server process so it re-scans entry points WITH the key in env.
echo "[cisco] 3/5 restarting $SERVICE so the evaluator registers..."
$DC restart "$SERVICE" >/dev/null 2>&1

# 4) Wait until the server reports cisco.ai_defense as an available evaluator.
echo "[cisco] 4/5 waiting for cisco.ai_defense to appear..."
ok=""
for _ in $(seq 1 40); do
  if curl -s "http://127.0.0.1:${AC_PORT}/api/v1/evaluators" -H "X-API-Key: ${ADMIN}" 2>/dev/null | grep -q '"cisco.ai_defense"'; then
    ok=1; break
  fi
  sleep 2
done
[ -n "$ok" ] || { echo "[cisco] evaluator did not register in time; check '$DC logs $SERVICE'"; exit 1; }
echo "[cisco]     registered."

# 5) Create ONE fail-closed control backed by it, attach to the agent(s).
#    on_error=deny => if Cisco AI Defense is unreachable, the call is BLOCKED (fail-closed).
echo "[cisco] 5/5 creating + attaching the openclaw-cisco-aidefense control..."
DATA=$(cat <<JSON
{"name":"openclaw-cisco-aidefense","data":{
  "enabled":true,"execution":"server",
  "scope":{"step_types":["llm"],"stages":["pre"]},
  "condition":{"selector":{"path":"input"},
    "evaluator":{"name":"cisco.ai_defense","config":{
      "api_key_env":"AI_DEFENSE_API_KEY","region":"${REGION}",
      "on_error":"deny","messages_strategy":"single","timeout_ms":15000}}},
  "action":{"decision":"deny"}}}
JSON
)
CID=$(curl -s -X PUT "http://127.0.0.1:${AC_PORT}/api/v1/controls" \
  -H "X-API-Key: ${ADMIN}" -H "Content-Type: application/json" -d "$DATA" \
  | sed -n 's/.*"control_id":[[:space:]]*"\{0,1\}\([^",}]*\).*/\1/p' | head -1)
if [ -z "$CID" ]; then
  CID=$(curl -s "http://127.0.0.1:${AC_PORT}/api/v1/controls" -H "X-API-Key: ${ADMIN}" \
    | tr ',' '\n' | grep -A1 'openclaw-cisco-aidefense' >/dev/null 2>&1; \
    curl -s "http://127.0.0.1:${AC_PORT}/api/v1/controls" -H "X-API-Key: ${ADMIN}")
fi
echo "[cisco]     control id=${CID:-<lookup>}"
IFS=','; for a in $AGENT_NAMES; do
  a="$(echo "$a" | xargs)"
  st=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:${AC_PORT}/api/v1/agents/${a}/controls/${CID}" -H "X-API-Key: ${ADMIN}")
  echo "[cisco]     attached to ${a}: HTTP ${st}"
done
unset IFS

echo "[cisco] DONE. Cisco AI Defense now gates the LLM surface (deny, fail-closed)."
echo "[cisco] Disable with: cisco/disable.sh"
