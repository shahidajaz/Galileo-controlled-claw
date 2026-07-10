#!/usr/bin/env bash
# Bring up the whole stack. First run generates secrets and builds images.
#   ./up.sh              # OpenClaw + Agent Control (+ Galileo if key set)
#   ./up.sh --splunk     # also run the bundled Splunk + forwarder
set -euo pipefail
cd "$(dirname "$0")"

# Guard against a STRAY docker-compose.override.yml. That file is box-specific
# (gitignored) and wires services onto external Docker networks that exist only
# where it was authored. up.sh itself ignores it (we always pass -f compose.yml),
# but a copy carried to another machine would break a bare `docker compose` command.
# So: if it is present but its external networks are missing, this is almost
# certainly a stray copy, stop with a clear message instead of letting it bite later.
# On the box where those networks exist, this passes silently. Override with ALLOW_OVERRIDE=1.
if [ -f docker-compose.override.yml ] && [ "${ALLOW_OVERRIDE:-0}" != "1" ]; then
  missing=""
  for net in $(grep -E '^[[:space:]]+name:[[:space:]]' docker-compose.override.yml 2>/dev/null | awk '{print $2}'); do
    docker network inspect "$net" >/dev/null 2>&1 || missing="$missing $net"
  done
  if [ -n "$missing" ]; then
    echo "ERROR: docker-compose.override.yml is present but its external network(s) do not exist:${missing}" >&2
    echo "       That file is box-specific and should not be copied to another machine." >&2
    echo "       Fix: remove it here ->  rm docker-compose.override.yml   (or set ALLOW_OVERRIDE=1 to bypass)" >&2
    exit 1
  fi
fi

# Preflight: check the essentials and fail early with a clear message instead of
# dying halfway through a multi-minute build. Portable across macOS and Linux.
preflight() {
  local err=0
  if ! command -v docker >/dev/null 2>&1; then
    echo "MISSING: docker. Install Docker Desktop (Mac/Windows) or Docker Engine (Linux)." >&2; err=1
  else
    docker info >/dev/null 2>&1 || { echo "Docker is installed but the daemon is not running. Start Docker Desktop and retry." >&2; err=1; }
    docker compose version >/dev/null 2>&1 || { echo "MISSING: Docker Compose v2 (the 'docker compose' subcommand)." >&2; err=1; }
  fi
  command -v python3 >/dev/null 2>&1 || { echo "MISSING: python3 (used to pick free ports)." >&2; err=1; }
  command -v openssl >/dev/null 2>&1 || { echo "MISSING: openssl (used to generate secrets)." >&2; err=1; }
  command -v curl    >/dev/null 2>&1 || echo "NOTE: curl not found; the readiness wait is skipped (not fatal)." >&2
  case "$(uname -m)" in
    arm64|aarch64) echo "NOTE: ARM64 host. Images build native; first build is slow, and the optional bundled Splunk image is amd64 (emulated). The core run is fine." >&2 ;;
  esac
  if command -v df >/dev/null 2>&1; then
    avail="$(df -Pk . 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}')"
    if [ -n "${avail:-}" ] && [ "$avail" -lt 6 ]; then
      echo "NOTE: only ~${avail} GB free here; the default model plus images need ~5-6 GB." >&2
    fi
  fi
  [ "$err" = 0 ] || { echo "Preflight failed. Fix the MISSING item(s) above and rerun ./up.sh" >&2; exit 1; }
}
preflight

[ -f .env ] || { cp .env.example .env; echo "created .env from .env.example, edit LLM_* / GALILEO_API_KEY as needed"; }

gen() { openssl rand -hex "${1:-24}"; }
setblank() {  # setblank KEY VALUE : fill KEY in .env only when it is blank/missing
  local k="$1" v="$2"
  grep -qE "^${k}=.+" .env && return 0
  if grep -qE "^${k}=" .env; then sed -i.bak "s|^${k}=.*|${k}=${v}|" .env && rm -f .env.bak; else echo "${k}=${v}" >> .env; fi
}
setblank AC_PG_PASSWORD    "$(gen)"
setblank AC_API_KEY        "ac_$(gen)"
setblank AC_ADMIN_KEY      "acadmin_$(gen)"
setblank AC_SESSION_SECRET "$(gen 32)"
setblank GATEWAY_TOKEN     "$(gen)"

# Auto-pick free host ports so several governed stacks never collide (e.g. running
# this next to the fleet). Uses python3 (already required by the portal); works on
# Mac + Linux + WSL. Only when THIS stack is not already running, so a rebuild keeps ports.
setkv() { local k="$1" v="$2"; if grep -qE "^${k}=" .env; then sed -i.bak "s|^${k}=.*|${k}=${v}|" .env && rm -f .env.bak; else echo "${k}=${v}" >> .env; fi; }
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
# DefenseClaw detector configured -> run the reachability shim so the AC container can
# reach your gateway (skip if your gateway already binds a Docker-reachable address).
grep -qE '^DEFENSECLAW_TOKEN=.+' .env && PROFILES+=(--profile defenseclaw)

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
