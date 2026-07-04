#!/usr/bin/env bash
# Forwards Agent Control governance events (control_execution_events) to Splunk HEC.
# Reads new rows from the Agent Control Postgres and POSTs each to a Splunk HEC.
# Fully env-driven so it works against the bundled Splunk or an existing one.
set -uo pipefail

PGHOST="${PG_HOST:-postgres}"
PGUSER="${PG_USER:-agent_control}"
PGDB="${PG_DB:-agent_control}"
PGPASS="${PG_PASSWORD:?PG_PASSWORD required}"
HEC="${SPLUNK_HEC_URL:-http://splunk:8088/services/collector/event}"
TOKEN="${SPLUNK_HEC_TOKEN:?SPLUNK_HEC_TOKEN required}"
INDEX="${SPLUNK_INDEX:-main}"
STATE="${STATE_FILE:-/state/.fwd_last_ts}"
mkdir -p "$(dirname "$STATE")"

export PGPASSWORD="$PGPASS"
pg() { psql -h "$PGHOST" -U "$PGUSER" -d "$PGDB" -tAc "$1" 2>/dev/null; }

# Wait for Postgres + the events table to exist.
until pg "SELECT 1" >/dev/null 2>&1; do echo "waiting for postgres@$PGHOST..."; sleep 3; done

LAST=$(cat "$STATE" 2>/dev/null || echo "1970-01-01 00:00:00+00")
echo "splunk-forwarder started; HEC=$HEC index=$INDEX last_ts=$LAST"

while :; do
  ROWS=$(pg "SELECT row_to_json(t)::text FROM (SELECT control_execution_id, timestamp, data, agent_name, namespace_key FROM control_execution_events WHERE timestamp > '$LAST' ORDER BY timestamp) t")
  if [ -n "${ROWS:-}" ]; then
    n=0
    while IFS= read -r J; do
      [ -z "$J" ] && continue
      curl -sk -o /dev/null -X POST "$HEC" -H "Authorization: Splunk $TOKEN" \
        -d "{\"sourcetype\":\"openclaw:agentcontrol\",\"source\":\"agent-control\",\"index\":\"$INDEX\",\"event\":$J}"
      n=$((n+1))
    done <<< "$ROWS"
    NEW=$(pg "SELECT to_char(max(timestamp),'YYYY-MM-DD HH24:MI:SS.US+00') FROM control_execution_events WHERE timestamp > '$LAST'")
    [ -n "${NEW:-}" ] && { LAST="$NEW"; printf '%s' "$LAST" > "$STATE"; }
    echo "$(date -u +%H:%M:%S) forwarded $n event(s) -> Splunk (up to $LAST)"
  fi
  sleep 5
done
