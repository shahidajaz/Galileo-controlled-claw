#!/usr/bin/env bash
# Prints a clean access card for the stack: every endpoint, token, and next step.
# Reads .env by key (never sources it - values like WEBEX_SCOPES have spaces).
# Safe to run anytime:  ./bin/access-card.sh
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env yet. Run ./setup.sh first."; exit 1; }

v()  { sed -n "s/^$1=//p" .env | head -1; }   # value of KEY ("" if unset)
on() { [ -n "$(v "$1")" ]; }                  # is KEY set + non-empty?
row() { printf '  %-13s %s\n' "$1" "$2"; }
hr()  { printf '  %s\n' "────────────────────────────────────────────────────────────────"; }

AC_PORT="$(v AC_PORT)"; AC_PORT="${AC_PORT:-8181}"
GW="$(v OPENCLAW_GATEWAY_PORT)"; GW="${GW:-18789}"

# Resolve the Telegram bot handle live (nice touch; falls back quietly).
TG_HANDLE=""
if on TELEGRAM_BOT_TOKEN; then
  TG_HANDLE=$(curl -s --max-time 5 "https://api.telegram.org/bot$(v TELEGRAM_BOT_TOKEN)/getMe" \
    | python3 -c 'import sys,json;print("@"+json.load(sys.stdin)["result"]["username"])' 2>/dev/null) || TG_HANDLE=""
  [ -z "$TG_HANDLE" ] && TG_HANDLE="(bot token set)"
fi

echo
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║   Galileo controlled Claw · access card                          ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo
echo "  ENDPOINTS   (bound to 127.0.0.1 - SSH-tunnel to reach remotely)"
row "OpenClaw"   "http://127.0.0.1:${GW}"
row ""           "gateway token: $(v GATEWAY_TOKEN)"
row "Agent Ctrl" "http://127.0.0.1:${AC_PORT}"
row ""           "admin key: $(v AC_ADMIN_KEY)"
echo
echo "  GOVERNANCE"
if [ "$(v GOVERNANCE_ENABLED)" != "false" ]; then
  fc="$(v GOVERNANCE_FAIL_CLOSED)"; row "Mode" "ON  ·  tool + LLM surfaces  ·  fail-closed=${fc:-true}"
else
  row "Mode" "OFF  ·  ungoverned (no plugin loaded)"
fi
echo
echo "  OBSERVABILITY"
row "Galileo"    "$(on GALILEO_API_KEY   && echo "ON  → project $(v GALILEO_PROJECT)  ·  https://app.galileo.ai" || echo "off")"
row "Splunk HEC" "$(on SPLUNK_HEC_URL    && echo "ON  → index $(v SPLUNK_INDEX)  (decisions + LLM turns)" || echo "off")"
row "Splunk o11y" "$(on SPLUNK_O11Y_REALM && echo "ON  → realm $(v SPLUNK_O11Y_REALM)  ·  https://app.$(v SPLUNK_O11Y_REALM).signalfx.com" || echo "off")"
on SPLUNK_O11Y_REALM && { s="$(v SPLUNK_O11Y_SERVICE)"; row "" "metric openclaw.governance.decision + traces (service ${s:-openclaw})"; }
echo
echo "  CHANNELS & TOOLS"
TG_ALLOW="$(v TELEGRAM_ALLOW)"
row "Telegram" "$(on TELEGRAM_BOT_TOKEN && echo "${TG_HANDLE}  ·  allowed id(s): ${TG_ALLOW:-<pairing>}" || echo "off")"
if on WEBEX_CLIENT_ID; then
  row "Webex" "configured - authorize once:"
  row "" "docker compose exec openclaw node /root/openclaw-webex/oauth-setup.mjs url"
else
  row "Webex" "off"
fi
echo
hr
echo "  TUI          ./bin/tui.sh              interactive terminal chat (auto-pairs)"
echo "  ONE-SHOT     docker compose exec openclaw bash -lc \\"
echo "               'cd /root/ocsrc && node scripts/run-node.mjs agent --agent main -m \"hello\"'"
echo "  LOGS  docker compose logs -f openclaw     STOP  ./down.sh     THIS CARD  ./bin/access-card.sh"
hr
echo
