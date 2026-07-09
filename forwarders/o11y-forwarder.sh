#!/usr/bin/env bash
# Forwards Agent Control governance decisions to Splunk Observability Cloud (o11y)
# as metrics. One counter per decision -> a governance dashboard/alerts in o11y.
# Active only when SPLUNK_O11Y_REALM + SPLUNK_O11Y_TOKEN are set.
set -uo pipefail

PGHOST="${PG_HOST:-postgres}"; PGUSER="${PG_USER:-agent_control}"; PGDB="${PG_DB:-agent_control}"
PGPASS="${PG_PASSWORD:?PG_PASSWORD required}"
REALM="${SPLUNK_O11Y_REALM:?SPLUNK_O11Y_REALM required}"
TOKEN="${SPLUNK_O11Y_TOKEN:?SPLUNK_O11Y_TOKEN required}"
INGEST="https://ingest.${REALM}.signalfx.com/v2/datapoint"
STATE="${STATE_FILE:-/state/.o11y_last_ts}"
mkdir -p "$(dirname "$STATE")"

export PGPASSWORD="$PGPASS"
pg() { psql -h "$PGHOST" -U "$PGUSER" -d "$PGDB" -tAF $'\x1f' -c "$1" 2>/dev/null; }

until pg "SELECT 1" >/dev/null 2>&1; do echo "waiting for postgres@$PGHOST..."; sleep 3; done
# On a fresh DB the AC server creates control_execution_events via migrations at boot;
# seeding before it exists yields an empty last_ts that breaks the WHERE query. Wait for it.
until [ "$(pg "SELECT to_regclass('public.control_execution_events') IS NOT NULL")" = "t" ]; do
  echo "waiting for control_execution_events table..."; sleep 3
done

# o11y metrics carry an INGEST-time stamp (we send no per-point timestamp), so
# backfilling historical decisions would dump the whole table onto "now" as a burst.
# On first run (no state), start from the current max timestamp -> only LIVE decisions ship.
if [ -f "$STATE" ] && [ -n "$(cat "$STATE")" ]; then
  LAST=$(cat "$STATE")
else
  LAST=$(pg "SELECT coalesce(to_char(max(timestamp),'YYYY-MM-DD HH24:MI:SS.US+00'),'1970-01-01 00:00:00+00') FROM control_execution_events")
  LAST=${LAST:-1970-01-01 00:00:00+00}
  printf '%s' "$LAST" > "$STATE"
fi
echo "o11y-forwarder started; ingest=$INGEST realm=$REALM last_ts=$LAST"

flush() {  # POST an accumulated JSON array of counter objects in one request
  [ -z "${1:-}" ] && return 0
  curl -s -o /dev/null -X POST "$INGEST" -H "X-SF-Token: $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"counter\":[$1]}"
}

while :; do
  ROWS=$(pg "SELECT coalesce(data->>'control_name','?'), coalesce(data->>'action','?'), coalesce(data->>'matched','false'), coalesce(data->>'applies_to','?') FROM control_execution_events WHERE timestamp > '$LAST' ORDER BY timestamp")
  if [ -n "${ROWS:-}" ]; then
    n=0; batch=""
    while IFS=$'\x1f' read -r control action matched surface; do
      [ -z "$control" ] && continue
      dp="{\"metric\":\"openclaw.governance.decision\",\"value\":1,\"dimensions\":{\"control\":\"$control\",\"action\":\"$action\",\"matched\":\"$matched\",\"surface\":\"$surface\"}}"
      batch="${batch:+$batch,}$dp"; n=$((n+1))
      if [ $((n % 200)) -eq 0 ]; then flush "$batch"; batch=""; fi
    done <<< "$ROWS"
    flush "$batch"
    NEW=$(pg "SELECT to_char(max(timestamp),'YYYY-MM-DD HH24:MI:SS.US+00') FROM control_execution_events WHERE timestamp > '$LAST'")
    [ -n "${NEW:-}" ] && { LAST="$NEW"; printf '%s' "$LAST" > "$STATE"; }
    echo "$(date -u +%H:%M:%S) sent $n decision metric(s) -> o11y (up to $LAST)"
  fi
  sleep 5
done
