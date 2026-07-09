#!/usr/bin/env python3
"""One-shot: attach the openclaw-governed policy set to the agent.

Runs at stack start (only when GOVERNANCE_ENABLED=true). Uses the Agent Control
REST API via stdlib urllib (no SDK). Idempotent; retries the attach until the
agent has registered itself (the OpenClaw gateway registers it on boot).

Policy set (Agent Control v8.2.0 decisions: deny / steer / observe):
  TOOL surface (via the OpenClaw plugin):
    - block a demo token (FORBIDDEN_TOKEN)   [deny]
    - block dangerous shell commands          [deny]
    - block secret/key exfiltration           [deny]
  LLM surface (via the llm-proxy):
    - block prompt injection                  [deny]
    - steer away from PII in the prompt        [steer]
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

URL = os.environ.get("AC_URL", "http://server:8000").rstrip("/")
KEY = os.environ.get("AC_ADMIN_KEY", "")
AGENT = os.environ.get("AGENT_NAME", "openclaw-agent:main")
TOKEN = os.environ.get("FORBIDDEN_TOKEN", "FORBIDDEN")
GOV = os.environ.get("GOVERNANCE_ENABLED", "true").lower() == "true"


def rule(step, pattern, decision="deny", steer_msg=None, selector="input"):
    # selector="input" matches the step payload (tool args / llm prompt);
    # selector="name" matches the tool name itself (used to gate write-capable tools).
    action = {"decision": decision}
    if decision == "steer":
        action["steering_context"] = {"message": steer_msg or "Please rephrase your request."}
    return {
        "enabled": True,
        "execution": "server",
        "scope": {"step_types": [step], "stages": ["pre"]},
        "condition": {"selector": {"path": selector},
                      "evaluator": {"name": "regex", "config": {"pattern": pattern}}},
        "action": action,
    }


# Patterns below reflect the red-team-hardened set (see ~/openclaw-redteam/RESULTS.md +
# PROBES.md). The receipt found the original PI/PII regexes were bypassable ("forget
# everything", DAN roleplay, spelled-out SSN) and that write actions had no hard control;
# these broadened patterns + the write gate are the fixes, proven 6/6 by probe.py.
CONTROLS = [
    # --- TOOL surface (deny) ---
    ("openclaw-block-forbidden-tool", rule("tool", TOKEN)),
    ("openclaw-block-dangerous-cmd",
     rule("tool", r"(?i)rm\s+-rf|\bmkfs\b|dd\s+if=|:\(\)\s*\{|chmod\s+-R\s+777|>\s*/dev/sd")),
    ("openclaw-block-secret-exfil",
     rule("tool", r"AKIA[0-9A-Z]{16}|-----BEGIN\s+(RSA\s+|OPENSSH\s+|EC\s+)?PRIVATE\s+KEY|\bsk-[A-Za-z0-9]{20,}")),
    # write-capable tools are denied by NAME (no matching model reply can talk its way past it)
    ("openclaw-block-unapproved-write",
     rule("tool", r"(?i)webex_(send_message|book_meeting)", selector="name")),
    # --- DELEGATION edge (Manager -> Helper via sessions_spawn) ---
    # Delegation is a tool call, so secret/dangerous-command laundering through a subagent's
    # task is ALREADY denied by the tool-input controls above. Two gaps remain, closed here:
    #  1. prompt-injection carried in a delegated task: the block-prompt-injection control is
    #     LLM-scope only, so extend the same red-lines to the TOOL surface (covers sessions_spawn
    #     task + any other tool arg). You cannot spawn a Helper with an injected/jailbreak brief.
    ("openclaw-block-injection-in-tool",
     rule("tool", r"(?i)ignore\s+(all\s+)?(previous|prior|above)\s+instructions|disregard\s+(the\s+)?(system|above|previous)"
                  r"|reveal\s+your\s+system\s+prompt|forget\s+(everything|all|what\s+you|the|your)"
                  r"|you\s+are\s+(now\s+)?(dan|a\s+dan)|no\s+restrictions|jailbreak"
                  r"|ignore\s+your\s+(instructions|rules|guidelines)|(original|initial|hidden)\s+(setup\s+)?instructions")),
    #  2. attribution: make every delegation a first-class AUDITED edge (a delegation receipt),
    #     distinct from generic tool calls, by observing the sessions_spawn tool by name.
    ("openclaw-govern-delegation",
     rule("tool", r"(?i)sessions_spawn", decision="observe", selector="name")),
    # --- LLM surface ---
    ("openclaw-block-prompt-injection",
     rule("llm", r"(?i)ignore\s+(all\s+)?(previous|prior|above)\s+instructions|disregard\s+(the\s+)?(system|above|previous)"
                 r"|reveal\s+your\s+system\s+prompt|forget\s+(everything|all|what\s+you|the|your)"
                 r"|you\s+are\s+(now\s+)?(dan|a\s+dan)|no\s+restrictions|pretend\s+(you|the\s+rules|to\s+be)|jailbreak"
                 r"|ignore\s+your\s+(instructions|rules|guidelines)|(original|initial|hidden)\s+(setup\s+)?instructions")),
    ("openclaw-steer-pii",
     # (?i) must LEAD the pattern: Python 3.11+ re raises ValueError on mid-pattern
     # global flags, which would kill this control on an AC server upgrade.
     rule("llm", r"(?i)[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|\b\d{3}-\d{2}-\d{4}\b"
                 r"|social\s+security|\bssn\b|my\s+social\s+is",
          decision="steer",
          steer_msg="Your request appears to contain personal data (email or SSN). Please remove it and try again.")),
]


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        URL + path, data=data, method=method,
        headers={"X-API-Key": KEY, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)}


if not GOV:
    print("[ac-setup] GOVERNANCE_ENABLED=false -> agent runs UNGOVERNED, no controls attached")
    sys.exit(0)

# wait for the Agent Control server
for _ in range(60):
    st, _b = call("GET", "/health")
    if st == 200:
        break
    st, _b = call("GET", "/")
    if st and st < 500:
        break
    time.sleep(2)

# Ensure the agent exists. On a clean DB the agent has not self-registered yet, so
# attaching controls to it would 404/spin forever. initAgent is idempotent.
for _ in range(30):
    st, _b = call("POST", "/api/v1/agents/initAgent", {"agent": {"agent_name": AGENT}})
    if st in (200, 201, 409):
        break
    time.sleep(2)
print(f"[ac-setup] initAgent {AGENT}: HTTP {st}")


# These 5 are a STARTER PACK, seeded once. Agent Control's UI + REST API own controls
# after that: add / edit / remove them live (no restart). So we seed IDEMPOTENTLY:
# create only what's missing, never overwrite, so your live edits survive reboots.
SEED = os.environ.get("AC_SEED_STARTER", "true").lower() == "true"
UI_URL = os.environ.get("AC_UI_URL", "http://127.0.0.1:8183")


def controls_by_name():
    _st, lst = call("GET", "/api/v1/controls")
    items = lst.get("controls", lst) if isinstance(lst, dict) else lst
    out = {}
    if isinstance(items, list):
        for it in items:
            if isinstance(it, dict) and it.get("name"):
                out[it["name"]] = it.get("id") or it.get("control_id")
    return out


def create_control(name, data):
    st, b = call("PUT", "/api/v1/controls", {"name": name, "data": data})
    if st in (200, 201) and isinstance(b, dict) and "control_id" in b:
        return b["control_id"]
    return controls_by_name().get(name)  # created concurrently, or upserted


def attach(cid):
    for _ in range(60):
        st, b = call("POST", f"/api/v1/agents/{AGENT}/controls/{cid}")
        if st in (200, 201, 409):
            return st
        time.sleep(3)
    return st


if SEED:
    existing = controls_by_name()
    for name, data in CONTROLS:
        if name in existing:
            cid = existing[name]
            print(f"[ac-setup] {name}: exists (id={cid}) -> kept as-is (live edits preserved)")
        else:
            cid = create_control(name, data)
            print(f"[ac-setup] {name}: created id={cid} ({data['action']['decision']} on {data['scope']['step_types'][0]})")
        if not cid:
            print(f"[ac-setup] WARNING: could not create/find control {name}")
            continue
        attach(cid)  # idempotent (409 = already bound)
else:
    print("[ac-setup] AC_SEED_STARTER=false -> not seeding; manage all controls in the UI")

print(f"[ac-setup] done. Manage controls live (add/edit/remove, applies immediately): {UI_URL}")
