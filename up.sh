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
  LOCAL_MODEL=1; PROFILES+=(--profile models)
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    CF+=(-f compose.gpu.yml); echo "   local model: GPU detected, Ollama will use it"
  else
    echo "   local model: no GPU, Ollama runs on CPU (use a small model like qwen2.5:1.5b)"
  fi
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
