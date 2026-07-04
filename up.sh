#!/usr/bin/env bash
# Bring up the whole stack. First run generates secrets and builds images.
#   ./up.sh              # OpenClaw + Agent Control (+ Galileo if key set)
#   ./up.sh --splunk     # also run the bundled Splunk + forwarder
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { cp .env.example .env; echo "created .env from .env.example — edit LLM_* / GALILEO_API_KEY as needed"; }

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

PROFILES=()
[ "${1:-}" = "--splunk" ] && PROFILES=(--profile splunk)
[ "${WITH_SPLUNK:-}" = "1" ] && PROFILES=(--profile splunk)

echo ">> building + starting (first run pulls + compiles OpenClaw from source — several minutes)"
docker compose "${PROFILES[@]}" up -d --build

# shellcheck disable=SC1091
set -a; . ./.env; set +a
cat <<EOF

============================================================
  openclaw-governed is UP
============================================================
  Agent Control (governor UI)  http://localhost:${AC_PORT:-8181}
      admin key:               ${AC_ADMIN_KEY}
  OpenClaw gateway             http://localhost:${OPENCLAW_GATEWAY_PORT:-18789}
$( [ -n "${GALILEO_API_KEY:-}" ] && echo "  Galileo feed                 ON  -> project ${GALILEO_PROJECT}" || echo "  Galileo feed                 off (set GALILEO_API_KEY in .env to enable)" )
$( [ "${PROFILES[*]:-}" = "--profile splunk" ] && echo "  Splunk                       http://localhost:${SPLUNK_PORT:-8090}  (user: admin)" || echo "  Splunk                       not started (run ./up.sh --splunk)" )

  Try it:   docker compose exec openclaw \\
              bash -lc 'cd /root/ocsrc && node scripts/run-node.mjs agent --agent main -m "list the files in /root"'
  Full usage + how a BLOCK looks:  see docs/USAGE.md
============================================================
EOF
