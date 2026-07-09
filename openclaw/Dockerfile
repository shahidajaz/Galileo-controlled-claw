# OpenClaw, governed by Agent Control, with a Galileo forwarder baked in.
# Both OpenClaw and the Agent Control plugin run FROM SOURCE (loaded via jiti);
# there is deliberately no build step, clone + install is enough.
FROM node:24.18.0-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates procps curl \
 && rm -rf /var/lib/apt/lists/*
RUN corepack enable

ARG OPENCLAW_REF=v2026.3.8
ARG PLUGIN_REF=v1.8.2

WORKDIR /root

# OpenClaw itself (runs from source via scripts/run-node.mjs, no build).
RUN git clone --depth 1 --branch ${OPENCLAW_REF} https://github.com/openclaw/openclaw.git /root/ocsrc \
 && cd /root/ocsrc && pnpm install --frozen-lockfile

# The Agent Control plugin (index.ts -> src/plugin-entry.ts, loaded via jiti).
RUN git clone --depth 1 --branch ${PLUGIN_REF} https://github.com/agentcontrol/openclaw-plugin.git /root/plugin \
 && cd /root/plugin && npm ci

COPY openclaw/render-config.mjs openclaw/galileo-forwarder.mjs openclaw/cachetrace-splunk-forwarder.mjs openclaw/cachetrace-o11y-forwarder.mjs openclaw/entrypoint.sh /opt/oc/
RUN chmod +x /opt/oc/entrypoint.sh

# Agent operating guide: OpenClaw injects this workspace AGENTS.md into the system
# prompt at session start (and re-injects its Session Startup / Red Lines sections
# after compaction). This is what makes the agent reach for the webex_* tools.
COPY openclaw/agent-workspace /root/agent-workspace
# Helper subagent's own workspace (focused read-only role); the Manager delegates to it.
COPY openclaw/agent-workspace-helper /root/agent-workspace-helper

# Governed Webex tools plugin (baked in -> root-owned, passes OpenClaw's plugin
# ownership check; loaded from source via jiti like the agent-control plugin).
COPY webex /root/openclaw-webex
RUN cd /root/openclaw-webex && npm install --omit=dev

ENV OPENCLAW_GATEWAY_PORT=18789
EXPOSE 18789
ENTRYPOINT ["/opt/oc/entrypoint.sh"]
