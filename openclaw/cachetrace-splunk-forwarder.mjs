// OpenClaw cacheTrace -> Splunk HEC, one event per completed LLM turn.
// Reads /root/cache-trace.jsonl (the same file the Galileo forwarder reads) and
// POSTs each new turn to the Splunk HTTP Event Collector as sourcetype openclaw:llm.
// Runs inside the openclaw container. Active ONLY when SPLUNK_HEC_URL is set, so
// Splunk can hold BOTH lenses: governance decisions (from Agent Control's Postgres,
// via the splunk-forwarder service) AND the raw LLM turns (from here).
import fs from "node:fs";

const TRACE = process.env.TRACE_FILE || "/root/cache-trace.jsonl";
const STATE = process.env.SPLUNK_LLM_STATE_FILE || "/root/.splunk_llm_fwd_state";
const HEC = process.env.SPLUNK_HEC_URL;
const TOKEN = process.env.SPLUNK_HEC_TOKEN || "";
const INDEX = process.env.SPLUNK_INDEX || "main";
const SOURCETYPE = process.env.SPLUNK_LLM_SOURCETYPE || "openclaw:llm";

if (!HEC) {
  console.log("[splunk-llm] SPLUNK_HEC_URL not set; LLM-turn forwarder idle");
  process.exit(0);
}

const textOf = (c) => typeof c === "string" ? c
  : Array.isArray(c) ? c.map((p) => (p && p.type === "text" ? p.text : (p && p.text) || "")).join("")
  : "";

function loadState() { try { return JSON.parse(fs.readFileSync(STATE, "utf8")); } catch { return { seen: [] }; } }
function saveState(s) { fs.writeFileSync(STATE, JSON.stringify(s)); }

function turnToEvent(turn) {
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
  const parsed = msgs[ai].timestamp ? Date.parse(msgs[ai].timestamp) : NaN;
  const evt = {
    sourcetype: SOURCETYPE, index: INDEX, source: "openclaw",
    event: {
      agent: "openclaw-agent:main", kind: "llm_turn", model,
      prompt, completion,
      prompt_tokens: pt, completion_tokens: ct, total_tokens: pt + ct,
    },
  };
  if (Number.isFinite(parsed)) evt.time = parsed / 1000;
  return evt;
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
    const ev = turnToEvent(o);
    if (ev) out.push({ id, ev });
  }
  return out;
}

async function post(events) {
  const body = events.map((e) => JSON.stringify(e)).join("\n");
  const res = await fetch(HEC, {
    method: "POST",
    headers: { Authorization: `Splunk ${TOKEN}`, "Content-Type": "application/json" },
    body,
  });
  return { code: res.status, body: await res.text() };
}

async function tick() {
  const state = loadState();
  const items = newTurns(state);
  if (!items.length) return 0;
  const r = await post(items.map((i) => i.ev));
  if (r.code >= 200 && r.code < 300) {
    state.seen.push(...items.map((i) => i.id));
    if (state.seen.length > 5000) state.seen = state.seen.slice(-5000);  // must exceed the rotation tail (2000 lines) or kept turns re-send
    saveState(state);
    console.log(`${new Date().toISOString()} sent ${items.length} LLM turn(s) -> Splunk (HTTP ${r.code})`);
  } else {
    console.log(`${new Date().toISOString()} Splunk POST failed HTTP ${r.code}: ${r.body.slice(0, 150)}`);
  }
  return items.length;
}

console.log(`splunk-llm-forwarder started; HEC=${HEC} sourcetype=${SOURCETYPE} index=${INDEX}`);
for (;;) {
  try { await tick(); } catch (e) { console.log("err", e.message); }
  await new Promise((r) => setTimeout(r, 5000));
}
