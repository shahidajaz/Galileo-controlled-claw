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
const GOV_ENABLED = (env.GOVERNANCE_ENABLED || "true") === "true";  // false = run OpenClaw ungoverned (no plugin)
const LLM_GOV = (env.LLM_GOVERNANCE || "true") === "true";
const LLM_PROXY = env.LLM_PROXY_URL || "";
const TG_TOKEN = env.TELEGRAM_BOT_TOKEN || "";  // Telegram channel: drive the agent from chat (blank = off)
const TG_ALLOW = (env.TELEGRAM_ALLOW || "").split(",").map((s) => s.trim()).filter(Boolean);  // your numeric Telegram id(s)
// Governed delegate: a Manager (main) that may hand focused work to ONE Helper subagent.
// Topology is declared HERE (who may spawn whom); the POLICY on what may be delegated is
// enforced by Agent Control on the sessions_spawn tool call, same fail-closed engine as
// every other tool. So delegation is a first-class governed + audited edge, not a side door.
const DELEGATE = (env.DELEGATE_ENABLED || "true") === "true";
// route reasoning through the LLM-layer governance proxy when governance is on
const LLM_EFFECTIVE = (GOV_ENABLED && LLM_GOV && LLM_PROXY) ? LLM_PROXY : LLM_BASE;
const CTX = parseInt(env.LLM_CONTEXT_WINDOW || "131072", 10);   // match the model's real max context
const MAXTOK = Math.min(2048, Math.floor(CTX / 4));  // reserve less for output -> more room for input (triage pulls lots of message text)

const cfg = {
  meta: { lastTouchedVersion: "2026.3.8" },
  models: {
    mode: "merge",
    providers: {
      inference: {
        baseUrl: LLM_EFFECTIVE,
        apiKey: LLM_KEY,
        api: "openai-completions",
        models: [{
          id: LLM_MODEL,
          name: `inference/${LLM_MODEL}`,
          reasoning: false,
          input: ["text"],
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          contextWindow: CTX,
          maxTokens: MAXTOK,
        }],
      },
    },
  },
  agents: {
    defaults: {
      model: { primary: `inference/${LLM_MODEL}` },
      // Inject the workspace AGENTS.md (the Webex operating guide) into the system
      // prompt at session start. Without this the agent only sees bare tool
      // descriptions and won't reach for the webex_* tools. The workspace holds
      // just AGENTS.md, so the bootstrap stays small.
      skipBootstrap: false,
      workspace: env.AGENT_WORKSPACE || "/root/agent-workspace",
      compaction: { mode: "safeguard" },
      thinkingDefault: "off",
      timeoutSeconds: 600,
      // Safety rails on delegation itself: shallow tree, few children. Blast-radius bound
      // even before policy. The governor sits on top of these for content-level control.
      subagents: { maxSpawnDepth: 2, maxChildrenPerAgent: 3, runTimeoutSeconds: 300 },
    },
    // Manager + Helper when DELEGATE is on. The Manager may spawn ONLY "helper"
    // (allowAgents allowlist); the Helper cannot spawn anyone (no allowAgents). Both run
    // the same governed model + the same tool gate, so the Helper is as governed as the Manager.
    list: DELEGATE
      ? [
          { id: "main", default: true, subagents: { allowAgents: ["helper"] } },
          { id: "helper", workspace: env.HELPER_WORKSPACE || "/root/agent-workspace-helper" },
        ]
      : [{ id: "main", default: true }],
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
  plugins: (() => {
    const paths = [], entries = {}, installs = {}, allow = [];
    if (GOV_ENABLED) {  // Agent Control governor (tool gate). Webex tools ride through this.
      paths.push("/root/plugin");
      allow.push("agent-control-openclaw-plugin");
      entries["agent-control-openclaw-plugin"] = {
        enabled: true,
        config: { serverUrl: AC_URL, apiKey: AC_KEY, failClosed: FAIL_CLOSED, logLevel: "info" },
      };
      installs["agent-control-openclaw-plugin"] = {
        source: "path", sourcePath: "/root/plugin", installPath: "/root/plugin", version: "1.8.2",
      };
    }
    if ((env.WEBEX_ENABLED || "true") === "true") {  // governed Webex tools (BYO-per-user)
      paths.push("/root/openclaw-webex");
      allow.push("openclaw-webex");
      entries["openclaw-webex"] = { enabled: true };
      installs["openclaw-webex"] = {
        source: "path", sourcePath: "/root/openclaw-webex", installPath: "/root/openclaw-webex", version: "0.1.0",
      };
    }
    return { load: { paths }, entries, installs, allow };
  })(),
  // cacheTrace records every LLM turn (prompt + response) to a file; the Galileo
  // forwarder turns those into scorable OpenInference spans.
  // Telegram channel (only when a bot token is set): messages route to agent "main",
  // so they pass the same governance + observability as the CLI.
  ...(TG_TOKEN ? { channels: { telegram: {
    enabled: true, botToken: TG_TOKEN,
    ...(TG_ALLOW.length
      ? { dmPolicy: "allowlist", allowFrom: TG_ALLOW, groupPolicy: "allowlist", groupAllowFrom: TG_ALLOW }
      : { dmPolicy: "pairing" }),
  } } } : {}),
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
console.log(`[render-config] wrote ${out} (LLM=${LLM_MODEL} @ ${LLM_EFFECTIVE}${LLM_EFFECTIVE === LLM_PROXY ? " [governed proxy]" : ""}, governed=${GOV_ENABLED}, governor=${AC_URL}, failClosed=${FAIL_CLOSED})`);
