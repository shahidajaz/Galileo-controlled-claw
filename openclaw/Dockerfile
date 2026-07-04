# OpenClaw, governed by Agent Control, with a Galileo forwarder baked in.
# Both OpenClaw and the Agent Control plugin run FROM SOURCE (loaded via jiti);
# there is deliberately no build step — clone + install is enough.
FROM node:24-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates procps curl \
 && rm -rf /var/lib/apt/lists/*
RUN corepack enable

ARG OPENCLAW_REF=v2026.3.8
ARG PLUGIN_REF=v1.8.2

WORKDIR /root

# OpenClaw itself (runs from source via scripts/run-node.mjs — no build).
RUN git clone --depth 1 --branch ${OPENCLAW_REF} https://github.com/openclaw/openclaw.git /root/ocsrc \
 && cd /root/ocsrc && pnpm install

# The Agent Control plugin (index.ts -> src/plugin-entry.ts, loaded via jiti).
RUN git clone --depth 1 --branch ${PLUGIN_REF} https://github.com/agentcontrol/openclaw-plugin.git /root/plugin \
 && cd /root/plugin && npm ci

COPY render-config.mjs galileo-forwarder.mjs entrypoint.sh /opt/oc/
RUN chmod +x /opt/oc/entrypoint.sh

ENV OPENCLAW_GATEWAY_PORT=18789
EXPOSE 18789
ENTRYPOINT ["/opt/oc/entrypoint.sh"]
