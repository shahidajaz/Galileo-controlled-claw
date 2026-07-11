#!/usr/bin/env bash
# Read-only control center: live state of the running stack + the URLs and
# commands that matter. Safe to run anytime.  ./bin/status.sh
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env. Run ./setup.sh first."; exit 1; }

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'; CY=$'\e[36m'; GR=$'\e[32m'; MG=$'\e[35m'; YE=$'\e[33m'
else B=""; DIM=""; R=""; CY=""; GR=""; MG=""; YE=""; fi
v()   { sed -n "s/^$1=//p" .env | head -1; }
on()  { [ -n "$(v "$1")" ]; }
hd()  { printf '\n  %s\n' "${CY}${B}$1${R}"; }
row() { printf '     %-14s %s\n' "$1" "$2"; }

ACP="$(v AC_PORT)"; ACP="${ACP:-8181}"; GW="$(v OPENCLAW_GATEWAY_PORT)"; GW="${GW:-18789}"
RUN="$(docker compose ps --status running --format '{{.Service}}' 2>/dev/null || true)"
isup() { printf '%s\n' "$RUN" | grep -qx "$1"; }
svc()  { if isup "$1"; then printf '     %b  %-16s %s\n' "${GR}●${R}" "$1" "up${2:+   $2}"; else printf '     %b  %-16s %s\n' "${DIM}○${R}" "$1" "${DIM}down${R}"; fi; }

printf '\n  %s\n  %s\n' "${CY}${B}Galileo controlled Claw · status${R}" "${DIM}live state of the stack${R}"

hd "SERVICES"
svc postgres "(governor DB)"; svc server "(Agent Control :$ACP)"; svc llm-proxy "(LLM gate)"
svc openclaw "(agent + gateway :$GW)"; svc splunk-forwarder "(decisions → HEC)"; svc o11y-forwarder "(decisions → o11y)"

hd "GOVERNANCE"
if isup server; then
  cnt=$(curl -s --max-time 4 -H "X-API-Key: $(v AC_ADMIN_KEY)" "http://127.0.0.1:$ACP/api/v1/agents/openclaw-agent:main/controls" 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);c=d.get("controls",d);print(len(c) if isinstance(c,list) else 0)' 2>/dev/null || echo "?")
  [ "$(v GOVERNANCE_ENABLED)" = false ] && row "Mode" "${DIM}off (raw)${R}" || row "Mode" "${GR}ENFORCING${R} · $cnt controls on openclaw-agent:main"
  row "Manage live" "${MG}http://127.0.0.1:$ACP${R}  ${DIM}(add/edit/remove, applies immediately)${R}"
  row "Admin key" "$(v AC_ADMIN_KEY)"
else
  row "Mode" "${DIM}server down${R}"
fi

hd "AGENTS"
if [ "$(v DELEGATE_ENABLED)" = false ]; then
  row "Topology" "${DIM}single agent (main)${R}"
else
  row "Topology" "${B}Manager${R} (main) ${DIM}→ delegates to →${R} ${B}Helper${R} (helper, read-only)"
  if isup postgres; then
    dg=$(docker compose exec -T postgres psql -U agent_control -d agent_control -tAc \
      "select count(*) from control_execution_events where data->>'control_name'='openclaw-govern-delegation' and (data->>'matched')::bool=true" 2>/dev/null | tr -d '[:space:]')
    row "Delegations" "${GR}${dg:-0}${R} governed + audited (every sessions_spawn passes the same gate)"
  fi
  row "Guarantee" "${DIM}delegation is a tool call → a subagent cannot launder a red line${R}"
fi

hd "OBSERVABILITY"
gl="${DIM}off${R}"; on GALILEO_API_KEY && gl="project $(v GALILEO_PROJECT)  ${MG}https://app.galileo.ai${R}"
row "Galileo" "$gl"
if isup openclaw; then
  last=$(docker compose exec -T openclaw sh -lc 'tail -1 /root/galileo-fwd.log 2>/dev/null' 2>/dev/null | sed 's/^[0-9T:.Z-]* //')
  [ -n "$last" ] && row "" "${DIM}last: $last${R}"
fi
hec="${DIM}off${R}"; on SPLUNK_HEC_URL && hec="index $(v SPLUNK_INDEX)  ${DIM}$(v SPLUNK_HEC_URL)${R}"
row "Splunk HEC" "$hec"
o11y="${DIM}off${R}"; on SPLUNK_O11Y_REALM && o11y="realm $(v SPLUNK_O11Y_REALM)  ${MG}https://app.$(v SPLUNK_O11Y_REALM).signalfx.com${R}"
row "Splunk o11y" "$o11y"

hd "CONNECTIONS"
tg="${DIM}off${R}"
if on TELEGRAM_BOT_TOKEN; then
  h=$(curl -s --max-time 4 "https://api.telegram.org/bot$(v TELEGRAM_BOT_TOKEN)/getMe" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("@"+d["result"]["username"] if d.get("ok") else "")' 2>/dev/null)
  tg="channel · ${h:-bot} · allow $(v TELEGRAM_ALLOW)"
fi
row "Telegram" "$tg"
wx="${DIM}off${R}"; on WEBEX_CLIENT_ID && wx="tool plugin · configured (authorize: oauth-setup.mjs)"
row "Webex" "$wx"

hd "DO THINGS"
row "Chat (TUI)" "${B}./bin/tui.sh${R}"
row "Access card" "${B}./bin/access-card.sh${R}"
row "Reconfigure" "${B}./setup.sh${R}"
row "Stop all" "${B}docker compose --profile splunk --profile splunk-hec --profile splunk-o11y down --remove-orphans${R}"
printf '\n'
