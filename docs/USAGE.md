# Using openclaw-governed

## 1. Bring it up

```bash
./up.sh --splunk
```

First run compiles OpenClaw from source (a few minutes). When it finishes you'll
see your admin key and URLs. Everything binds to `127.0.0.1`; from another
machine use an SSH tunnel, e.g.:

```bash
ssh -L 8181:localhost:8181 -L 8090:localhost:8090 you@your-host
```

## 2. Run the agent

The agent is the `openclaw` container. Give it a task:

```bash
docker compose exec openclaw \
  bash -lc 'cd /root/ocsrc && node scripts/run-node.mjs agent --agent main -m "list the files in /root"'
```

You can also pair the **TUI** or an IDE to the gateway at
`http://localhost:18789` (token is `GATEWAY_TOKEN` in your `.env`).

## 3. See a tool call get BLOCKED

Agent Control governs every tool call. Ask the agent to do something and watch a
disallowed action get denied (fail-closed). For example, a shell command the
policy blocks returns a block instead of running:

```bash
docker compose exec openclaw \
  bash -lc 'cd /root/ocsrc && node scripts/run-node.mjs agent --agent main -m "run the shell command: echo BLOCKED_BY_AGENT_CONTROL"'
```

Edit the policy in the Agent Control UI (`http://localhost:8181`) to change what
is allowed vs blocked.

## 4. Read the governance logs in Splunk

Open `http://localhost:8090` (user `admin`, password = `SPLUNK_PASSWORD`). Search:

```
sourcetype="openclaw:agentcontrol"
```

Each event is one governance decision (agent, tool, allow/block, timestamp). The
`splunk-forwarder` sidecar ships these from Agent Control's database in real time.

To ship to a Splunk you already run instead of the bundled one, set in `.env`:

```
SPLUNK_HEC_URL=http://your-splunk:8088/services/collector/event
SPLUNK_HEC_TOKEN=<your HEC token>
```

## 5. Read the LLM traces in Galileo

If `GALILEO_API_KEY` is set, every LLM turn shows up at **app.galileo.ai** under
your `GALILEO_PROJECT` / `GALILEO_LOG_STREAM` as a scorable trace (prompt,
response, tokens, model). Galileo's metrics (groundedness, etc.) run on those.

Verify it's flowing:

```bash
docker compose exec openclaw tail -n 5 /root/galileo-fwd.log
#   ... sent N span(s) -> Galileo (HTTP 200, rejected=0)
```

`rejected=0` means Galileo accepted the spans.

## 6. Durability

- Everything runs with `restart: unless-stopped`, so a reboot brings the whole
  stack back, **including the OpenClaw gateway and both feeds** (they're baked
  into the image entrypoint, not started by hand).
- Config + cacheTrace live on the image/volumes, so `docker compose restart`
  and full reboots are safe. `./down.sh -v` wipes data volumes.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Agent errors calling the LLM | check `LLM_BASE_URL` is reachable from the container (`host.docker.internal` = the host) |
| Every tool call blocked | Agent Control is unreachable and `GOVERNANCE_FAIL_CLOSED=true`, check the `server` container is healthy |
| Galileo log shows `rejected>0` | spans lacked GenAI attributes, ensure you're on the shipped forwarder (it sends OpenInference spans) |
| Splunk container won't start (arm64) | use `SPLUNK_HEC_URL` to point at an existing Splunk instead |
