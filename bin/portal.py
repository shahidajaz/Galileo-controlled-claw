#!/usr/bin/env python3
"""Governed OpenClaw (single agent) - web control plane. Stdlib only; runs on the box,
open it in a browser (tunnel the port over SSH):

    python3 bin/portal.py            # http://127.0.0.1:8891

Views: Home (status + start/stop), Connections (integrations, backed by .env),
Governance (the controls on the agent), Chat. One agent = openclaw-agent:main.
Governance itself is always on and is not configured here.
"""
import json, os, re, shlex, shutil, subprocess, threading
from urllib.parse import urlparse, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CF = "compose.yml"
AGENT = "openclaw-agent:main"
OC_SERVICE = "openclaw"                       # the single agent's compose service
PORT = int(os.environ.get("PORTAL_PORT", "8891"))

# Recommended local models, tagged by what hardware they suit.
RECMODELS = [
    {"id": "qwen2.5:1.5b", "note": "~1 GB, fast, great on CPU", "tier": "cpu"},
    {"id": "qwen2.5:3b",   "note": "~2 GB, smarter, OK on CPU", "tier": "cpu"},
    {"id": "llama3.2:3b",  "note": "~2 GB, general purpose",    "tier": "cpu"},
    {"id": "qwen2.5:7b",   "note": "~4.7 GB, best quality, GPU recommended", "tier": "gpu"},
]

_GPU = None
def has_gpu():
    global _GPU
    if _GPU is None:
        try:
            _GPU = subprocess.run(["nvidia-smi", "-L"], capture_output=True, timeout=5).returncode == 0
        except Exception:
            _GPU = False
    return _GPU

def ollama_models():
    try:
        out = subprocess.run(["docker", "compose", "-f", CF, "--profile", "models", "exec", "-T",
                              "ollama", "ollama", "list"], cwd=ROOT, capture_output=True, text=True, timeout=15).stdout
        return [ln.split()[0] for ln in out.splitlines()[1:] if ln.strip()]
    except Exception:
        return []

# ---------- .env data layer ----------
def envget(k, d=""):
    p = os.path.join(ROOT, ".env")
    if os.path.exists(p):
        for ln in open(p):
            if ln.startswith(k + "="):
                return ln.split("=", 1)[1].strip()
    return d

def setenv(k, v):
    p = os.path.join(ROOT, ".env")
    lines = open(p).read().splitlines() if os.path.exists(p) else []
    for i, ln in enumerate(lines):
        if ln.startswith(k + "="):
            lines[i] = f"{k}={v}"; break
    else:
        lines.append(f"{k}={v}")
    open(p, "w").write("\n".join(lines) + "\n")

def ensure_env():
    p = os.path.join(ROOT, ".env"); ex = os.path.join(ROOT, ".env.example")
    if not os.path.exists(p) and os.path.exists(ex):
        shutil.copyfile(ex, p)

