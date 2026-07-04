// OpenClaw cacheTrace -> Galileo (app.galileo.ai) as OpenInference LLM spans.
// Reads /root/cache-trace.jsonl, turns each completed LLM turn into a scorable
// GenAI span, and POSTs OTLP/JSON to the Galileo OTEL endpoint.
// Runs inside the oc-v38 container (Node built-in fetch, reaches the internet).
import fs from "node:fs";

const TRACE = process.env.TRACE_FILE || "/root/cache-trace.jsonl";
const STATE = process.env.STATE_FILE || "/root/.galileo_fwd_state";
const EP    = process.env.GALILEO_OTEL_ENDPOINT;
const KEY   = process.env.GALILEO_API_KEY;
const PROJ  = process.env.GALILEO_PROJECT;
const LS    = process.env.GALILEO_LOG_STREAM;
const ONESHOT = process.env.ONESHOT === "1";

const hex = (n) => Array.from({ length: n }, () => Math.floor(Math.random() * 16).toString(16)).join("");
const textOf = (c) => typeof c === "string" ? c
  : Array.isArray(c) ? c.map((p) => (p && p.type === "text" ? p.text : (p && p.text) || (p && p.type === "toolResult" ? "[tool result]" : ""))).join("")
  : "";

function loadState() { try { return JSON.parse(fs.readFileSync(STATE, "utf8")); } catch { return { seen: [] }; } }
function saveState(s) { fs.writeFileSync(STATE, JSON.stringify(s)); }

// One OpenInference LLM span per completed turn (last user prompt -> final assistant reply).
function turnToSpan(turn) {
  const msgs = turn.messages;
  let ai = -1;
  for (let i = msgs.length - 1; i >= 0; i--) { if (msgs[i].role === "assistant") { ai = i; break; } }
  if (ai < 0) return null;
  let ui = -1;
  for (let i = ai - 1; i >= 0; i--) { if (msgs[i].role === "user") { ui = i; break; } }
  const prompt = ui >= 0 ? textOf(msgs[ui].content) : "";
  const completion = textOf(msgs[ai].content);
  if (!completion.trim()) return null;
  const a = msgs[ai];
  const u = a.usage || {};
  const pt = u.inputTokens ?? u.promptTokens ?? u.prompt_tokens ?? 0;
  const ct = u.outputTokens ?? u.completionTokens ?? u.completion_tokens ?? 0;
  const parsed = a.timestamp ? Date.parse(a.timestamp) : NaN;
  const endMs = Number.isFinite(parsed) ? parsed : Date.now();
  const startNs = BigInt(endMs - 1000) * 1000000n;
  const endNs = BigInt(endMs) * 1000000n;
  const model = (turn.modelId || "gpt-oss-120b").split("/").pop();
  const attr = (k, v, t = "stringValue") => ({ key: k, value: { [t]: v } });
  return {
    traceId: hex(32), spanId: hex(16), name: "llm", kind: 1,
    startTimeUnixNano: startNs.toString(), endTimeUnixNano: endNs.toString(),
    attributes: [
      attr("openinference.span.kind", "LLM"),
      attr("llm.model_name", model),
      attr("llm.provider", turn.provider || "openclaw"),
      attr("llm.system", "openai"),
      attr("gen_ai.system", "openai"),
      attr("gen_ai.operation.name", "chat"),
      attr("gen_ai.request.model", model),
      attr("input.value", prompt), attr("input.mime_type", "text/plain"),
      attr("output.value", completion), attr("output.mime_type", "text/plain"),
      attr("llm.input_messages.0.message.role", "user"),
      attr("llm.input_messages.0.message.content", prompt),
      attr("llm.output_messages.0.message.role", "assistant"),
      attr("llm.output_messages.0.message.content", completion),
      attr("llm.token_count.prompt", String(pt), "intValue"),
      attr("llm.token_count.completion", String(ct), "intValue"),
      attr("llm.token_count.total", String(pt + ct), "intValue"),
      attr("agent", "openclaw-agent:main"),
      attr("governed.by", "galileo-agent-control"),
    ],
    status: { code: 1 },
  };
}

async function postSpans(spans) {
  const body = JSON.stringify({
    resourceSpans: [{
      resource: { attributes: [
        { key: "service.name", value: { stringValue: "openclaw" } },
        { key: "gen_ai.system", value: { stringValue: "openai" } },
      ] },
      scopeSpans: [{ scope: { name: "openclaw.cachetrace" }, spans }],
    }],
  });
  const res = await fetch(EP, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Galileo-API-Key": KEY, project: PROJ, logstream: LS },
    body,
  });
  const txt = await res.text();
  return { code: res.status, body: txt };
}

function newTurns(state) {
  let lines;
  try { lines = fs.readFileSync(TRACE, "utf8").trim().split("\n"); } catch { return []; }
  const out = [];
  const seen = new Set(state.seen);
  for (const l of lines) {
    let o; try { o = JSON.parse(l); } catch { continue; }
    if (o.stage !== "session:after") continue;               // completed turn only
    const id = `${o.runId}:${o.seq}`;
    if (seen.has(id)) continue;
    const span = turnToSpan(o);
    if (span) out.push({ id, span });
  }
  return out;
}

async function tick() {
  const state = loadState();
  const items = newTurns(state);
  if (!items.length) return 0;
  const r = await postSpans(items.map((i) => i.span));
  if (r.code >= 200 && r.code < 300) {
    let rejected = "?";
    try { rejected = JSON.parse(r.body)?.partialSuccess?.rejectedSpans ?? "0"; } catch { rejected = "0"; }
    state.seen.push(...items.map((i) => i.id));
    if (state.seen.length > 500) state.seen = state.seen.slice(-500);
    saveState(state);
    console.log(`${new Date().toISOString()} sent ${items.length} span(s) -> Galileo (HTTP ${r.code}, rejected=${rejected})`);
  } else {
    console.log(`${new Date().toISOString()} Galileo POST failed HTTP ${r.code}: ${r.body.slice(0, 200)}`);
  }
  return items.length;
}

if (ONESHOT) {
  const n = await tick();
  console.log(`oneshot done: ${n} turn(s) processed`);
} else {
  console.log(`galileo-forwarder started; endpoint=${EP} project=${PROJ} stream=${LS}`);
  for (;;) { try { await tick(); } catch (e) { console.log("err", e.message); } await new Promise((r) => setTimeout(r, 5000)); }
}
