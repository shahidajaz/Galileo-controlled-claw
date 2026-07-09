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

const clip = (s, n) => { s = s || ""; return s.length > n ? s.slice(0, n) + "…" : s; };
const tms = (ts) => { const p = ts ? Date.parse(ts) : NaN; return Number.isFinite(p) ? p : null; };
const A = (pairs) => pairs.map(([k, v, t = "stringValue"]) => ({ key: k, value: { [t]: String(v) } }));

// Build one OTLP span (ms times -> ns).
function mkSpan({ traceId, spanId, parentId, name, start, end, attrs, error }) {
  const s = Math.max(1, start || Date.now());
  const e = Math.max(s + 1, end || s + 1);
  return {
    traceId, spanId, ...(parentId ? { parentSpanId: parentId } : {}),
    name, kind: 1,
    startTimeUnixNano: (BigInt(s) * 1000000n).toString(),
    endTimeUnixNano: (BigInt(e) * 1000000n).toString(),
    attributes: A(attrs),
    status: error ? { code: 2, message: "tool error" } : { code: 1 },
  };
}

// The governor's verdict is exact in the trace itself: a blocked step returns
// "[Agent Control blocked this request] <control>", an allowed one returns its real
// result. Derive allow/deny (and the control that fired) from that, no fuzzy matching.
const BLOCK_RE = /\[?Agent Control blocked this request\]?\s*([\w:-]+)?/i;
const govOf = (text) => { const m = BLOCK_RE.exec(text || ""); return m ? { action: "deny", control: m[1] || "" } : { action: "allow", control: "" }; };

// A full OpenInference trace per turn: a parent AGENT span with a child LLM span for
// each model step and a child TOOL span for each tool call (with its input + output),
// all sharing one trace and grouped by session. Galileo then sees and scores every
// part of the turn (each Webex tool call, each reasoning step), not just the final answer.
function turnToSpans(turn) {
  const msgs = turn.messages || [];
  // latest turn only: from the last user message to the end (older turns were already sent)
  let ui = -1;
  for (let i = msgs.length - 1; i >= 0; i--) { if (msgs[i].role === "user") { ui = i; break; } }
  if (ui < 0) return [];
  const slice = msgs.slice(ui);
  const prompt = textOf(slice[0].content);
  let finalText = "";
  for (let i = slice.length - 1; i >= 0; i--) {
    if (slice[i].role === "assistant") { const t = textOf(slice[i].content); if (t.trim()) { finalText = t; break; } }
  }
  const hasTools = slice.some((m) => m.role === "toolResult");
  if (!finalText.trim() && !hasTools) return [];

  const model = (turn.modelId || "model").split("/").pop();
  const session = turn.sessionKey || turn.sessionId || "main";
  const traceId = hex(32), parentId = hex(16);
  const t0 = tms(slice[0].timestamp) || Date.now();
  const tN = tms(slice[slice.length - 1].timestamp) || t0;
  const denied = slice.some((m) => (m.role === "toolResult" || m.role === "assistant") && govOf(textOf(m.content)).action === "deny");
  const base = [["session.id", session], ["agent", "openclaw-agent:main"], ["governed.by", "galileo-agent-control"]];

  const spans = [mkSpan({
    traceId, spanId: parentId, parentId: null, name: "agent turn", start: t0, end: tN,
    attrs: [["openinference.span.kind", "AGENT"], ["input.value", clip(prompt, 8000)], ["input.mime_type", "text/plain"],
      ["output.value", clip(finalText, 8000)], ["output.mime_type", "text/plain"],
      ["governance.action", denied ? "deny" : "allow"], ...base],
  })];

  // toolCall id -> the arguments the assistant passed (so the TOOL span shows real input)
  const argsById = {};
  for (const m of slice) if (m.role === "assistant" && Array.isArray(m.content))
    for (const c of m.content) if (c && c.type === "toolCall") argsById[c.id] = c;

  let cursor = t0;
  for (const m of slice) {
    if (m.role === "assistant") {
      const calls = Array.isArray(m.content) ? m.content.filter((c) => c && c.type === "toolCall") : [];
      const text = textOf(m.content);
      const out = text || (calls.length ? "calls: " + calls.map((c) => c.name).join(", ") : "");
      if (!out.trim()) continue;
      const u = m.usage || {};
      const end = tms(m.timestamp) || cursor;
      const gl = govOf(out);
      spans.push(mkSpan({
        traceId, spanId: hex(16), parentId, name: "llm", start: cursor, end,
        attrs: [["openinference.span.kind", "LLM"], ["llm.model_name", model], ["gen_ai.system", "openai"],
          ["gen_ai.request.model", model], ["input.value", clip(prompt, 4000)], ["output.value", clip(out, 6000)],
          ["llm.token_count.prompt", u.inputTokens ?? u.promptTokens ?? 0, "intValue"],
          ["llm.token_count.completion", u.outputTokens ?? u.completionTokens ?? 0, "intValue"],
          ["governance.action", gl.action], ...(gl.control ? [["governance.control", gl.control]] : []), ...base],
      }));
      cursor = end;
    } else if (m.role === "toolResult") {
      const arg = argsById[m.toolCallId];
      const end = tms(m.timestamp) || cursor;
      const gt = govOf(textOf(m.content));
      spans.push(mkSpan({
        traceId, spanId: hex(16), parentId, name: m.toolName || "tool", start: cursor, end, error: m.isError || gt.action === "deny",
        attrs: [["openinference.span.kind", "TOOL"], ["tool.name", m.toolName || "tool"],
          ["input.value", arg ? clip(JSON.stringify(arg.arguments || {}), 2000) : ""],
          ["output.value", clip(textOf(m.content), 4000)],
          ["governance.action", gt.action], ...(gt.control ? [["governance.control", gt.control]] : []), ...base],
      }));
      cursor = end;
    }
  }
  return spans;
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
    const spans = turnToSpans(o);
    if (spans.length) out.push({ id, spans });
  }
  return out;
}

async function tick() {
  const state = loadState();
  const items = newTurns(state);
  if (!items.length) return 0;
  const spans = items.flatMap((i) => i.spans);
  const r = await postSpans(spans);
  if (r.code >= 200 && r.code < 300) {
    let rejected = "?";
    try { rejected = JSON.parse(r.body)?.partialSuccess?.rejectedSpans ?? "0"; } catch { rejected = "0"; }
    state.seen.push(...items.map((i) => i.id));
    if (state.seen.length > 5000) state.seen = state.seen.slice(-5000);  // must exceed the rotation tail (2000 lines) or kept turns re-send
    saveState(state);
    console.log(`${new Date().toISOString()} sent ${items.length} turn(s) / ${spans.length} span(s) -> Galileo (HTTP ${r.code}, rejected=${rejected})`);
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
