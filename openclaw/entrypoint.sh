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

# LLM turns -> Splunk (only when SPLUNK_HEC_URL is set). Gives Splunk BOTH lenses:
# governance decisions (via the splunk-forwarder service) AND the raw LLM turns (here).
if [ -n "${SPLUNK_HEC_URL:-}" ]; then
  echo "[entrypoint] Splunk LLM-turn forwarder ON (index=${SPLUNK_INDEX:-main} sourcetype=openclaw:llm)"
  ( while true; do node /opt/oc/cachetrace-splunk-forwarder.mjs >> /root/splunk-llm-fwd.log 2>&1 || true; sleep 5; done ) &
else
  echo "[entrypoint] Splunk LLM-turn forwarder OFF (no SPLUNK_HEC_URL)"
fi

# LLM turns -> Splunk Observability Cloud (o11y) as traces (only when o11y creds set).
# Pairs with the o11y-forwarder service (governance decisions -> metrics) so o11y gets
# BOTH lenses. Independent of the HEC path above: a user can run HEC, o11y, or both.
if [ -n "${SPLUNK_O11Y_REALM:-}" ] && [ -n "${SPLUNK_O11Y_TOKEN:-}" ]; then
  echo "[entrypoint] o11y LLM-trace forwarder ON (realm=${SPLUNK_O11Y_REALM} service=${SPLUNK_O11Y_SERVICE:-openclaw})"
  ( while true; do node /opt/oc/cachetrace-o11y-forwarder.mjs >> /root/o11y-llm-fwd.log 2>&1 || true; sleep 5; done ) &
else
  echo "[entrypoint] o11y LLM-trace forwarder OFF (no SPLUNK_O11Y_REALM/TOKEN)"
fi

# Governed delegate: subagent spawn opens an operator/node connection to the local gateway,
# which requires device pairing. The gateway binds loopback only (mode:local), so every
# pairing request is inherently local. Auto-approve pending requests so the Manager can spawn
# the Helper with zero manual steps. Only runs when DELEGATE_ENABLED != false. approve uses
# the local table fallback, so it works even before the gateway finishes coming up.
# Governed delegate: enable subagent spawning turnkey.
# A subagent spawn opens an operator connection to the local gateway, which OpenClaw gates
# behind a one-time device pairing. This is an OpenClaw operator-auth step, ORTHOGONAL to the
# Agent Control governance gate (that stays fail-closed regardless). The gateway binds loopback
# only, so the sole device that ever connects is this box's own CLI. We prime it once: fire a
# throwaway delegation to create the operator device, then approve it. After this, the Manager
# can spawn the Helper with zero manual steps. Loopback-scoped and one-shot (not a standing
# auto-approver), so it never blesses a device that appears later during operation.
if [ "${DELEGATE_ENABLED:-true}" != "false" ]; then
  ( RN="node /root/ocsrc/scripts/run-node.mjs"
    UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    for i in $(seq 1 40); do curl -sf "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}/" >/dev/null 2>&1 && break; sleep 1; done
    sleep 3
    cd /root/ocsrc
    timeout 90 $RN agent --agent main --session-id "pair-prime-$$" \
      -m 'call sessions_spawn with agentId "helper" and task "reply OK"' >/dev/null 2>&1 || true
    n=0; for id in $($RN devices list 2>/dev/null | grep -oE "$UUID" | sort -u); do
      $RN devices approve "$id" >/dev/null 2>&1 && n=$((n+1)); done
    echo "[entrypoint] governed-delegate pairing primed (approved $n loopback operator device(s))"
  ) &
fi

# Rotate the cacheTrace so a long-lived container doesn't grow and reread it
# unbounded. Copy-truncate keeps the gateway's open write fd valid (O_APPEND);
# the forwarders dedupe kept lines by runId:seq, so the retained tail is safe.
( while true; do
    sz=$(stat -c%s /root/cache-trace.jsonl 2>/dev/null || echo 0)
    if [ "$sz" -gt "${CACHETRACE_MAX_BYTES:-52428800}" ]; then
      tail -n 2000 /root/cache-trace.jsonl > /root/.cache-trace.tmp \
        && cat /root/.cache-trace.tmp > /root/cache-trace.jsonl \
        && rm -f /root/.cache-trace.tmp
      echo "[entrypoint] rotated cache-trace.jsonl (was ${sz} bytes, kept last 2000 lines)"
    fi
    sleep 60
  done ) &

echo "[entrypoint] starting OpenClaw gateway on :${OPENCLAW_GATEWAY_PORT:-18789}"
cd /root/ocsrc
exec node scripts/run-node.mjs gateway
