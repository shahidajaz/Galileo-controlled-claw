# openclaw-governed

Run **OpenClaw** (an autonomous AI agent) with a safety governor in front of it,
and see everything it does in two places at once.

- **Agent Control** governs every tool call, allow or **block**, fail-closed.
- **Splunk** receives every governance decision (what was allowed / blocked).
- **Galileo** receives every LLM turn as a scorable trace (prompt + response).

One `docker compose` stack. All ports bind to `127.0.0.1`. No cloud account
required except an (optional) Galileo API key.

```
              ┌──────────────┐      tool call        ┌──────────────────┐
   you  ─────▶│   OpenClaw   │─────  allow/block ────▶│  Agent Control   │
              │  (gateway)   │◀──────────────────────│   (+ Postgres)   │
              └──────┬───────┘                        └────────┬─────────┘
                     │ LLM prompt/response                     │ decisions
                     ▼                                         ▼
              ┌──────────────┐                          ┌──────────────┐
              │   Galileo    │                          │    Splunk    │
              │ (LLM scoring)│                          │ (audit logs) │
              └──────────────┘                          └──────────────┘
```

## Prerequisites

- Docker + Docker Compose v2
- An **OpenAI-compatible LLM endpoint** (local vLLM, Ollama, or OpenAI, set in `.env`)
- ~4 GB free RAM for the base stack; **+2 GB** if you enable the bundled Splunk
- Optional: a Galileo API key (from app.galileo.ai) for the LLM-scoring feed

## Quick start

```bash
./setup.sh         # interactive: asks for your LLM, Galileo key, Splunk -> writes .env
./up.sh            # OpenClaw + Agent Control (+ Galileo / Splunk if configured)
```

`setup.sh` probes your LLM endpoint to list available models, generates all secrets,
and offers to bring the stack up. Prefer to edit by hand instead? `cp .env.example .env`,
set `LLM_BASE_URL` / `LLM_MODEL`, then `./up.sh`. Add `--splunk` for the bundled Splunk.

To run the agent **ungoverned** for an A/B test: `GOVERNANCE_ENABLED=false ./up.sh`.

`up.sh` generates all secrets on first run and prints your access URLs + admin key.

## What you get

| Service | URL (default) | What it is |
|---|---|---|
| Agent Control | http://localhost:8181 | the governor UI + API (login with the printed admin key) |
| OpenClaw gateway | http://localhost:18789 | the governed agent (pair a TUI, or `exec` it, see USAGE) |
| Splunk | http://localhost:8090 | governance audit logs (`--profile splunk`, user `admin`) |
| Galileo | app.galileo.ai | LLM traces (your project, if `GALILEO_API_KEY` set) |

See **[docs/USAGE.md](docs/USAGE.md)** for: running the agent, what a blocked
tool call looks like, searching Splunk, and reading the Galileo traces.

## Configuration

Everything is in `.env` (see `.env.example` for the annotated list). The most
common edits:

- `LLM_BASE_URL` / `LLM_MODEL`, your model endpoint
- `GALILEO_API_KEY`, blank disables the Galileo feed entirely
- `GOVERNANCE_FAIL_CLOSED=true`, block tool calls if the governor is down
- `SPLUNK_HEC_URL`, point the forwarder at an **existing** Splunk instead of the bundled one

## Governance surfaces, policies, decisions

Agent Control exposes three surfaces and (in v8.2.0) three decisions. This repo wires:

| Surface | How | Decisions used |
|---|---|---|
| **Tool calls** | the native `agent-control-openclaw-plugin` (in-process) | `deny` |
| **LLM calls (reasoning)** | the `llm-proxy` service (OpenClaw talks to it instead of the model; it evaluates every prompt via Agent Control `/api/v1/evaluation`, fail-closed, and records the decision for the audit trail) | `deny`, `steer` |
| Agent workflow | *not wired* — the vendor plugin only hooks tools; the workflow surface needs `@control()` decorators inside OpenClaw itself | — |

The demo policy set (auto-attached by `ac-setup`): block a demo token, dangerous shell
commands, and secret/key exfiltration (tool `deny`); block prompt-injection (LLM `deny`);
steer away from PII in the prompt (LLM `steer`). Edit them in `ac-setup/setup.py`.

**Honest ceilings of the open-source build:** the self-hosted Agent Control server ships
only the built-in evaluators `regex / list / json / sql`. The Luna / NeMo / Bedrock
detectors from Galileo's marketing are commercial/add-on and **not** in this build, so
regex is the strongest native detector here. Luna-2 **scoring** and **Signals** run in the
Galileo cloud on the traces the forwarder sends (enable out-of-the-box metrics per log
stream in the Galileo UI); they are observability, they do not block.

Toggle governance per run: `GOVERNANCE_ENABLED=false ./up.sh` (raw), `LLM_GOVERNANCE=false`
(keep tool governance, drop the LLM layer).

## Pinned versions

OpenClaw `v2026.3.8` · agent-control-openclaw-plugin `v1.8.2` · Agent Control `v8.2.0`.
Both OpenClaw and the plugin run from source (loaded via jiti), there is no build step.

**Everything is pinned for reproducible deploys:** base images node `24.18.0`, postgres `16.14-alpine`, splunk `9.4.13`; app deps locked (openclaw `pnpm-lock.yaml` installed with `--frozen-lockfile`, plugin via `npm ci`); Agent Control builds from its own `v8.2.0` tag.

## Notes

- The `splunk/splunk` image is x86_64-first; on arm64, prefer `SPLUNK_HEC_URL`
  pointing at an existing Splunk over the bundled service.
- Galileo only ingests **GenAI** spans, so the forwarder converts each OpenClaw
  LLM turn into an OpenInference LLM span before sending. Governance decisions
  (allow/block) go to Splunk, not Galileo, two lenses by design.
