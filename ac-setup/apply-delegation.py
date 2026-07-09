#!/usr/bin/env python3
# Apply the governed-delegate controls LIVE to the running stack (setup.py only seeds
# fresh deploys). Adds, if absent, and attaches to openclaw-agent:main:
#   - openclaw-block-injection-in-tool : deny prompt-injection carried in ANY tool arg,
#       which closes the delegation-boundary gap (a Manager cannot spawn a Helper with an
#       injected/jailbreak task). The LLM-scope injection control did not cover this.
#   - openclaw-govern-delegation       : observe every sessions_spawn by name = a delegation
#       receipt, delegation as a first-class audited edge.
import json, urllib.request, urllib.error, os

# STACK_ENV points at the stack's .env (default: the single-agent stack);
# AGENT_NAMES (comma list) targets fleet deploys, AGENT_NAME a single agent.
ENV = os.environ.get("STACK_ENV") or os.path.expanduser("~/openclaw-governed/.env")
def envget(k):
    for ln in open(ENV):
        if ln.startswith(k + "="):
            return ln.split("=", 1)[1].strip()
    return ""
KEY = envget("AC_ADMIN_KEY"); PORT = envget("AC_PORT") or "8183"
BASE = f"http://127.0.0.1:{PORT}"
_names = os.environ.get("AGENT_NAMES") or os.environ.get("AGENT_NAME", "openclaw-agent:main")
AGENTS = [n.strip() for n in _names.split(",") if n.strip()]

def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"X-API-Key": KEY, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read().decode(); return r.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read().decode())
        except Exception: return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)}

def rule(step, pattern, decision="deny", selector="input", steer_msg=None):
    action = {"decision": decision}
    if decision == "steer":
        action["steering_context"] = {"message": steer_msg or "Please rephrase your request."}
    return {"enabled": True, "execution": "server",
            "scope": {"step_types": [step], "stages": ["pre"]},
            "condition": {"selector": {"path": selector}, "evaluator": {"name": "regex", "config": {"pattern": pattern}}},
            "action": action}

INJ = (r"(?i)ignore\s+(all\s+)?(previous|prior|above)\s+instructions|disregard\s+(the\s+)?(system|above|previous)"
       r"|reveal\s+your\s+system\s+prompt|forget\s+(everything|all|what\s+you|the|your)"
       r"|you\s+are\s+(now\s+)?(dan|a\s+dan)|no\s+restrictions|jailbreak"
       r"|ignore\s+your\s+(instructions|rules|guidelines)|(original|initial|hidden)\s+(setup\s+)?instructions")

# (?i) leads the pattern: Python 3.11+ re rejects mid-pattern global flags, so the
# old mid-pattern form would break the control on an AC server upgrade. Included
# here so existing deploys get the corrected pattern (setup.py only seeds, never
# overwrites a live control).
PII = (r"(?i)[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|\b\d{3}-\d{2}-\d{4}\b"
       r"|social\s+security|\bssn\b|my\s+social\s+is")

WANT = [
    ("openclaw-block-injection-in-tool", rule("tool", INJ, "deny", "input")),
    ("openclaw-govern-delegation",       rule("tool", r"(?i)sessions_spawn", "observe", "name")),
    ("openclaw-steer-pii",               rule("llm", PII, "steer", "input",
        "Your request appears to contain personal data (email or SSN). Please remove it and try again.")),
]

st, lst = call("GET", "/api/v1/controls")
items = lst.get("controls", lst) if isinstance(lst, dict) else lst
byname = {x.get("name"): (x.get("id") or x.get("control_id")) for x in items if isinstance(x, dict)}

print("Applying governed-delegate controls (live):")
for name, data in WANT:
    cid = byname.get(name)
    if cid:
        st, _ = call("PUT", f"/api/v1/controls/{cid}/data", {"data": data})
        print(f"  {name} (id={cid}): updated HTTP {st}")
    else:
        st, b = call("PUT", "/api/v1/controls", {"name": name, "data": data})
        cid = b.get("control_id") if isinstance(b, dict) else None
        print(f"  {name}: created id={cid} HTTP {st}")
    if cid:
        for agent in AGENTS:
            st, _ = call("POST", f"/api/v1/agents/{agent}/controls/{cid}")
            print(f"    attached to {agent}: HTTP {st}")
print("done. Verify: python3 ~/openclaw-redteam/probe.py")
