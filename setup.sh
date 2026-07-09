#!/usr/bin/env bash
# Dashboard setup for openclaw-governed.
# Grouped, self-explaining board. Arrow keys move, Enter configures, t tests
# credentials, L launches, Q quits. Writes .env. Everything is pre-wired: you
# only supply credentials to switch each piece on.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || cp .env.example .env

# ── styling ──────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'; CY=$'\e[36m'; GR=$'\e[32m'; YE=$'\e[33m'; MG=$'\e[35m'; RD=$'\e[31m'
else B=""; DIM=""; R=""; CY=""; GR=""; YE=""; MG=""; RD=""; fi
HR="  ${DIM}────────────────────────────────────────────────────────────${R}"
cls()  { clear 2>/dev/null || printf '\033[2J\033[3J\033[H'; }

# ── env + prompt helpers ─────────────────────────────────────────────────────
cur()    { sed -n "s/^$1=//p" .env | head -1; }
curdef() { local v; v="$(cur "$1")"; echo "${v:-$2}"; }
setenv() { if grep -qE "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi; }
ask()    { local a; read -r -p "  $1 [$2]: " a; echo "${a:-$2}"; }
asksec() { local a; read -r -s -p "  $1: " a; echo >&2; echo "$a"; }
card()   { cls; printf '\n  %s\n%s\n\n' "${CY}${B}$1${R}" "$HR"; }
howto()  { printf '  %s %s\n' "${YE}${B}How to get it:${R}" "$1"; }
li()     { printf '     %s\n' "${DIM}$1${R}"; }
link()   { printf '     %s\n' "${MG}↗ $1${R}"; }
ok()     { printf '     %s\n' "${GR}✓ $1${R}"; }
bad()    { printf '     %s\n' "${RD}✗ $1${R}"; }
pause()  { read -r -p "  press Enter to return to the board " _; }
saved()  { printf '\n  %s\n' "${GR}✓ saved${R}"; pause; }
cleanurl(){ printf '%s' "$1" | sed 's|https\?://||;s|/v1$||'; }
humanctx(){ case "$1" in 8192) echo 8k;; 32768) echo 32k;; 131072) echo 131k;; 262144) echo 256k;; *) echo "${1}t";; esac; }

