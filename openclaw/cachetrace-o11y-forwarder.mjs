// OpenClaw cacheTrace -> Splunk Observability Cloud (o11y) traces, one span per LLM turn.
// Reads /root/cache-trace.jsonl (the same file the Galileo + Splunk-HEC forwarders read)
// and POSTs each new turn as a ZIPKIN JSON span to the o11y trace ingest. Runs inside the
// openclaw container. Active ONLY when SPLUNK_O11Y_REALM + SPLUNK_O11Y_TOKEN are set, so
// o11y can hold BOTH lenses: governance decisions (metrics, via the o11y-forwarder service)
// AND the raw LLM turns (traces, from here). Zipkin is what /v2/trace/otlp actually accepts.
import fs from "node:fs";
import crypto from "node:crypto";

const TRACE = process.env.TRACE_FILE || "/root/cache-trace.jsonl";
const STATE = process.env.O11Y_LLM_STATE_FILE || "/root/.o11y_llm_fwd_state";
const REALM = process.env.SPLUNK_O11Y_REALM || "";
const TOKEN = process.env.SPLUNK_O11Y_TOKEN || "";
const SERVICE = process.env.SPLUNK_O11Y_SERVICE || "openclaw";

if (!REALM || !TOKEN) {
  console.log("[o11y-llm] SPLUNK_O11Y_REALM/TOKEN not set; LLM-trace forwarder idle");
  process.exit(0);
}
const INGEST = `https://ingest.${REALM}.signalfx.com/v2/trace/otlp`;

const textOf = (c) => typeof c === "string" ? c
  : Array.isArray(c) ? c.map((p) => (p && p.type === "text" ? p.text : (p && p.text) || "")).join("")
  : "";

function loadState() { try { return JSON.parse(fs.readFileSync(STATE, "utf8")); } catch { return { seen: [] }; } }
function saveState(s) { fs.writeFileSync(STATE, JSON.stringify(s)); }

function turnToSpan(turn) {
  const msgs = turn.messages || [];
  let ai = -1;
  for (let i = msgs.length - 1; i >= 0; i--) { if (msgs[i].role === "assistant") { ai = i; break; } }
  if (ai < 0) return null;
  let ui = -1;
  for (let i = ai - 1; i >= 0; i--) { if (msgs[i].role === "user") { ui = i; break; } }
  const prompt = ui >= 0 ? textOf(msgs[ui].content) : "";
  const completion = textOf(msgs[ai].content);
  if (!completion.trim()) return null;
  const u = msgs[ai].usage || {};
  const pt = u.inputTokens ?? u.promptTokens ?? u.prompt_tokens ?? 0;
  const ct = u.outputTokens ?? u.completionTokens ?? u.completion_tokens ?? 0;
  const model = (turn.modelId || "").split("/").pop() || "unknown";
  const endMs = msgs[ai].timestamp ? Date.parse(msgs[ai].timestamp) : Date.now();
  const startMs = ui >= 0 && msgs[ui].timestamp ? Date.parse(msgs[ui].timestamp) : endMs - 1;
  const start = Number.isFinite(startMs) ? startMs : Date.now() - 1;
  const end = Number.isFinite(endMs) ? endMs : Date.now();
  const durationUs = Math.max(1, (end - start) * 1000);
  return {
    traceId: crypto.randomBytes(16).toString("hex"),
    id: crypto.randomBytes(8).toString("hex"),
    name: "llm_turn",
    timestamp: start * 1000, // micros
    duration: durationUs,
    localEndpoint: { serviceName: SERVICE },
    tags: {
      agent: "openclaw-agent:main",
      model,
      "prompt.tokens": String(pt),
      "completion.tokens": String(ct),
      "total.tokens": String(pt + ct),
      "prompt.preview": prompt.slice(0, 300),
      "completion.preview": completion.slice(0, 300),
    },
  };
}

function newTurns(state) {
  let lines;
  try { lines = fs.readFileSync(TRACE, "utf8").trim().split("\n"); } catch { return []; }
  const out = [];
  const seen = new Set(state.seen);
  for (const l of lines) {
    let o; try { o = JSON.parse(l); } catch { continue; }
    if (o.stage !== "session:after") continue;
    const id = `${o.runId}:${o.seq}`;
    if (seen.has(id)) continue;
    const sp = turnToSpan(o);
    if (sp) out.push({ id, sp });
  }
  return out;
}

async function post(spans) {
  const res = await fetch(INGEST, {
    method: "POST",
    headers: { "X-SF-Token": TOKEN, "Content-Type": "application/json" },
    body: JSON.stringify(spans),
  });
  return { code: res.status, body: await res.text() };
}

async function tick() {
  const state = loadState();
  const items = newTurns(state);
  if (!items.length) return 0;
  const r = await post(items.map((i) => i.sp));
  if (r.code >= 200 && r.code < 300) {
    state.seen.push(...items.map((i) => i.id));
    if (state.seen.length > 5000) state.seen = state.seen.slice(-5000);  // must exceed the rotation tail (2000 lines) or kept turns re-send
    saveState(state);
    console.log(`${new Date().toISOString()} sent ${items.length} LLM span(s) -> o11y (HTTP ${r.code})`);
  } else {
    console.log(`${new Date().toISOString()} o11y trace POST failed HTTP ${r.code}: ${r.body.slice(0, 150)}`);
  }
  return items.length;
}

console.log(`o11y-llm-forwarder started; ingest=${INGEST} service=${SERVICE}`);
for (;;) {
  try { await tick(); } catch (e) { console.log("err", e.message); }
  await new Promise((r) => setTimeout(r, 5000));
}
