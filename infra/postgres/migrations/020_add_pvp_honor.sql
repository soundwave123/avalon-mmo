-- T-391: PvP honor economy on the T-390 rating spine (owner-blessed HYBRID reward model).
-- Honor is SERVER-GRANTED from observed match results inside pvp_store.record_match — there is no
-- client verb that credits it. Every mutation writes pvp.honor_ledger (the T-366 ledger discipline
-- applied to the second currency). Season payouts are idempotent via pvp.season_grants.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/020_add_pvp_honor.sql

-- Per-character, per-season honor balance + the single active reward track.
CREATE TABLE IF NOT EXISTS pvp.honor (
    character_id  BIGINT  NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    season_id     INTEGER NOT NULL,
    balance       INTEGER NOT NULL DEFAULT 0 CHECK (balance >= 0),
    active_track  TEXT    NOT NULL DEFAULT '',
    PRIMARY KEY (character_id, season_id)
);

-- Append-only honor movement record (mirror of econ.coin_ledger; tools can aggregate both).
CREATE TABLE IF NOT EXISTS pvp.honor_ledger (
    id            BIGSERIAL PRIMARY KEY,
    character_id  BIGINT      NOT NULL,
    season_id     INTEGER     NOT NULL,
    delta         INTEGER     NOT NULL,
    reason        TEXT        NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS honor_ledger_char_idx ON pvp.honor_ledger (character_id, season_id);

-- Idempotency spine for season-end payouts: one grant per character/season/kind, ever.
CREATE TABLE IF NOT EXISTS pvp.season_grants (
    character_id  BIGINT      NOT NULL,
    season_id     INTEGER     NOT NULL,
    grant_kind    TEXT        NOT NULL,
    granted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (character_id, season_id, grant_kind)
);

-- Reward-track progress (tier = highest COMPLETED tier index, -1 = none).
CREATE TABLE IF NOT EXISTS pvp.track_progress (
    character_id  BIGINT  NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    track_id      TEXT    NOT NULL,
    tier          INTEGER NOT NULL DEFAULT -1,
    PRIMARY KEY (character_id, track_id)
);