def dc(*args, timeout=20):
    try:
        return subprocess.run(["docker", "compose", "-f", CF, *args], cwd=ROOT,
                              capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""

def running():
    return set(dc("ps", "--status", "running", "--format", "{{.Service}}").split())

# ---------- Agent Control (governance) ----------
def ac_url(path):
    return f"http://127.0.0.1:{envget('AC_PORT','8181')}{path}"

def _ac(method, path, body=None, timeout=8):
    import urllib.request, urllib.error
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(ac_url(path), data=data, method=method,
                                 headers={"X-API-Key": envget("AC_ADMIN_KEY"), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)}

def ac_controls():
    """Controls on the agent: [{id, name, enabled, decision, step}]. The global list has
    the flat fields we show; for a single-agent stack these are the agent's rules."""
    st, d = _ac("GET", "/api/v1/controls", timeout=5)
    if st == 0 or st >= 400:
        return None
    items = d.get("controls", d) if isinstance(d, dict) else d
    out = []
    for c in (items or []):
        if not isinstance(c, dict):
            continue
        act = c.get("action") or {}
        out.append({"id": c.get("id") or c.get("control_id"),
                    "name": c.get("name") or "control",
                    "enabled": c.get("enabled", True),
                    "decision": act.get("decision", "observe"),
                    "step": (c.get("step_types") or ["-"])[0]})
    return out

def ac_control_data(cid):
    """Full definition of one control (for editing): enabled/execution/scope/condition/action.
    The single-control GET nests the definition under 'data'."""
    st, d = _ac("GET", f"/api/v1/controls/{cid}")
    if st >= 400 or not isinstance(d, dict):
        return None
    data = d.get("data") if isinstance(d.get("data"), dict) else d
    return {k: data.get(k) for k in ("enabled", "execution", "scope", "condition", "action") if k in data}

def control_data(step, pattern, decision, steer_msg=""):
    action = {"decision": decision}
    if decision == "steer":
        action["steering_context"] = {"message": steer_msg or "Please rephrase your request."}
    return {"enabled": True, "execution": "server",
            "scope": {"step_types": [step], "stages": ["pre"]},
            "condition": {"selector": {"path": "input"},
                          "evaluator": {"name": "regex", "config": {"pattern": pattern}}},
            "action": action}

def audit(where=""):
    q = ("select count(*) from control_execution_events where (data->>'matched')::bool=true"
         + (" and " + where if where else ""))
    try:
        out = subprocess.run(["docker", "compose", "-f", CF, "exec", "-T", "postgres", "psql",
                              "-U", "agent_control", "-d", "agent_control", "-tAc", q],
                             cwd=ROOT, capture_output=True, text=True, timeout=12).stdout.strip()
        return int(out)
    except Exception:
        return None

# ---------- state ----------
def state():
    run = running()
    svcs = ["postgres", "server", "llm-proxy", OC_SERVICE]
    stack = {s: (s in run) for s in svcs}
    gov = {"enabled": (envget("GOVERNANCE_ENABLED", "true").lower() == "true"),
           "fail_closed": (envget("GOVERNANCE_FAIL_CLOSED", "true").lower() == "true"),
           "server": "server" in run,
           "decisions": audit(), "blocked": audit("data->>'action'='deny'")}
    val = lambda k: envget(k) or envget(k + "_SAVED")
    access = {
        "telegram": {"on": bool(envget("TELEGRAM_BOT_TOKEN")), "token": val("TELEGRAM_BOT_TOKEN"), "id": val("TELEGRAM_ALLOW")},
        "discord": {"on": bool(envget("DISCORD_BOT_TOKEN")), "token": val("DISCORD_BOT_TOKEN")},
        "slack": {"on": bool(envget("SLACK_BOT_TOKEN")), "token": val("SLACK_BOT_TOKEN"),
                  "app": val("SLACK_APP_TOKEN"), "signing": val("SLACK_SIGNING_SECRET")},
        "galileo": {"on": bool(envget("GALILEO_API_KEY")), "key": val("GALILEO_API_KEY"), "project": val("GALILEO_PROJECT")},
        "o11y": {"on": bool(envget("SPLUNK_O11Y_REALM")), "realm": val("SPLUNK_O11Y_REALM"), "token": val("SPLUNK_O11Y_TOKEN")},
        "splunk": {"on": bool(envget("SPLUNK_HEC_URL")), "url": val("SPLUNK_HEC_URL"), "token": val("SPLUNK_HEC_TOKEN")},
    }
    webex = {"connected": bool(envget("WEBEX_REFRESH_TOKEN")), "client_id": bool(envget("WEBEX_CLIENT_ID")),
             "redirect": envget("WEBEX_REDIRECT_URI", "")}
    base = envget("LLM_BASE_URL"); local = "ollama" in (base or "")
    setup = {"local": local, "gpu": has_gpu(), "model": envget("LLM_MODEL"),
             "configured": bool(envget("LLM_MODEL")) and bool(base),
             "recommended": RECMODELS,
             "downloaded": ollama_models() if (local and "ollama" in run) else []}
    controls = ac_controls()
    core_up = all(stack.get(s) for s in ("postgres", "server", "llm-proxy", OC_SERVICE))
    return {"stack": stack, "gov": gov, "access": access, "controls": controls,
            "webex": webex, "llm": {"model": envget("LLM_MODEL"), "base": base}, "setup": setup,
            "ready": bool(core_up and controls is not None),
            "ac_port": envget("AC_PORT", "8181"), "building": BUILD["running"]}

def agent_ready():
    """Honest readiness: core containers up, governor healthy, and the agent actually
    answers a warm-up message (which also loads the model). Slow, call once."""
    run = running()
    if not all(s in run for s in ("postgres", "server", "llm-proxy", OC_SERVICE)):
        return {"ready": False, "phase": "starting"}
    try:
        import urllib.request
        urllib.request.urlopen(ac_url("/health"), timeout=3)
    except Exception:
        return {"ready": False, "phase": "governor"}
    reply = chat_agent("Reply with just: ok")
    ok = bool(reply) and not reply.startswith("(")
    return {"ready": ok, "phase": "ready" if ok else "model"}

# ---------- chat ----------
def clean_reply(out):
    keep = [ln for ln in out.splitlines()
            if ln.strip() and not ln.strip().startswith(("[plugins]", "Config was", "ℹ", "$"))
            and "gateway connect" not in ln]
    return "\n".join(keep).strip() or "(no reply)"

def chat_agent(message):
    if OC_SERVICE not in running():
        return "(the stack is not running, start it first)"
    cmd = ("cd /root/ocsrc && node scripts/run-node.mjs agent --agent main "
           "--session-id web-$RANDOM -m " + shlex.quote(message))
    try:
        out = subprocess.run(["docker", "compose", "-f", CF, "exec", "-T", OC_SERVICE, "bash", "-lc", cmd],
                             cwd=ROOT, capture_output=True, text=True, timeout=240).stdout
        return clean_reply(out)
    except subprocess.TimeoutExpired:
        return "(timed out, the model took too long)"
    except Exception as ex:
        return f"(error: {ex})"

# ---------- Webex guided OAuth ----------
WEBEX_SCOPES = "spark:rooms_read spark:messages_read spark:messages_write spark:people_read"
WEBEX_API = "https://webexapis.com/v1"

def webex_authorize_url():
    import urllib.parse
    cid = envget("WEBEX_CLIENT_ID"); redir = envget("WEBEX_REDIRECT_URI")
    if not (cid and redir):
        return ""
    scopes = envget("WEBEX_SCOPES") or WEBEX_SCOPES
    q = urllib.parse.urlencode({"client_id": cid, "response_type": "code",
                                "redirect_uri": redir, "scope": scopes, "state": "openclaw"})
    return f"{WEBEX_API}/authorize?{q}"

def _webex_token(params):
    import urllib.request, urllib.parse, urllib.error
    body = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(f"{WEBEX_API}/access_token", data=body,
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Webex {e.code}: {e.read().decode()[:200]}")

def webex_connect(code):
    cid = envget("WEBEX_CLIENT_ID"); sec = envget("WEBEX_CLIENT_SECRET"); redir = envget("WEBEX_REDIRECT_URI")
    if not (cid and sec and redir):
        return {"ok": False, "error": "Save Client ID, Secret and Redirect URI first."}
    tok = _webex_token({"grant_type": "authorization_code", "client_id": cid,
                        "client_secret": sec, "code": code.strip(), "redirect_uri": redir})
    refresh = tok.get("refresh_token")
    if not refresh:
        return {"ok": False, "error": "No refresh token returned; check the code/redirect URI."}
    setenv("WEBEX_REFRESH_TOKEN", refresh)
    settings = json.dumps({"clientId": cid, "clientSecret": sec, "redirectUri": redir, "refreshToken": refresh})
    wrote = 0
    try:
        subprocess.run(["docker", "compose", "-f", CF, "exec", "-T", OC_SERVICE, "sh", "-c",
                        "mkdir -p /root/.openclaw-webex && cat > /root/.openclaw-webex/webex.json"],
                       cwd=ROOT, input=settings, text=True, timeout=15, check=True)
        wrote = 1
    except Exception:
        pass
    who = ""
    try:
        import urllib.request
        acc = _webex_token({"grant_type": "refresh_token", "client_id": cid,
                            "client_secret": sec, "refresh_token": refresh}).get("access_token")
        req = urllib.request.Request(f"{WEBEX_API}/people/me", headers={"Authorization": f"Bearer {acc}"})
        with urllib.request.urlopen(req, timeout=15) as r:
            me = json.loads(r.read().decode()); who = me.get("displayName") or (me.get("emails") or [""])[0]
    except Exception:
        pass
    return {"ok": True, "connected_as": who}

def webex_disconnect():
    setenv("WEBEX_REFRESH_TOKEN", "")
    try:
        subprocess.run(["docker", "compose", "-f", CF, "exec", "-T", OC_SERVICE, "sh", "-c",
                        "rm -f /root/.openclaw-webex/webex.json"], cwd=ROOT, timeout=15)
    except Exception:
        pass
    return {"ok": True}

# ---------- lifecycle jobs (streamed log) ----------
BUILD = {"lines": [], "running": False, "ok": None}

def start_build(cmd):
    if BUILD["running"]:
        return
    BUILD["lines"] = []; BUILD["running"] = True; BUILD["ok"] = None
    def run():
        BUILD["lines"].append("$ " + " ".join(cmd))
        try:
            p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, bufsize=1)
            for line in iter(p.stdout.readline, ""):
                line = line.rstrip("\n")
                if "\r" in line:
                    line = line.split("\r")[-1]
                if line.strip():
                    BUILD["lines"].append(line)
            p.wait(); BUILD["ok"] = (p.returncode == 0)
        except Exception as ex:
            BUILD["lines"].append("error: " + str(ex)); BUILD["ok"] = False
        BUILD["lines"].append("DONE " + ("ok" if BUILD["ok"] else "error"))
        BUILD["running"] = False
    threading.Thread(target=run, daemon=True).start()

# ---------- the page ----------
PAGE = open(os.path.join(os.path.dirname(__file__), "portal.html")).read() \
    if os.path.exists(os.path.join(os.path.dirname(__file__), "portal.html")) else "portal.html missing"

class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def _json(self):
        n = int(self.headers.get("Content-Length", "0"))
        try:
            return json.loads(self.rfile.read(n).decode() or "{}")
        except Exception:
            return {}

    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path in ("/", "/index.html"):
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if u.path == "/api/state":
            return self._send(200, json.dumps(state()))
        if u.path == "/api/build/log":
            since = int((q.get("since") or ["0"])[0])
            return self._send(200, json.dumps({"lines": BUILD["lines"][since:], "n": len(BUILD["lines"]),
                                                "running": BUILD["running"], "ok": BUILD["ok"]}))
        if u.path == "/api/webex/authurl":
            return self._send(200, json.dumps({"url": webex_authorize_url()}))
        if u.path == "/api/ready":
            return self._send(200, json.dumps(agent_ready()))
        return self._send(404, "{}")

    def do_POST(self):
        u = urlparse(self.path); d = self._json()
        if u.path == "/api/access":
            def setpair(on, k, v):
                if on:
                    setenv(k, v); setenv(k + "_SAVED", "")
                else:
                    setenv(k, ""); setenv(k + "_SAVED", v)
            t = d.get("telegram", {}); setpair(t.get("on"), "TELEGRAM_BOT_TOKEN", t.get("token", "")); setpair(t.get("on"), "TELEGRAM_ALLOW", t.get("id", ""))
            c = d.get("discord", {}); setpair(c.get("on"), "DISCORD_BOT_TOKEN", c.get("token", ""))
            sl = d.get("slack", {})
            setpair(sl.get("on"), "SLACK_BOT_TOKEN", sl.get("token", ""))
            setpair(sl.get("on"), "SLACK_APP_TOKEN", sl.get("app", ""))
            setpair(sl.get("on"), "SLACK_SIGNING_SECRET", sl.get("signing", ""))
            g = d.get("galileo", {}); setpair(g.get("on"), "GALILEO_API_KEY", g.get("key", "")); setenv("GALILEO_PROJECT", g.get("project") or "OpenClaw_Governed")
            o = d.get("o11y", {}); setpair(o.get("on"), "SPLUNK_O11Y_REALM", o.get("realm", "")); setpair(o.get("on"), "SPLUNK_O11Y_TOKEN", o.get("token", ""))
            s = d.get("splunk", {}); setpair(s.get("on"), "SPLUNK_HEC_URL", s.get("url", "")); setpair(s.get("on"), "SPLUNK_HEC_TOKEN", s.get("token", ""))
            start_build(["docker", "compose", "-f", CF, "up", "-d"])   # recreate only changed containers
            return self._send(200, json.dumps({"started": True}))
        if u.path == "/api/quickstart":
            # one click: point the agent at the bundled Ollama, pick a model, build + pull + start
            m = (d.get("model") or ("qwen2.5:7b" if has_gpu() else "qwen2.5:1.5b")).strip()
            setenv("LLM_BASE_URL", "http://ollama:11434/v1")
            setenv("LLM_MODEL", m)
            setenv("LLM_API_KEY", "unused")
            start_build(["bash", "up.sh"])
            return self._send(200, json.dumps({"started": True, "model": m}))
        if u.path == "/api/up":
            start_build(["bash", "up.sh"])
            return self._send(200, json.dumps({"started": True}))
        if u.path == "/api/down":
            flag = {"stop": "--stop", "reset": "--reset", "wipe": "--wipe"}.get(d.get("mode"), "--stop")
            start_build(["bash", "down.sh", flag])
            return self._send(200, json.dumps({"started": True}))
        if u.path == "/api/controls/save":
            # create (or update) a rule and attach it to the agent. No AC login needed:
            # the portal calls Agent Control's API with the admin key, server-side.
            name = (d.get("name") or "").strip()
            step = d.get("step") if d.get("step") in ("tool", "llm") else "tool"
            pattern = d.get("pattern") or ""
            decision = d.get("decision") if d.get("decision") in ("deny", "steer", "observe") else "deny"
            if not name or not pattern:
                return self._send(200, json.dumps({"ok": False, "error": "Name and a match pattern are required."}))
            data = control_data(step, pattern, decision, d.get("steer_msg", ""))
            cid = d.get("id")
            if cid:
                st, _ = _ac("PUT", f"/api/v1/controls/{cid}/data", {"data": data})
            else:
                st, b = _ac("PUT", "/api/v1/controls", {"name": name, "data": data})
                cid = b.get("control_id") if isinstance(b, dict) else None
                if cid:
                    _ac("POST", f"/api/v1/agents/{AGENT}/controls/{cid}")
            return self._send(200, json.dumps({"ok": st and st < 400, "id": cid}))
        if u.path == "/api/controls/toggle":
            cid = d.get("id")
            cur = ac_control_data(cid)
            if cur is None:
                return self._send(200, json.dumps({"ok": False, "error": "control not found"}))
            cur["enabled"] = bool(d.get("enabled"))
            st, _ = _ac("PUT", f"/api/v1/controls/{cid}/data", {"data": cur})
            return self._send(200, json.dumps({"ok": bool(st and st < 400)}))
        if u.path == "/api/controls/delete":
            cid = d.get("id")
            _ac("DELETE", f"/api/v1/agents/{AGENT}/controls/{cid}")   # detach
            st, _ = _ac("DELETE", f"/api/v1/controls/{cid}")           # remove
            return self._send(200, json.dumps({"ok": True}))
        if u.path == "/api/chat":
            return self._send(200, json.dumps({"reply": chat_agent(d.get("message", ""))}))
        if u.path == "/api/webex/save":
            for key, env in (("clientId", "WEBEX_CLIENT_ID"), ("clientSecret", "WEBEX_CLIENT_SECRET"),
                             ("redirectUri", "WEBEX_REDIRECT_URI")):
                v = (d.get(key) or "").strip()
                if v:
                    setenv(env, v)
            return self._send(200, json.dumps({"ok": True, "url": webex_authorize_url()}))
        if u.path == "/api/webex/connect":
            try:
                return self._send(200, json.dumps(webex_connect(d.get("code", ""))))
            except Exception as e:
                return self._send(200, json.dumps({"ok": False, "error": str(e)}))
        if u.path == "/api/webex/disconnect":
            return self._send(200, json.dumps(webex_disconnect()))
        return self._send(404, "{}")

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    ensure_env()
    srv = None
    for p in range(PORT, PORT + 20):          # auto-fallback if the port is taken
        try:
            srv = ThreadingHTTPServer(("127.0.0.1", p), H)
            print(f"[portal] open  http://127.0.0.1:{p}", flush=True)
            break
        except OSError:
            continue
    if srv is None:
        raise SystemExit(f"[portal] no free port in {PORT}..{PORT + 19}")
    srv.serve_forever()
