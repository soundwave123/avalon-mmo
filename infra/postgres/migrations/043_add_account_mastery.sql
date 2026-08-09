-- T-395: horizontal prestige / account-mastery track — the PERMANENT floor beneath the T-394
-- seasonal ladder. mastery.progress is keyed by an abstract TEXT subject (the login/account
-- username in the default account-wide scope; "char:<id>" in the owner-tunable character scope)
-- and is DELIBERATELY not season-keyed: the T-394 soft reset's write-set can never contain a
-- mastery row, which is what makes mastery survive every rollover (the eternal-home discipline).
-- mastery.ledger records every accrual with its server-observed source (T-366 ledger
-- discipline); amounts are CHECK-positive, so the track is monotonic at the schema level.
-- mastery.feed_claim is the exactly-once spine (the pvp.season_grants / rift.season_snapshot
-- pattern) for one-shot feeds such as a season's rift snapshot.
-- Rewards on this track are horizontal ONLY (titles/cosmetics via inventory.cosmetic_unlocks,
-- source 'mastery') — no power stat exists anywhere in this schema, by charter (T-482).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/043_add_account_mastery.sql

CREATE SCHEMA IF NOT EXISTS mastery;

CREATE TABLE IF NOT EXISTS mastery.progress (
    subject TEXT PRIMARY KEY,
    xp BIGINT NOT NULL DEFAULT 0 CHECK (xp >= 0),
    level INTEGER NOT NULL DEFAULT 0 CHECK (level >= 0)
);

CREATE TABLE IF NOT EXISTS mastery.ledger (
    id BIGSERIAL PRIMARY KEY,
    subject TEXT NOT NULL,
    source TEXT NOT NULL,
    amount BIGINT NOT NULL CHECK (amount > 0),
    ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS mastery_ledger_subject_idx ON mastery.ledger (subject, ts);

CREATE TABLE IF NOT EXISTS mastery.feed_claim (
    subject TEXT NOT NULL,
    feed TEXT NOT NULL,
    ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (subject, feed)
);
