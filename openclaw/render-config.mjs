// Renders ~/.openclaw/openclaw.json from environment variables at container start.
// This is what wires OpenClaw to your LLM, to Agent Control (the governor),
// and turns on the cacheTrace that the Galileo forwarder reads.
import fs from "node:fs";
import path from "node:path";

const env = process.env;
const home = env.OPENCLAW_HOME || "/root/.openclaw";
fs.mkdirSync(home, { recursive: true });

const LLM_BASE  = env.LLM_BASE_URL || "http://host.docker.internal:8000/v1";
const LLM_MODEL = env.LLM_MODEL    || "openai/gpt-oss-120b";
const LLM_KEY   = env.LLM_API_KEY  || "unused";
const AC_URL    = env.AC_SERVER_URL || "http://server:8000";
const AC_KEY    = env.AC_PLUGIN_API_KEY || "";
const GW_PORT   = parseInt(env.OPENCLAW_GATEWAY_PORT || "18789", 10);
const GW_TOKEN  = env.GATEWAY_TOKEN || "change-me";
const FAIL_CLOSED = (env.GOVERNANCE_FAIL_CLOSED || "true") === "true";

const cfg = {
  meta: { lastTouchedVersion: "2026.3.8" },
  models: {
    mode: "merge",
    providers: {
      inference: {
        baseUrl: LLM_BASE,
        apiKey: LLM_KEY,
        api: "openai-completions",
        models: [{
          id: LLM_MODEL,
          name: `inference/${LLM_MODEL}`,
          reasoning: false,
          input: ["text"],
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          contextWindow: 131072,
          maxTokens: 4096,
        }],
      },
    },
  },
  agents: {
    defaults: {
      model: { primary: `inference/${LLM_MODEL}` },
      skipBootstrap: true,
      compaction: { mode: "safeguard" },
      thinkingDefault: "off",
      timeoutSeconds: 600,
    },
    list: [{ id: "main", default: true }],
  },
  commands: { native: "auto", nativeSkills: "auto", restart: true, ownerDisplay: "raw" },
  gateway: {
    port: GW_PORT,
    mode: "local",
    controlUi: {
      allowedOrigins: [`http://127.0.0.1:${GW_PORT}`],
      allowInsecureAuth: true,
      dangerouslyDisableDeviceAuth: true,
    },
    auth: { mode: "token", token: GW_TOKEN },
    trustedProxies: ["127.0.0.1", "::1"],
  },
  // The governor: every tool call is checked against Agent Control. failClosed
  // means if Agent Control is unreachable, tools are BLOCKED (deny by default).
  plugins: {
    load: { paths: ["/root/plugin"] },
    entries: {
      "agent-control-openclaw-plugin": {
        enabled: true,
        config: { serverUrl: AC_URL, apiKey: AC_KEY, failClosed: FAIL_CLOSED, logLevel: "info" },
      },
    },
    installs: {
      "agent-control-openclaw-plugin": {
        source: "path", sourcePath: "/root/plugin", installPath: "/root/plugin", version: "1.8.2",
      },
    },
  },
  // cacheTrace records every LLM turn (prompt + response) to a file; the Galileo
  // forwarder turns those into scorable OpenInference spans.
  diagnostics: {
    enabled: true,
    cacheTrace: {
      enabled: true,
      filePath: "/root/cache-trace.jsonl",
      includeMessages: true,
      includePrompt: true,
      includeSystem: false,
    },
  },
};

const out = path.join(home, "openclaw.json");
fs.writeFileSync(out, JSON.stringify(cfg, null, 2), { mode: 0o600 });
console.log(`[render-config] wrote ${out} (LLM=${LLM_MODEL} @ ${LLM_BASE}, governor=${AC_URL}, failClosed=${FAIL_CLOSED})`);
