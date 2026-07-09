#!/usr/bin/env bash
# Open the OpenClaw terminal UI (TUI), connected to the running gateway.
# The gateway requires a one-time device pairing per container; this auto-pairs
# (idempotent) then opens the TUI. Usage:
#   ./bin/tui.sh            open the shared "main" session
#   ./bin/tui.sh scratch    open a fresh, isolated session named "scratch"
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env. Run ./setup.sh first."; exit 1; }
TOK=$(sed -n 's/^GATEWAY_TOKEN=//p' .env | head -1)
GW="ws://127.0.0.1:18789"
SESSION="${1:-main}"
oc() { docker compose exec -T -w /root/ocsrc openclaw node scripts/run-node.mjs "$@"; }

# Ensure the gateway is up.
docker compose exec -T openclaw sh -lc 'curl -sf http://127.0.0.1:18789/ >/dev/null' 2>/dev/null || {
  echo "OpenClaw gateway is not answering. Is the stack up? (./up.sh)"; exit 1; }

# Pair this device if needed: a brief connect registers a pairing request; approve it.
docker compose exec -T -w /root/ocsrc openclaw sh -lc \
  "timeout 3 node scripts/run-node.mjs tui --url $GW --token $TOK --session _pair --message pair >/dev/null 2>&1 || true"
if oc devices list 2>/dev/null | grep -q 'Pending ([1-9]'; then
  REQ=$(oc devices list 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  [ -n "${REQ:-}" ] && oc devices approve "$REQ" >/dev/null 2>&1 && echo "paired this device"
fi

echo "opening TUI (session: $SESSION). Ctrl+C to exit."
exec docker compose exec -it -w /root/ocsrc openclaw \
  node scripts/run-node.mjs tui --url "$GW" --token "$TOK" --session "$SESSION"
