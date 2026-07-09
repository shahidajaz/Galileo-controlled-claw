// Webex OAuth + REST client for the governed OpenClaw Webex assistant.
// BYO-per-user: credentials live in a settings file the user owns (never hardcoded),
// so each deployment/user points at their OWN Webex integration.
//
// Token model (verified against Cisco docs, see the Triage design doc):
//   access token  = 14 days
//   refresh token = 90 days, RESETS to 90 on each use -> effectively perpetual
// The refresh token is the stored secret; access tokens are minted on demand.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const BASE = "https://webexapis.com/v1";
const SETTINGS_PATH = process.env.WEBEX_SETTINGS ||
  path.join(process.env.OPENCLAW_HOME || path.join(os.homedir(), ".openclaw"), "webex.json");

// Scopes MUST be a subset of what your Webex integration was created with, or the
// authorize call returns invalid_scope. Default = the core four (spaces, messages,
// send, people). Add meeting:* by setting WEBEX_SCOPES if your integration has them.
export const WEBEX_SCOPES = process.env.WEBEX_SCOPES ||
  "spark:rooms_read spark:messages_read spark:messages_write spark:people_read";

// ---- settings (BYO, user-editable) -----------------------------------------
// Credentials come from env (WEBEX_CLIENT_ID/SECRET/REDIRECT, set per-user in .env)
// OR the settings file. The refresh token (from the OAuth flow) always lives in the
// settings file on the persisted volume.
function readFile() {
  try { return JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf8")); } catch { return {}; }
}
export function loadSettings() {
  const f = readFile();
  return {
    clientId: process.env.WEBEX_CLIENT_ID || f.clientId || "",
    clientSecret: process.env.WEBEX_CLIENT_SECRET || f.clientSecret || "",
    redirectUri: process.env.WEBEX_REDIRECT_URI || f.redirectUri || "",
    refreshToken: f.refreshToken || "",
  };
}
export function saveRefreshToken(refreshToken) {
  const f = readFile();
  f.refreshToken = refreshToken;
  fs.mkdirSync(path.dirname(SETTINGS_PATH), { recursive: true });
  fs.writeFileSync(SETTINGS_PATH, JSON.stringify(f, null, 2), { mode: 0o600 });
}
export function isConfigured() {
  const s = loadSettings();
  return Boolean(s.clientId && s.clientSecret && s.redirectUri && s.refreshToken);
}

// ---- OAuth: one-time authorization-code flow -------------------------------
export function buildAuthorizeUrl(state = "openclaw") {
  const s = loadSettings();
  const q = new URLSearchParams({
    client_id: s.clientId, response_type: "code",
    redirect_uri: s.redirectUri, scope: WEBEX_SCOPES, state,
  });
  return `${BASE}/authorize?${q.toString()}`;
}
export async function exchangeCode(code) {
  const s = loadSettings();
  const body = new URLSearchParams({
    grant_type: "authorization_code", client_id: s.clientId, client_secret: s.clientSecret,
    code, redirect_uri: s.redirectUri,
  });
  const r = await fetch(`${BASE}/access_token`, {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body,
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`token exchange failed: ${r.status} ${JSON.stringify(j)}`);
  saveRefreshToken(j.refresh_token);
  return j; // { access_token, expires_in, refresh_token, refresh_token_expires_in }
}

// ---- access-token minting (refresh flow, cached) ---------------------------
let _cache = { token: "", exp: 0 };
export async function getAccessToken() {
  if (_cache.token && Date.now() < _cache.exp - 60_000) return _cache.token;
  const s = loadSettings();
  if (!s.refreshToken) throw new Error("Webex not authorized: no refresh token (run the OAuth setup)");
  const body = new URLSearchParams({
    grant_type: "refresh_token", client_id: s.clientId, client_secret: s.clientSecret,
    refresh_token: s.refreshToken,
  });
  const r = await fetch(`${BASE}/access_token`, {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body,
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`token refresh failed: ${r.status} ${JSON.stringify(j)}`);
  if (j.refresh_token && j.refresh_token !== s.refreshToken) saveRefreshToken(j.refresh_token);
  _cache = { token: j.access_token, exp: Date.now() + (j.expires_in || 1209600) * 1000 };
  return _cache.token;
}

// ---- REST helper -----------------------------------------------------------
async function api(method, endpoint, { query, body } = {}) {
  const token = await getAccessToken();
  const url = new URL(BASE + endpoint);
  if (query) for (const [k, v] of Object.entries(query)) if (v != null) url.searchParams.set(k, v);
  const r = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  let json = null; try { json = JSON.parse(text); } catch {}
  if (!r.ok) throw new Error(`Webex ${method} ${endpoint} -> ${r.status}: ${text.slice(0, 200)}`);
  return json;
}

// ---- compact projections --------------------------------------------------
// Raw Webex messages carry html/markdown/ids/timestamps; 50 of them overflow a
// 32K-context model. Project reads to the few fields a summary needs, and cap counts.
const MSG_TEXT_MAX = 500;
const compactMsg = (m) => ({
  from: m.personEmail || m.personId,
  at: m.created,
  text: (m.text || m.markdown || "").slice(0, MSG_TEXT_MAX),
});
const compactRoom = (r) => ({ id: r.id, title: r.title, type: r.type, lastActivity: r.lastActivity });

// ---- the webex.* operations (exact endpoints from the design doc) ----------
export const webex = {
  // verify / whoami
  me: () => api("GET", "/people/me"),
  // READS (pass the governance gate). Projected + capped to fit the model context.
  list_spaces: async ({ max = 100 } = {}) => {
    const r = await api("GET", "/rooms", { query: { max } });
    return { items: (r.items || []).map(compactRoom) };
  },
  list_messages: async ({ roomId, mentionedMe = false, max = 20 }) => {
    const r = await api("GET", "/messages", { query: { roomId, mentionedPeople: mentionedMe ? "me" : null, max } });
    return { items: (r.items || []).map(compactMsg) };
  },
  list_direct: async ({ personId, personEmail, max = 20 }) => {
    const r = await api("GET", "/messages/direct", { query: { personId, personEmail, max } });
    return { items: (r.items || []).map(compactMsg) };
  },
  list_transcripts: ({ meetingId, max = 20 } = {}) =>
    api("GET", "/meetingTranscripts", { query: { meetingId, max } }),
  people: ({ id }) => api("GET", `/people/${encodeURIComponent(id)}`),
  // WRITES (higher-risk: gate hard, require human approval upstream)
  send_message: ({ roomId, toPersonId, toPersonEmail, text, markdown }) =>
    api("POST", "/messages", { body: { roomId, toPersonId, toPersonEmail, text, markdown } }),
  book_meeting: ({ title, start, end, invitees }) =>
    api("POST", "/meetings", { body: { title, start, end, invitees } }),
};

// Accept a space NAME or a roomId and return the roomId. Webex room IDs are long
// base64url; a human name (has spaces / is short) is resolved via list_spaces.
export async function resolveRoomId(nameOrId) {
  if (!nameOrId) throw new Error("no space given");
  if (/^[A-Za-z0-9+/_=-]{40,}$/.test(nameOrId) && !/\s/.test(nameOrId)) return nameOrId; // looks like an id
  const rooms = (await webex.list_spaces({ max: 200 })).items || [];
  const q = nameOrId.trim().toLowerCase();
  const hit = rooms.find((r) => (r.title || "").toLowerCase() === q)
    || rooms.find((r) => (r.title || "").toLowerCase().includes(q));
  if (!hit) throw new Error(`no Webex space matching "${nameOrId}"`);
  return hit.id;
}