# ── Telegram id capture ──────────────────────────────────────────────────────
capture_telegram_id() {
  local tok="$1" handle running="" id=""
  handle=$(curl -s --max-time 5 "https://api.telegram.org/bot${tok}/getMe" \
    | python3 -c 'import sys,json;print("@"+json.load(sys.stdin)["result"]["username"])' 2>/dev/null) || handle="your bot"
  if docker compose ps --status running 2>/dev/null | grep -q '\bopenclaw\b'; then
    running=1; docker compose stop openclaw >/dev/null 2>&1
  fi
  printf '  Open Telegram, send any message to %s, then press Enter...' "$handle" >&2
  read -r _ </dev/tty
  for _ in 1 2 3; do
    id=$(curl -s "https://api.telegram.org/bot${tok}/getUpdates?timeout=10" | python3 -c 'import sys,json
d=json.load(sys.stdin); fs=[u["message"]["from"] for u in d.get("result",[]) if u.get("message")]
print(fs[-1]["id"] if fs else "")' 2>/dev/null)
    [ -n "$id" ] && break
  done
  [ -n "$running" ] && docker compose start openclaw >/dev/null 2>&1
  echo "$id"
}

# ── editors ──────────────────────────────────────────────────────────────────
e_model() {
  card "Agent · Model  ·  the LLM your agent reasons with"
  li "Any OpenAI-compatible endpoint (your vLLM / Ollama / OpenAI)."
  local b probe avail m k c
  b=$(ask "Base URL" "$(curdef LLM_BASE_URL http://host.docker.internal:8000/v1)")
  probe="${b/host.docker.internal/localhost}"
  avail=$(curl -sf --max-time 5 "${probe%/}/models" 2>/dev/null | python3 -c 'import sys,json;print(", ".join(x["id"] for x in json.load(sys.stdin).get("data",[])))' 2>/dev/null || true)
  [ -n "$avail" ] && ok "reachable · models: $avail"
  m=$(ask "Model name" "$(curdef LLM_MODEL openai/gpt-oss-120b)")
  k=$(ask "API key ('unused' for a local model)" "$(curdef LLM_API_KEY unused)")
  c=$(ask "Context window in tokens (8192 / 32768 / 131072)" "$(curdef LLM_CONTEXT_WINDOW 131072)")
  setenv LLM_BASE_URL "$b"; setenv LLM_MODEL "$m"; setenv LLM_API_KEY "$k"; setenv LLM_CONTEXT_WINDOW "$c"
  saved
}
e_gov() {
  card "Governance · Agent Control  ·  the runtime guardrails"
  li "Checks every tool call + model turn before it happens (fail-closed)."
  li "5 starter controls seed at boot. After that you add/edit/remove them"
  li "LIVE in the Agent Control UI (no restart) - the setup does not limit you."
  local g t
  g=$(ask "Enforce governance? true = on, false = run raw" "$(curdef GOVERNANCE_ENABLED true)")
  t=$(ask "Demo deny-token (blocks any tool input containing it)" "$(curdef FORBIDDEN_TOKEN FORBIDDEN)")
  s=$(ask "Seed the 5 starter controls at boot? true/false" "$(curdef AC_SEED_STARTER true)")
  setenv GOVERNANCE_ENABLED "$g"; setenv FORBIDDEN_TOKEN "$t"; setenv AC_SEED_STARTER "$s"
  ok "manage controls live after launch:  http://127.0.0.1:$(curdef AC_PORT 8181)"
  saved
}
e_galileo() {
  card "Observability · Galileo  ·  LLM tracing + scoring   (optional)"
  howto "sign in, then Settings › API Keys › Create API Key. Make a Project too."
  li "A 'project' is a Galileo workspace; your LLM traces + scores land in it."
  link "https://app.galileo.ai"
  local gk gp
  gk=$(asksec "Galileo API key (blank keeps · - disables)")
  [ "$gk" = "-" ] && setenv GALILEO_API_KEY "" || { [ -n "$gk" ] && setenv GALILEO_API_KEY "$gk"; }
  if [ -n "$(cur GALILEO_API_KEY)" ]; then gp=$(ask "Galileo project name" "$(curdef GALILEO_PROJECT OpenClaw_Galileo)"); setenv GALILEO_PROJECT "$gp"; fi
  saved
}
e_splunk() {
  card "Observability · Splunk  ·  two destinations, pick either or both"
  li "(a) events            → Splunk HEC (classic log index)"
  li "(b) metrics + traces  → Splunk Observability Cloud (a separate product)"
  printf '\n'
  local a
  a=$(ask "Set up (a) Splunk HEC events? y / n / - to disable" "$([ -n "$(cur SPLUNK_HEC_URL)" ] && echo y || echo n)")
  case "$a" in
    [Yy]*) howto "Splunk › Settings › Data Inputs › HTTP Event Collector › New Token."
           local su st si
           su=$(ask "HEC URL  (https://<host>:8088/services/collector/event)" "$(cur SPLUNK_HEC_URL)"); setenv SPLUNK_HEC_URL "$su"
           st=$(ask "HEC token" "$(curdef SPLUNK_HEC_TOKEN 00000000-0000-0000-0000-000000000001)"); setenv SPLUNK_HEC_TOKEN "$st"
           si=$(ask "Index" "$(curdef SPLUNK_INDEX main)"); setenv SPLUNK_INDEX "$si" ;;
    -)     setenv SPLUNK_HEC_URL "" ;;
  esac
  printf '\n'
  local o
  o=$(ask "Set up (b) Splunk Observability Cloud? y / n / - to disable" "$([ -n "$(cur SPLUNK_O11Y_REALM)" ] && echo y || echo n)")
  case "$o" in
    [Yy]*) howto "app.<realm>.signalfx.com › Settings › Access Tokens (an org access token)."
           li "realm = your region, from your o11y URL. Examples: us0, us1, eu0, jp0."
           local so ot os
           so=$(ask "o11y realm" "$(curdef SPLUNK_O11Y_REALM us1)"); setenv SPLUNK_O11Y_REALM "$so"
           ot=$(asksec "o11y access token (blank keeps)"); [ -n "$ot" ] && setenv SPLUNK_O11Y_TOKEN "$ot"
           os=$(ask "service name" "$(curdef SPLUNK_O11Y_SERVICE openclaw)"); setenv SPLUNK_O11Y_SERVICE "$os" ;;
    -)     setenv SPLUNK_O11Y_REALM "" ;;
  esac
  saved
}
e_telegram() {
  card "Channel · Telegram  ·  a way for people to chat with the agent   (optional)"
  howto "in Telegram open @BotFather › /newbot › name it › copy the token."
  li "A channel is how humans reach the agent. Only allow-listed ids may chat."
  link "https://t.me/BotFather"
  local tg tok ida cid tgid
  tg=$(asksec "Bot token (blank keeps · - disables)")
  [ "$tg" = "-" ] && { setenv TELEGRAM_BOT_TOKEN ""; saved; return; }
  [ -n "$tg" ] && setenv TELEGRAM_BOT_TOKEN "$tg"
  tok=$(cur TELEGRAM_BOT_TOKEN)
  if [ -n "$tok" ]; then
    ida=$(ask "Capture your Telegram id now by messaging the bot? Y=auto, n=type" "Y")
    cid=""; case "$ida" in [Nn]*) : ;; *) cid=$(capture_telegram_id "$tok"); [ -n "$cid" ] && ok "your id: $cid";; esac
    tgid=$(ask "Allowed id(s), comma-separated (only these may chat)" "${cid:-$(cur TELEGRAM_ALLOW)}"); setenv TELEGRAM_ALLOW "$tgid"
  fi
  saved
}
e_addch() {
  card "Channel · Add another  ·  more ways for people to reach the agent"
  li "OpenClaw supports many channels: Slack, Discord, WhatsApp, Signal, Teams, Matrix, ..."
  li "Telegram is wired in this build; another channel is one config block away."
  li "Say which one you want and it gets wired the same way Telegram was."
  link "https://docs.openclaw.ai  (Channels)"
  pause
}
e_webex() {
  card "Tool plugin · Webex  ·  a capability the agent can call   (optional)"
  howto "developer.webex.com › My Webex Apps › Create a New App › Integration."
  li "A tool plugin is something the agent can DO; every call is governed."
  li "Set the Redirect URI (below), pick scopes (spark:all + meeting:*), Save,"
  li "then copy the Client ID + Client Secret."
  link "https://developer.webex.com/my-apps/new/integration"
  local wc ws wr
  wc=$(ask "Client ID (blank keeps · - disables)" "$(cur WEBEX_CLIENT_ID)")
  [ "$wc" = "-" ] && { setenv WEBEX_CLIENT_ID ""; saved; return; }
  setenv WEBEX_CLIENT_ID "$wc"
  if [ -n "$wc" ]; then
    ws=$(asksec "Client Secret (blank keeps)"); [ -n "$ws" ] && setenv WEBEX_CLIENT_SECRET "$ws"
    wr=$(ask "Redirect URI" "$(curdef WEBEX_REDIRECT_URI http://localhost:8765/callback)"); setenv WEBEX_REDIRECT_URI "$wr"
    li "after launch, authorize once:  docker compose exec openclaw node /root/openclaw-webex/oauth-setup.mjs url"
  fi
  saved
}
e_addtool() {
  card "Tool plugin · Add another  ·  more things the agent can do"
  li "Two ways to add capabilities (all pass Agent Control like Webex does):"
  li "  • an official OpenClaw plugin (installs on demand)"
  li "  • an MCP server (point OpenClaw at any MCP endpoint)"
  li "Webex is the tool plugin wired here; more can be added the same way."
  link "https://docs.openclaw.ai  (Plugins / MCP)"
  pause
}
edit() { case "$1" in
  model)e_model;; gov)e_gov;; galileo)e_galileo;; splunk)e_splunk;;
  telegram)e_telegram;; addch)e_addch;; webex)e_webex;; addtool)e_addtool;; esac; }

