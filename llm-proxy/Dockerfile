# LLM-layer control point: governs the OpenClaw <-> model hop via Agent Control.
FROM node:24.18.0-bookworm-slim
WORKDIR /app
COPY proxy.mjs .
EXPOSE 8100
CMD ["node", "proxy.mjs"]
