# Webex triage playbook

Ready-to-run prompts for the governed OpenClaw agent, one per stage. Run them from
the CLI (`run "..."`) or from Telegram once the channel is on. Every `webex.*` call
they trigger passes the Agent Control gate and lands in Splunk + Galileo.

**Reads pass the gate. Writes (`send`, `book`) wait for your explicit approval - the
agent drafts, you send.** A read that misfires is noise; a send that misfires is an
email to your team.

Needs a **≥32K-context model** to cluster/summarize many messages well (the tools
themselves work on any tool-calling model).

---

## Stage 1 - Read (prove access)
```
List my Webex spaces.
Show the last 20 messages in the "Infra" space.
```

## Stage 2 - What needs my response
```
Across my Webex spaces and DMs from the last 3 days, list only threads awaiting MY
reply (I'm @mentioned, or it's a DM where their message is the latest). For each:
space, who, a one-line ask, and the link. Exclude anything I've already answered.
```

## Stage 3 - Cluster by topic
```
Group today's messages in "Infra" into topics. For each: a 5-word label, who's
involved, and the 1-line state. Order by activity.
```

## Stage 4 - Rank importance
```
Rank the items you surfaced by how urgently they need me. Show the score and the ONE
reason for each, so I can correct you. This is a suggested ordering, never an action.
```

## Stage 5 - Meeting summary + action items
```
Download the transcript of yesterday's "Platform sync" and summarize it. Then list
action items in two groups: mine, and everyone else's.
```

## Stage 6 - Draft replies (you approve)
```
For the top 3 items that need me, draft a short reply each. Show them - do NOT send.
I'll approve or edit.
```
Then, only on your explicit say-so (a governed, audited `webex_send_message`):
```
Send draft #2 as-is to that space. Hold the others.
```

## The digest (assemble on demand or on a schedule)
```
Give me my Webex digest for today:
  1. What needs me (Stage 2, ranked by Stage 4)
  2. Topics across my spaces (Stage 3)
  3. Meeting summaries + my action items (Stage 5)
  4. Suggested replies to review (Stage 6, draft only)
Deliver it here. Scope: only the spaces I named. Never auto-send.
```

## Governance you can point to
- Every `webex.*` action is a gated tool call (`deny / steer / observe`), audited in Splunk (`sourcetype=openclaw:agentcontrol`).
- Reads are content, not just metadata - keep scope to the spaces you chose; that choice is the privacy boundary and it's logged.
- Writes never fire without your approval.
