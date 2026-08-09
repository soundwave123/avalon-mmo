-- T-390: PvP rating + seasonal ladder backbone — the competitive spine (fun-audit run 1).
-- MODEL-AGNOSTIC (owner-input-queue row A): this is the rating DATA SPINE only. The reward payout
-- (T-391), matchmaking guards (T-392), and PvP combat/consent (T-381, owner-gated) are separate.
-- Apply: podman exec -i avalon-postgres psql -U avalon -d avalon < infra/postgres/migrations/017_add_pvp_ratings.sql
CREATE SCHEMA IF NOT EXISTS pvp;

-- seasons: one row per fixed wall-clock window. id is the DETERMINISTIC ordinal derived from the
-- SERVER clock (PvpSeason.season_for) — season 1 at the epoch, +1 each SEASON_SECS. No client input
-- names a season. Upserted (ON CONFLICT DO NOTHING) the first time a match lands inside the window.
CREATE TABLE IF NOT EXISTS pvp.seasons (
    id         INT PRIMARY KEY,           -- server-clock ordinal (NOT a SERIAL surrogate)
    starts_at  TIMESTAMPTZ NOT NULL,
    ends_at    TIMESTAMPTZ NOT NULL
);

-- ratings: one row per (character, season, bracket). The PRIMARY KEY makes the triple unique — a
-- character has AT MOST one rating per bracket per season. rating is the Elo/MMR number (EloRating);
-- wins/losses drive both the placement K-boost and the leaderboard. A season rollover writes NEW
-- rows in the next season, soft-reset toward the mean — last season's rows stay as the snapshot.
CREATE TABLE IF NOT EXISTS pvp.ratings (
    character_id INT NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    season_id    INT NOT NULL,
    bracket      TEXT NOT NULL,           -- 'duel' to start (T-381 consensual surface); WvW-scale later
    rating       INT NOT NULL DEFAULT 1500,
    wins         INT NOT NULL DEFAULT 0,
    losses       INT NOT NULL DEFAULT 0,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (character_id, season_id, bracket)
);
-- Leaderboard access path: top-N by rating within one season+bracket.
CREATE INDEX IF NOT EXISTS ratings_leaderboard ON pvp.ratings (season_id, bracket, rating DESC);
