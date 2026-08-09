#!/usr/bin/env bash
# T-186: retention/engagement rollups over telemetry.gameplay_events. Text output — the
# owner's "measure fun, don't guess" surface (game-direction.md §5). Read-only; safe to run
# any time. Derives a character's level from its prior level_up events, so "deaths per level"
# needs no extra payload. Usage: scripts/telemetry-report.sh [days]  (default 7).
set -uo pipefail
CONTAINER="${AVALON_PG_CONTAINER:-avalon-postgres}"
DAYS="${1:-7}"

psql_q() { podman exec -i "$CONTAINER" psql -U avalon -d avalon -v ON_ERROR_STOP=1 "$@"; }

echo "=== Avalon telemetry — last ${DAYS} days ==="

echo; echo "-- Daily active characters (DAU) --"
psql_q -c "
SELECT ts::date AS day, count(DISTINCT character) AS dau
FROM telemetry.gameplay_events
WHERE character IS NOT NULL AND ts > now() - interval '${DAYS} days'
GROUP BY day ORDER BY day;"

echo; echo "-- Sessions per day --"
psql_q -c "
SELECT ts::date AS day, count(*) AS sessions
FROM telemetry.gameplay_events
WHERE event_type = 'session_start' AND ts > now() - interval '${DAYS} days'
GROUP BY day ORDER BY day;"

echo; echo "-- Median session length (paired start->end per character) --"
psql_q -c "
WITH ends AS (
  SELECT character, ts AS end_ts,
         (SELECT max(s.ts) FROM telemetry.gameplay_events s
          WHERE s.character = e.character AND s.event_type = 'session_start' AND s.ts <= e.ts) AS start_ts
  FROM telemetry.gameplay_events e
  WHERE e.event_type = 'session_end' AND e.ts > now() - interval '${DAYS} days'
)
SELECT count(*) AS sessions,
       coalesce(round(extract(epoch FROM percentile_cont(0.5)
         WITHIN GROUP (ORDER BY end_ts - start_ts))), 0) AS median_seconds
FROM ends WHERE start_ts IS NOT NULL;"

echo; echo "-- Time-to-level: median seconds from a character's first session to each level --"
psql_q -c "
WITH firsts AS (
  SELECT character, min(ts) AS first_ts FROM telemetry.gameplay_events
  WHERE character IS NOT NULL GROUP BY character
), levels AS (
  SELECT l.character,
         (payload->>'level')::int AS level,
         extract(epoch FROM l.ts - f.first_ts) AS secs
  FROM telemetry.gameplay_events l JOIN firsts f ON f.character = l.character
  WHERE l.event_type = 'level_up' AND payload ? 'level'
)
SELECT level, count(*) AS reached,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY secs)) AS median_seconds
FROM levels GROUP BY level ORDER BY level;"

echo; echo "-- Deaths per derived level bracket (level = 1 + prior level_ups) --"
psql_q -c "
WITH deaths AS (
  SELECT d.character, d.ts,
         1 + (SELECT count(*) FROM telemetry.gameplay_events u
              WHERE u.character = d.character AND u.event_type = 'level_up' AND u.ts <= d.ts) AS level
  FROM telemetry.gameplay_events d
  WHERE d.event_type = 'death' AND d.ts > now() - interval '${DAYS} days'
)
SELECT width_bucket(level, 1, 61, 6) AS bracket,
       min(level) || '-' || max(level) AS level_range,
       count(*) AS deaths
FROM deaths GROUP BY bracket ORDER BY bracket;"

echo; echo "=== end of report ==="