# ── credential test (best-effort, reachable checks only) ─────────────────────
test_item() {
  card "Test credentials · $1"
  case "$1" in
    model)
      local u; u="$(cur LLM_BASE_URL | sed 's|host.docker.internal|localhost|')"
      curl -sf --max-time 6 "${u%/}/models" >/dev/null 2>&1 && ok "LLM endpoint responds ($u)" || bad "no response at $u" ;;
    telegram)
      local tok h; tok="$(cur TELEGRAM_BOT_TOKEN)"
      [ -z "$tok" ] && { li "not configured"; } || {
        h=$(curl -s --max-time 6 "https://api.telegram.org/bot$tok/getMe" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("@"+d["result"]["username"] if d.get("ok") else "")' 2>/dev/null)
        [ -n "$h" ] && ok "Telegram bot $h authenticates" || bad "Telegram token rejected"; } ;;
    splunk)
      local hec o realm tok
      hec="$(cur SPLUNK_HEC_URL)"; realm="$(cur SPLUNK_O11Y_REALM)"; tok="$(cur SPLUNK_O11Y_TOKEN)"
      if [ -n "$hec" ]; then
        case "$hec" in *localhost*|*127.0.0.1*|*http://*-*) li "HEC ($hec) resolves only inside the stack; validated at launch." ;;
          *) curl -sk --max-time 6 -o /dev/null -w '' -H "Authorization: Splunk $(cur SPLUNK_HEC_TOKEN)" -d '{"event":"setup-test"}' "$hec" && ok "HEC reachable" || bad "HEC did not accept the test event" ;; esac
      else li "HEC not configured"; fi
      if [ -n "$realm" ] && [ -n "$tok" ]; then
        local code; code=$(curl -s --max-time 6 -o /dev/null -w '%{http_code}' -X POST "https://ingest.$realm.signalfx.com/v2/datapoint" -H "X-SF-Token: $tok" -H 'Content-Type: application/json' -d '{"counter":[{"metric":"openclaw.setup.test","value":1}]}' 2>/dev/null)
        [ "$code" = "200" ] && ok "o11y realm $realm accepts (HTTP 200)" || bad "o11y realm $realm rejected (HTTP $code)"
      else li "o11y not configured"; fi ;;
    galileo) li "No cheap key check; Galileo validates on the first trace. After launch:"; li "docker compose exec openclaw tail -f /root/galileo-fwd.log" ;;
    webex)   li "Validated by the one-time OAuth after launch:"; li "docker compose exec openclaw node /root/openclaw-webex/oauth-setup.mjs verify" ;;
    *)       li "Nothing to test for this item." ;;
  esac
  printf '\n'; pause
}

