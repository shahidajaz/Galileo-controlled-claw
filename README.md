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
cp .env.example .env
#   edit LLM_BASE_URL / LLM_MODEL   (point at your model)
#   optionally paste GALILEO_API_KEY

./up.sh            # OpenClaw + Agent Control (+ Galileo if key set)
./up.sh --splunk   # ...and the bundled Splunk + log forwarder
```

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
