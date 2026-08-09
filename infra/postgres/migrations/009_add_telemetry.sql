-- T-186: telemetry foundation — an append-only gameplay event log the retention KPIs
-- (D1/D7/D30, session length, time-to-level, deaths/level) all derive from. Master is the
-- single writer (architecture rule); the world batches events and ships them fire-and-forget.
CREATE SCHEMA IF NOT EXISTS telemetry;

CREATE TABLE IF NOT EXISTS telemetry.gameplay_events (
    id BIGSERIAL PRIMARY KEY,
    ts TIMESTAMPTZ NOT NULL DEFAULT now(),
    account TEXT,          -- login account (nullable: some events predate a resolved account)
    character TEXT,        -- character/username the event is about (nullable for account-level)
    event_type TEXT NOT NULL,  -- session_start | session_end | level_up | death | respawn | ...
    payload JSONB NOT NULL DEFAULT '{}'::jsonb
);

-- Rollup access paths: by event type over time (DAU, sessions/day, time-to-level), and per
-- character over time (a single player's session/level/death timeline).
CREATE INDEX IF NOT EXISTS gameplay_events_type_ts_idx
    ON telemetry.gameplay_events (event_type, ts);
CREATE INDEX IF NOT EXISTS gameplay_events_char_ts_idx
    ON telemetry.gameplay_events (character, ts);
