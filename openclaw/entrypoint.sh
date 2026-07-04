#!/usr/bin/env bash
# OpenClaw container entrypoint:
#  1. render ~/.openclaw/openclaw.json from env
#  2. start the Galileo forwarder in the background (only if GALILEO_API_KEY is set)
#  3. run the OpenClaw gateway in the foreground (PID 1 -> restart policy revives it)
set -euo pipefail

node /opt/oc/render-config.mjs

touch /root/cache-trace.jsonl
if [ -n "${GALILEO_API_KEY:-}" ]; then
  echo "[entrypoint] Galileo forwarder ON (project=${GALILEO_PROJECT:-?} stream=${GALILEO_LOG_STREAM:-?})"
  ( while true; do node /opt/oc/galileo-forwarder.mjs >> /root/galileo-fwd.log 2>&1 || true; sleep 5; done ) &
else
  echo "[entrypoint] Galileo forwarder OFF (no GALILEO_API_KEY), Agent Control + Splunk still active"
fi

echo "[entrypoint] starting OpenClaw gateway on :${OPENCLAW_GATEWAY_PORT:-18789}"
cd /root/ocsrc
exec node scripts/run-node.mjs gateway
