-- T-393: Rift Trials keystone ladder — per-character keystone tier (server-adjudicated up/downgrade
-- on timed clear/fail), per-season best-tier score (the leaderboard read), and a verdict ledger
-- (T-366 ledger discipline: every tier change carries its reason). bad_luck is the HONEST
-- bad-luck-floor counter for the scaled M7 loot roll — consecutive misses raise the next roll's
-- odds until a guaranteed hit, then reset; pure fairness, never purchasable (no pity-for-money).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/039_add_rift_ladder.sql

CREATE SCHEMA IF NOT EXISTS rift;

CREATE TABLE IF NOT EXISTS rift.keystone (
    character_id BIGINT PRIMARY KEY REFERENCES chars.characters(id) ON DELETE CASCADE,
    tier INTEGER NOT NULL DEFAULT 1 CHECK (tier >= 1),
    bad_luck INTEGER NOT NULL DEFAULT 0 CHECK (bad_luck >= 0)
);

CREATE TABLE IF NOT EXISTS rift.best_tier (
    character_id BIGINT NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    season_id INTEGER NOT NULL,
    tier INTEGER NOT NULL CHECK (tier >= 1),
    PRIMARY KEY (character_id, season_id)
);

CREATE TABLE IF NOT EXISTS rift.ledger (
    id BIGSERIAL PRIMARY KEY,
    character_id BIGINT NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    season_id INTEGER NOT NULL,
    tier_before INTEGER NOT NULL,
    tier_after INTEGER NOT NULL,
    verdict TEXT NOT NULL,
    ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- The leaderboard read is season + tier ordered; keep it index-backed as the ladder populates.
CREATE INDEX IF NOT EXISTS best_tier_season_idx ON rift.best_tier (season_id, tier DESC);
