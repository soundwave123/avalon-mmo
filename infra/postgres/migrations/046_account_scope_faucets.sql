-- T-549: the daily gift/streak (T-450) and the weekly vault (T-480) are RETENTION-RITUAL faucets
-- that must reward the ACCOUNT once per period, not each character. T-507 gave accounts up to 3
-- characters, so per-character keying let one account mint up to 3x the daily/weekly coin the T-475
-- ledger modelled, all flowing into the SHARED auction market. Owner decision (b): per-account caps.
--
-- This re-keys the daily/weekly claim + lockout tracking from character_id to the ACCOUNT username
-- (chars.characters.username). Coin/XP grants still land on whichever character claims first — only
-- the once-per-period GATE moves up to the account. QUESTS stay per-character and are untouched:
-- chars.character_daily_claims (objective / first_completion) keeps its character_id keying, and the
-- daily gift's once-per-account-per-day lockout now lives entirely in character_daily_state's
-- (account, last_login_date). No coin-flow faucet/sink reasons change, so the coin_flow view stands.
--
-- Existing playtest claims are preserved sanely by COLLAPSING each account's per-character rows into
-- one account row (keep the best streak / furthest progress / earliest claim). No row here stores
-- gear, combat power, a countdown, or a banked/lost reward.
--
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/046_account_scope_faucets.sql

BEGIN;

-- ── T-450 daily gift/streak → account ──────────────────────────────────────────────────────────
-- The account's streak state. last_login_date IS the once-per-account-per-day gift lockout: a second
-- character logging in the same day reads this row, sees today already logged, and mints nothing.
CREATE TABLE IF NOT EXISTS chars.character_daily_state_v2 (
    account TEXT PRIMARY KEY,
    last_login_date DATE NOT NULL,
    streak INTEGER NOT NULL CHECK (streak >= 1)
);

-- Collapse per-character streak rows to one per account: furthest login + best streak (never a
-- reset — a lapse on one alt must not erase the account's earned streak). Idempotent re-run safe.
INSERT INTO chars.character_daily_state_v2 (account, last_login_date, streak)
SELECT c.username, MAX(s.last_login_date), MAX(s.streak)
FROM chars.character_daily_state s
JOIN chars.characters c ON c.id = s.character_id
GROUP BY c.username
ON CONFLICT (account) DO NOTHING;

DROP TABLE chars.character_daily_state;
ALTER TABLE chars.character_daily_state_v2 RENAME TO character_daily_state;

-- ── T-480 weekly vault → account ───────────────────────────────────────────────────────────────
-- Per-account per-ISO-week track progress. All of an account's characters build toward ONE shared
-- weekly set (progress caps at each track's goal), so alts share the appointment.
CREATE TABLE IF NOT EXISTS chars.character_weekly_progress_v2 (
    account TEXT NOT NULL,
    week_key DATE NOT NULL,
    track TEXT NOT NULL,
    progress INTEGER NOT NULL DEFAULT 0 CHECK (progress >= 0),
    PRIMARY KEY (account, week_key, track)
);

-- Collapse: an account's furthest progress on each (week, track) across its characters.
INSERT INTO chars.character_weekly_progress_v2 (account, week_key, track, progress)
SELECT c.username, p.week_key, p.track, MAX(p.progress)
FROM chars.character_weekly_progress p
JOIN chars.characters c ON c.id = p.character_id
GROUP BY c.username, p.week_key, p.track
ON CONFLICT (account, week_key, track) DO NOTHING;

DROP TABLE chars.character_weekly_progress;
ALTER TABLE chars.character_weekly_progress_v2 RENAME TO character_weekly_progress;

-- The once-per-account-per-week vault claim (PK account+week IS the gate).
CREATE TABLE IF NOT EXISTS chars.character_weekly_claims_v2 (
    account TEXT NOT NULL,
    week_key DATE NOT NULL,
    choice TEXT NOT NULL,
    claimed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (account, week_key)
);

-- Collapse: keep the FIRST character's claim per (account, week) — whoever claimed first spent the
-- account's claim for that week, exactly the going-forward rule.
INSERT INTO chars.character_weekly_claims_v2 (account, week_key, choice, claimed_at)
SELECT DISTINCT ON (c.username, cl.week_key) c.username, cl.week_key, cl.choice, cl.claimed_at
FROM chars.character_weekly_claims cl
JOIN chars.characters c ON c.id = cl.character_id
ORDER BY c.username, cl.week_key, cl.claimed_at
ON CONFLICT (account, week_key) DO NOTHING;

DROP TABLE chars.character_weekly_claims;
ALTER TABLE chars.character_weekly_claims_v2 RENAME TO character_weekly_claims;

COMMIT;