gen_secrets() {
  local g; g() { openssl rand -hex "${1:-24}"; }
  setblank() { grep -qE "^$1=.+" .env && return 0; setenv "$1" "$2"; }
  setblank AC_PG_PASSWORD "$(g)"; setblank AC_API_KEY "ac_$(g)"; setblank AC_ADMIN_KEY "acadmin_$(g)"
  setblank AC_SESSION_SECRET "$(g 32)"; setblank GATEWAY_TOKEN "$(g)"
}

# ── board model ──────────────────────────────────────────────────────────────
dot() { case "$1" in "+") printf '%b' "${MG}＋${R}";; "") printf '%b' "${DIM}○${R}";; *) printf '%b' "${GR}●${R}";; esac; }
flag() { case "$1" in
  model) echo x;;
  gov)   [ "$(cur GOVERNANCE_ENABLED)" = true ] && echo x;;
  galileo) cur GALILEO_API_KEY;;
  splunk) { [ -n "$(cur SPLUNK_HEC_URL)" ] || [ -n "$(cur SPLUNK_O11Y_REALM)" ]; } && echo x;;
  telegram) cur TELEGRAM_BOT_TOKEN;;
  webex) cur WEBEX_CLIENT_ID;;
  addch|addtool) echo "+";;
esac; }
val() { case "$1" in
  model) echo "$(cur LLM_MODEL) · $(cleanurl "$(cur LLM_BASE_URL)") · ctx $(humanctx "$(cur LLM_CONTEXT_WINDOW)")";;
  gov)   [ "$(cur GOVERNANCE_ENABLED)" = true ] && echo "ENFORCING · fail-closed · 5 starter controls (edit live at :$(curdef AC_PORT 8181))" || echo "${DIM}off (running raw, no guardrails)${R}";;
  galileo) [ -n "$(cur GALILEO_API_KEY)" ] && echo "project ${B}$(cur GALILEO_PROJECT)${R} — your LLM traces + scores land here" || echo "${DIM}off (no LLM tracing)${R}";;
  splunk)
    local h o; h="$(cur SPLUNK_HEC_URL)"; o="$(cur SPLUNK_O11Y_REALM)"
    if [ -n "$h" ] && [ -n "$o" ]; then echo "events → HEC (index $(cur SPLUNK_INDEX)) · metrics → o11y (realm $o)"
    elif [ -n "$h" ]; then echo "events → HEC (index $(cur SPLUNK_INDEX))"
    elif [ -n "$o" ]; then echo "metrics + traces → o11y (realm $o)"
    else echo "${DIM}off (no Splunk)${R}"; fi;;
  telegram) [ -n "$(cur TELEGRAM_BOT_TOKEN)" ] && echo "bot configured · only id(s) $(cur TELEGRAM_ALLOW) may chat" || echo "${DIM}off${R}";;
  addch) echo "${DIM}Slack · Discord · WhatsApp · Signal · Teams … (add a way in)${R}";;
  webex) [ -n "$(cur WEBEX_CLIENT_ID)" ] && echo "Webex triage tools (spaces, messages, transcripts) — governed" || echo "${DIM}off${R}";;
  addtool) echo "${DIM}official plugin · MCP server · custom (add a capability)${R}";;
