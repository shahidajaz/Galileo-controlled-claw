#!/usr/bin/env bash
# Bring up the whole stack. First run generates secrets and builds images.
#   ./up.sh              # OpenClaw + Agent Control (+ Galileo if key set)
#   ./up.sh --splunk     # also run the bundled Splunk + forwarder
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { cp .env.example .env; echo "created .env from .env.example, edit LLM_* / GALILEO_API_KEY as needed"; }

gen() { openssl rand -hex "${1:-24}"; }
setblank() {  # setblank KEY VALUE : fill KEY in .env only when it is blank/missing
  local k="$1" v="$2"
  grep -qE "^${k}=.+" .env && return 0
  if grep -qE "^${k}=" .env; then sed -i "s|^${k}=.*|${k}=${v}|" .env; else echo "${k}=${v}" >> .env; fi
}
setblank AC_PG_PASSWORD    "$(gen)"
setblank AC_API_KEY        "ac_$(gen)"
setblank AC_ADMIN_KEY      "acadmin_$(gen)"
setblank AC_SESSION_SECRET "$(gen 32)"
setblank GATEWAY_TOKEN     "$(gen)"

# Auto-pick free host ports so several governed stacks never collide (e.g. running
# this next to the fleet). Uses python3 (already required by the portal); works on
# Mac + Linux + WSL. Only when THIS stack is not already running, so a rebuild keeps ports.
setkv() { local k="$1" v="$2"; if grep -qE "^${k}=" .env; then sed -i "s|^${k}=.*|${k}=${v}|" .env; else echo "${k}=${v}" >> .env; fi; }
free_port() { local k="$1" def="$2" cur p; cur="$(grep -E "^${k}=" .env | cut -d= -f2)"; cur="${cur:-$def}"
  p="$(python3 -c 'import socket,sys
p=int(sys.argv[1])
while True:
    s=socket.socket()
    try: s.bind(("127.0.0.1",p)); s.close(); print(p); break
    except OSError: p+=1' "$cur")"
  setkv "$k" "$p"; }
if [ -z "$(docker compose -f compose.yml ps -q 2>/dev/null | head -1)" ]; then
  free_port AC_PORT 8181
  free_port OPENCLAW_GATEWAY_PORT 18789
  grep -qE '^SPLUNK_PORT=' .env && free_port SPLUNK_PORT 8090
  echo "   host ports: Agent Control=$(grep -E '^AC_PORT=' .env | cut -d= -f2), gateway=$(grep -E '^OPENCLAW_GATEWAY_PORT=' .env | cut -d= -f2)"
fi

# Compose profiles are auto-selected from .env so nobody has to memorize flags:
#   --splunk (or WITH_SPLUNK=1)  -> also run the BUNDLED Splunk container (demo/offline)
#   SPLUNK_HEC_URL set in .env    -> ship decisions to that (external) Splunk, forwarder only
#   SPLUNK_O11Y_REALM set in .env -> ship metrics to Splunk Observability Cloud
PROFILES=()
if [ "${1:-}" = "--splunk" ] || [ "${WITH_SPLUNK:-}" = "1" ]; then
  PROFILES+=(--profile splunk)
elif grep -qE '^SPLUNK_HEC_URL=.+' .env; then
  PROFILES+=(--profile splunk-hec)
fi
grep -qE '^SPLUNK_O11Y_REALM=.+' .env && PROFILES+=(--profile splunk-o11y)

# Local model mode: if the agent's LLM points at the bundled Ollama, run it and use
# the GPU when one is present. Otherwise the agent uses your external LLM_BASE_URL.
CF=(-f compose.yml); LOCAL_MODEL=0
if grep -qE '^LLM_BASE_URL=.*ollama' .env; then
  LOCAL_MODEL=1; PROFILES+=(--profile models); GPU=0
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1 && { CF+=(-f compose.gpu.yml); GPU=1; }
  # auto-pick a model by hardware if the user has not chosen one (fresh clone = blank)
  if ! grep -qE '^LLM_MODEL=.+' .env; then
    [ "$GPU" = 1 ] && setkv LLM_MODEL "qwen2.5:7b" || setkv LLM_MODEL "qwen2.5:1.5b"
  fi
  echo "   local model: $(grep -E '^LLM_MODEL=' .env | cut -d= -f2) on $([ "$GPU" = 1 ] && echo GPU || echo CPU)"
fi

# Agent Control base image (stock server from the upstream tag); our ac-server/Dockerfile
# overlays the DefenseClaw evaluator on top. Built once, then cached.
BASE="${AC_BASE_IMAGE:-openclaw-ac-base:8.2.0}"
if ! docker image inspect "$BASE" >/dev/null 2>&1; then
  echo ">> building Agent Control base image ($BASE) from source (first time, slow)..."
  docker build -t "$BASE" -f server/Dockerfile "https://github.com/agentcontrol/agent-control.git#v8.2.0" || { echo "base build failed"; exit 1; }
fi

echo ">> building + starting (first run pulls + compiles OpenClaw from source, several minutes)"
echo "   profiles: ${PROFILES[*]:-<none>}"
docker compose "${CF[@]}" "${PROFILES[@]}" up -d --build

# Download the chosen local model into Ollama (first time only; kept afterwards).
if [ "$LOCAL_MODEL" = 1 ]; then
  M=$(grep -E '^LLM_MODEL=' .env | cut -d= -f2)
  echo ">> ensuring local model present: ${M}"
  docker compose "${CF[@]}" --profile models exec -T ollama ollama pull "${M}" || \
    echo "   (could not pull ${M} yet; the portal Quick start can retry)"
fi

# Wait briefly for the governor to answer, then print the access card.
printf ">> waiting for services"
for _ in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$(grep -E '^AC_PORT=' .env | cut -d= -f2 || echo 8181)/health" >/dev/null 2>&1 && break
  printf "."; sleep 2
done
echo
./bin/access-card.sh
