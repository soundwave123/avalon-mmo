-- T-678: renown v1 — per-character, per-hub standing points (owner decision 2026-08-08:
-- per-character on the achievement-credit seam; account-wide stays a possible LATER migration,
-- which this shape keeps cheap: one row per (character, hub), aggregate by account to migrate).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/054_add_renown.sql
--
-- hub_id references the data registry (server/master/data/renown_ranks.json), not a table —
-- adding a hub (Highkeep + Ashmoor today, more per zone pass) is a JSON edit, no schema change.
-- Points are a monotonic total; ranks are derived from data thresholds, never stored.
CREATE TABLE IF NOT EXISTS chars.character_renown (
    character_id INT  NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    hub_id       TEXT NOT NULL,
    points       INT  NOT NULL DEFAULT 0,
    PRIMARY KEY (character_id, hub_id)
);
