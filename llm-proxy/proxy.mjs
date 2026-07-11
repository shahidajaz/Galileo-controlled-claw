// LLM-layer control point for openclaw-governed.
// Sits between OpenClaw and the real model (OpenAI-compatible). On each chat
// completion it evaluates the NEW prompt content against Agent Control's LLM
// surface (POST /api/v1/evaluation, step.type="llm", stage="pre") and then:
//   deny    -> return a blocked completion (agent sees the refusal), fail-closed
//   steer   -> inject the steering message and continue to the model (Agent
//              Control semantics); STEER_MODE=respond returns the steering
//              message as the completion instead (soft-deny, the old behavior)
//   observe -> forward to the real model unchanged
// "NEW prompt content" = the last user message PLUS any tool results appended
// since the last assistant turn, so indirect prompt injection carried in tool
// OUTPUT is governed at this boundary too (GOVERN_TOOL_RESULTS=false disables).
// Governance decisions are recorded via /api/v1/observability/events (the REST
// evaluate path enforces but does not auto-record). Recording is retried and
// buffered; a failure is logged loudly as AUDIT-DEGRADED, never dropped silently.
// LLM turns still reach Galileo/Splunk via the openclaw cacheTrace forwarders,
// so this proxy does NOT emit spans (no double-send).
import http from "node:http";

const PORT = parseInt(process.env.PORT || "8100", 10);
const UPSTREAM = (process.env.LLM_UPSTREAM_URL || "http://host.docker.internal:8000/v1").replace(/\/$/, "");
const UP_KEY = process.env.LLM_API_KEY || "unused";
const AC_URL = (process.env.AC_SERVER_URL || "http://server:8000").replace(/\/$/, "");
const AC_KEY = process.env.AC_API_KEY || "";
const AGENT = process.env.AGENT_NAME || "openclaw-agent:main";
const GOV_ON = (process.env.LLM_GOVERNANCE || "true") === "true";
const FAIL_CLOSED = (process.env.GOVERNANCE_FAIL_CLOSED || "true") === "true";
const STEER_MODE = process.env.STEER_MODE === "respond" ? "respond" : "inject";
const GOV_TOOLS = (process.env.GOVERN_TOOL_RESULTS || "true") === "true";

process.on("unhandledRejection", (e) => console.log("unhandledRejection:", e?.message || e));
process.on("uncaughtException", (e) => console.log("uncaughtException:", e?.message || e));

const hex = (n) => Array.from({ length: n }, () => Math.floor(Math.random() * 16).toString(16)).join("");
const textOf = (c) => typeof c === "string" ? c
  : Array.isArray(c) ? c.map((p) => (p && typeof p.text === "string" ? p.text : "")).join("")
  : c == null ? "" : JSON.stringify(c);

// The content to govern this call: the last user message + every tool result
// appended since the last assistant turn (the model is about to consume those
// for the first time; earlier messages were governed on their own turns).
function govInput(msgs) {
  const arr = Array.isArray(msgs) ? msgs : [];
  const parts = [];
  const u = arr.filter((m) => m.role === "user").pop();
  if (u) parts.push(textOf(u.content));
  if (GOV_TOOLS) {
    let lastA = -1;
    for (let i = arr.length - 1; i >= 0; i--) if (arr[i].role === "assistant") { lastA = i; break; }
    for (const m of arr.slice(lastA + 1))
      if (m.role === "tool" || m.role === "toolResult" || m.role === "function") parts.push(textOf(m.content));
  }
  return parts.filter((s) => s && s.trim()).join("\n");
}

// --- record the LLM-surface decision as observability events (-> Postgres -> Splunk) ---
// The REST evaluation path enforces but does not auto-record; the plugin records
// separately, so we mirror that here for a complete audit trail on the LLM layer.
// One trace_id per evaluation, so all events of one decision correlate.
function eventsFrom(j, traceId) {
  const now = new Date().toISOString();
  const mk = (m, matched) => ({
    control_execution_id: m.control_execution_id || hex(16),
    trace_id: traceId, span_id: hex(16), agent_name: AGENT,
    control_id: m.control_id, control_name: m.control_name,
    check_stage: "pre", applies_to: "llm_call",
    action: (m.action && (m.action.decision || m.action)) || "observe",
    matched, confidence: m.result?.confidence ?? (matched ? 1 : 0),
    timestamp: now, evaluator_name: m.result?.evaluator_name || "regex",
    selector_path: "input", metadata: {},
  });
  return [
    ...(j.matches || []).map((m) => mk(m, true)),
    ...(j.non_matches || []).map((m) => mk(m, false)),
  ];
}

