# Cisco AI Defense as an Agent Control evaluator (optional, off by default)

Agent Control's OSS server ships only regex/list/json/sql evaluators, so the
enforcement gate is literal-match. **Cisco AI Defense** is a launch-partner
*semantic* evaluator (ref: Galileo blog, "Securing the Agentic Future") that
plugs into Agent Control's own deny/steer engine via the `agent_control.evaluators`
entry-point group. It already ships as source inside the server image at
`/app/evaluators/contrib/cisco` (registered name `cisco.ai_defense`).

This wires it in as a **one-env-var flip**, off by default.

## Turn on
1. Put your key in `.env`:
   ```
   CISCO_AI_DEFENSE_API_KEY=<your key>
   CISCO_AI_DEFENSE_REGION=us      # us | ap | eu
   ```
2. Run the enabler (fleet: pass the compose file + roster):
   ```
   cisco/enable.sh
   # fleet:
   COMPOSE_FILE=compose.fleet.yml \
   AGENT_NAMES="openclaw-agent:manager,openclaw-agent:helper1,...,helper5" \
   cisco/enable.sh
   ```
   It installs the evaluator into the server venv, restarts the server, waits for
   `cisco.ai_defense` to register, then creates the fail-closed control
   `openclaw-cisco-aidefense` (LLM surface, `on_error=deny`) and attaches it.

## Turn off
```
cisco/disable.sh          # detaches + disables the control; nothing egresses
```

## The trade-off (read before enabling)
- **Detection:** semantic, vendor-native. Far stronger than the regex controls.
- **Enforcement seat:** unchanged. Agent Control still decides deny/steer, fail-closed.
  `on_error=deny` means if Cisco AI Defense is unreachable, the call is **blocked**.
- **Data path:** the evaluator calls Cisco's **cloud** inspect API
  (`*.aidefense.security.cisco.com`) — governed prompt content **leaves the box**.
  That is the whole reason it is off by default. Do not enable on a stack that must
  stay local. For a **Cisco-facing demo** (Galileo + Agent Control + Cisco AI Defense,
  all first-party), it is the intended, native story.

## Same pattern, local: DefenseClaw as an evaluator
Cisco AI Defense is just a `@register_evaluator` class wrapping a REST inspect API.
**DefenseClaw already exposes an equivalent local inspect API**
(`POST 127.0.0.1:18970/api/v1/inspect/tool`), so it can be packaged as a sibling
evaluator (`defenseclaw.inspect`) with the *same* shape — but **on-box, no egress**.
That gives semantic enforcement plugged natively into Agent Control's fail-closed
engine with content never leaving the machine. See `../defenseclaw-evaluator/` if built.
Caveats to carry over: force `on_error=deny` (DefenseClaw's own default is fail-open),
and mind its 5-45s latency (tune `timeout_ms` or scope it selectively).
