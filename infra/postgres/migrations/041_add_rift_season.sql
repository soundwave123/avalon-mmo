-- T-394: seasonal wrap over the T-393 Rift Trials ladder — the per-character end-of-season
-- snapshot. One row per (character, season), written exactly once when the master first observes
-- the season rollover; the INSERT ... ON CONFLICT DO NOTHING RETURNING claim on this primary key
-- is the idempotency spine that gates the whole per-character settle (snapshot + keystone soft
-- reset + seasonal cosmetic grant), mirroring the pvp.season_grants pattern.
--
-- THIS TABLE IS THE T-395 HOOK: the permanent prestige track consumes these rows (best_tier per
-- season, forever) — never delete them. keystone_before/keystone_after audit the soft reset: a
-- bounded regression toward a floor (an UPDATE of rift.keystone.tier only), NEVER a wipe and
-- NEVER a DELETE of characters/gear/coin/cosmetics (the eternal-home contract).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/041_add_rift_season.sql

CREATE TABLE IF NOT EXISTS rift.season_snapshot (
    character_id BIGINT NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    season_id INTEGER NOT NULL,
    best_tier INTEGER NOT NULL CHECK (best_tier >= 1),
    keystone_before INTEGER NOT NULL CHECK (keystone_before >= 1),
    keystone_after INTEGER NOT NULL CHECK (keystone_after >= 1),
    ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (character_id, season_id)
);

-- T-395 reads a whole season's standings at once; keep that read index-backed.
CREATE INDEX IF NOT EXISTS season_snapshot_season_idx
    ON rift.season_snapshot (season_id, best_tier DESC);