// Audit events buffer + retry: enforcement is fail-closed and already decided;
// the audit trail is retried until delivered and DEGRADATION IS LOUD, so a
// Splunk gap is visible in the logs instead of silent.
let auditBuf = [];
let flushing = false;
async function flushAudit() {
  if (flushing || !auditBuf.length) return;
  flushing = true;
  const batch = auditBuf.splice(0, auditBuf.length);
  try {
    const res = await fetch(`${AC_URL}/api/v1/observability/events`, {
      method: "POST", headers: { "Content-Type": "application/json", "X-API-Key": AC_KEY },
      body: JSON.stringify({ events: batch }), signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
  } catch (e) {
    auditBuf = batch.concat(auditBuf).slice(0, 1000);  // keep at most 1000 pending
    console.log(`${new Date().toISOString()} AUDIT-DEGRADED: record failed (${e.message}); ${auditBuf.length} event(s) buffered for retry`);
  } finally {
    flushing = false;
  }
}
setInterval(flushAudit, 10000).unref();
function recordEvents(j, traceId) {
  const events = eventsFrom(j, traceId);
  if (!events.length) return;
  auditBuf.push(...events);
  flushAudit();
}

// --- Agent Control LLM-surface evaluation (REST, same path the plugin uses) ---
async function evaluateLlm(prompt) {
  if (!GOV_ON) return { decision: "observe" };
  const traceId = hex(32);
  try {
    const res = await fetch(`${AC_URL}/api/v1/evaluation`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": AC_KEY },
      body: JSON.stringify({
        agent_name: AGENT,
        step: { type: "llm", name: "chat", input: prompt },
        stage: "pre",
      }),
      signal: AbortSignal.timeout(8000),
    });
    const j = await res.json();
    if (!res.ok) throw new Error(`evaluation HTTP ${res.status}`);
    recordEvents(j, traceId);  // buffered + retried audit trail
    if (j.is_safe) return { decision: "observe", traceId };
    const matches = j.matches || [];
    const deny = matches.find((m) => m.action === "deny");
    if (deny) return { decision: "deny", traceId, reason: j.reason || deny.control_name || "blocked by Agent Control policy" };
    const steer = matches.find((m) => m.action === "steer");
    if (steer) return { decision: "steer", traceId, message: steer.steering_context?.message || j.reason || "Please rephrase your request." };
    return { decision: "deny", traceId, reason: j.reason || "blocked by Agent Control policy" };
  } catch (e) {
    return FAIL_CLOSED
      ? { decision: "deny", traceId, reason: `agent-control unavailable (fail-closed): ${e.message}` }
      : { decision: "observe", traceId };
  }
}

function completionJSON(model, text) {
  return { id: "chatcmpl-gov-" + hex(8), object: "chat.completion", created: 0, model: model || "unknown",
    choices: [{ index: 0, message: { role: "assistant", content: text }, finish_reason: "stop" }],
    usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 } };
}
function sseFor(model, text) {
  const base = { id: "chatcmpl-gov-" + hex(8), object: "chat.completion.chunk", created: 0, model: model || "unknown" };
  const c1 = { ...base, choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }] };
  const c2 = { ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] };
  return `data: ${JSON.stringify(c1)}\n\ndata: ${JSON.stringify(c2)}\n\ndata: [DONE]\n\n`;
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", async () => {
    const reqBody = Buffer.concat(chunks);
    const isChat = /\/chat\/completions$/.test(req.url);
    let reqJson = null; try { reqJson = JSON.parse(reqBody.toString() || "{}"); } catch {}

    // A chat request the proxy cannot parse cannot be governed -> reject, never
    // pass it through ungoverned (fail-closed on the parse itself).
    if (isChat && !reqJson) {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "llm-proxy: request body is not valid JSON; refusing to forward ungoverned" }));
      return;
    }

    let forwardBody = reqBody;
    if (isChat && reqJson) {
      const prompt = govInput(reqJson.messages);
      const stream = !!reqJson.stream;
      const model = reqJson.model;
      const g = await evaluateLlm(prompt);
      if (g.decision === "deny" || (g.decision === "steer" && STEER_MODE === "respond")) {
        const msg = g.decision === "deny"
          ? "[Agent Control blocked this request] " + (g.reason || "policy")
          : g.message;
        res.writeHead(200, { "Content-Type": stream ? "text/event-stream" : "application/json" });
        res.end(stream ? sseFor(model, msg) : JSON.stringify(completionJSON(model, msg)));
        console.log(`${new Date().toISOString()} LLM ${g.decision} trace=${g.traceId || "-"} -> "${(msg || "").slice(0, 60)}"`);
        return;
      }
      if (g.decision === "steer") {
        // Agent Control steer semantics: inject the steering context, then continue.
        reqJson.messages = [...(reqJson.messages || []), { role: "system", content: `[Agent Control steering] ${g.message}` }];
        forwardBody = Buffer.from(JSON.stringify(reqJson));
        console.log(`${new Date().toISOString()} LLM steer(inject) trace=${g.traceId || "-"} -> "${(g.message || "").slice(0, 60)}"`);
      }
    }

    // Qwen3/3.5 on Ollama only disable reasoning via the NATIVE /api/chat "think" flag;
    // the OpenAI /v1 endpoint ignores it, so the model spends its whole budget "thinking"
    // and returns an EMPTY answer (stopReason "length"). For Qwen on an Ollama upstream we
    // translate this one call to native /api/chat with think:false, then map the reply
    // (content and any tool calls) back to OpenAI shape. Governance already ran above, so
    // this only changes HOW the model is reached, not whether it is governed.
    const isOllama = /ollama|:11434/.test(UPSTREAM);
    if (isChat && reqJson && /qwen/i.test(reqJson.model || "") && isOllama) {
      const nb = { model: reqJson.model, messages: reqJson.messages, think: false, stream: false, options: {} };
      if (reqJson.max_tokens) nb.options.num_predict = reqJson.max_tokens;
      if (typeof reqJson.temperature === "number") nb.options.temperature = reqJson.temperature;
      if (reqJson.tools) nb.tools = reqJson.tools;
      let nr;
      try {
        const up = await fetch(UPSTREAM.replace(/\/v1$/, "") + "/api/chat",
          { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(nb) });
        nr = await up.json();
      } catch (e) {
        res.writeHead(502, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: `llm-proxy native upstream error: ${e.message}` })); return;
      }
      const nm = nr.message || {};
      const toolCalls = Array.isArray(nm.tool_calls) && nm.tool_calls.length
        ? nm.tool_calls.map((t) => ({ id: "call_" + hex(8), type: "function",
            function: { name: t.function?.name || "",
              arguments: typeof t.function?.arguments === "string" ? t.function.arguments : JSON.stringify(t.function?.arguments || {}) } }))
        : undefined;
      const finish = toolCalls ? "tool_calls" : "stop";
      const msg = { role: "assistant", content: nm.content || "" };
      if (toolCalls) msg.tool_calls = toolCalls;
      if (reqJson.stream) {
        const base = { id: "chatcmpl-gov-" + hex(8), object: "chat.completion.chunk", created: 0, model: reqJson.model };
        const delta = toolCalls ? { ...msg, tool_calls: toolCalls.map((t, i) => ({ index: i, ...t })) } : msg;
        const d1 = { ...base, choices: [{ index: 0, delta, finish_reason: null }] };
        const d2 = { ...base, choices: [{ index: 0, delta: {}, finish_reason: finish }] };
        res.writeHead(200, { "Content-Type": "text/event-stream" });
        res.end(`data: ${JSON.stringify(d1)}\n\ndata: ${JSON.stringify(d2)}\n\ndata: [DONE]\n\n`);
      } else {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ id: "chatcmpl-gov-" + hex(8), object: "chat.completion", created: 0, model: reqJson.model,
          choices: [{ index: 0, message: msg, finish_reason: finish }],
          usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 } }));
      }
      console.log(`${new Date().toISOString()} LLM qwen->native think:false trace=- content=${(nm.content || "").length}b tools=${toolCalls ? toolCalls.length : 0}`);
      return;
    }

    // forward to the real model
    const url = UPSTREAM + req.url.replace(/^\/v1/, "");
    let upstream;
    try {
      upstream = await fetch(url, { method: req.method,
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${UP_KEY}` },
        body: ["GET", "HEAD"].includes(req.method) ? undefined : forwardBody });
    } catch (e) {
      res.writeHead(502, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: `llm-proxy upstream error: ${e.message}` })); return;
    }
    res.writeHead(upstream.status, { "Content-Type": upstream.headers.get("content-type") || "application/json" });
    if (isChat && reqJson?.stream) {
      const reader = upstream.body.getReader();
      for (;;) { const { done, value } = await reader.read(); if (done) break; res.write(Buffer.from(value)); }
      res.end();
    } else {
      res.end(Buffer.from(await upstream.arrayBuffer()));
    }
  });
});
server.listen(PORT, () => console.log(`llm-proxy on :${PORT} -> ${UPSTREAM} | governance ${GOV_ON ? "on" : "off"} (tools:${GOV_TOOLS}, steer:${STEER_MODE}) | agent ${AGENT}`));