esac; }

MENU=(
  "H:AGENT:the model your agent reasons with"
  "I:model:Model"
  "H:GOVERNANCE:every tool call and model turn is checked, fail-closed"
  "I:gov:Agent Control"
  "H:OBSERVABILITY:optional — where traces, metrics and events go"
  "I:galileo:Galileo"
  "I:splunk:Splunk"
  "H:CHANNELS:how people reach the agent"
  "I:telegram:Telegram"
  "I:addch:Add channel"
  "H:TOOLS & PLUGINS:what the agent can do (all governed)"
  "I:webex:Webex"
  "I:addtool:Add tool"
)
ITEM_IDS=(); for e in "${MENU[@]}"; do [ "${e%%:*}" = I ] && { r="${e#*:}"; ITEM_IDS+=("${r%%:*}"); }; done
NITEMS=${#ITEM_IDS[@]}

board() {
  cls
  printf '\n  %s\n'   "${CY}${B}openclaw-governed · setup${R}"
  printf '  %s\n'     "${DIM}Everything is pre-wired. Fill in credentials to switch each piece on.${R}"
  local ii=-1 e type rest id label pad
  for e in "${MENU[@]}"; do
    type="${e%%:*}"; rest="${e#*:}"
    if [ "$type" = "H" ]; then
      printf '\n  %s  %s\n' "${CY}${B}${rest%%:*}${R}" "${DIM}${rest#*:}${R}"
    else
      id="${rest%%:*}"; label="${rest#*:}"; ii=$((ii+1)); pad=$(printf '%-13s' "$label")
      if [ "$ii" = "$SEL" ]; then
        printf '   %b %b  %b\n' "${CY}${B}▸${R}" "$(dot "$(flag "$id")")" "${B}${pad}${R} $(val "$id")"
      else
        printf '     %b  %s %s\n' "$(dot "$(flag "$id")")" "$pad" "$(val "$id")"
      fi
    fi
  done
  printf '\n%s\n' "$HR"
  printf '    %b move  %b edit  %b test creds  %b launch  %b quit\n' "${B}↑↓${R}" "${B}⏎${R}" "${B}t${R}" "${GR}${B}L${R}" "${B}Q${R}"
}

getkey() {
  local k rest
  IFS= read -rsn1 k || { printf quit; return; }
  if [ "$k" = $'\e' ]; then IFS= read -rsn2 -t 0.1 rest || rest=""; case "$rest" in *A) printf up;; *B) printf down;; *) printf esc;; esac; return; fi
  case "$k" in "") printf enter;; [Qq]) printf quit;; [Ll]) printf launch;; [Tt]) printf test;; *) printf other;; esac
}

# ── loop ─────────────────────────────────────────────────────────────────────
SEL=0
while true; do
  board
  case "$(getkey)" in
    up)     SEL=$(( SEL>0 ? SEL-1 : NITEMS-1 ));;
    down)   SEL=$(( SEL<NITEMS-1 ? SEL+1 : 0 ));;
    enter)  edit "${ITEM_IDS[$SEL]}";;
    test)   test_item "${ITEM_IDS[$SEL]}";;
    launch) gen_secrets; cls; exec ./up.sh;;
    quit)   gen_secrets; cls; printf '  %s  Launch:  %s   ·   status:  %s\n\n' "${GR}Saved to .env.${R}" "${B}./up.sh${R}" "${B}./bin/status.sh${R}"; exit 0;;
    *) ;;
  esac
done
