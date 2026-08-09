-- T-480: weekly appointment vault state. Additive/idempotent only: progress caps at each track's
-- goal, the claim row IS the once-per-week gate (PK character+week), and no row stores gear,
-- combat power, a countdown, or lost/banked rewards. week_key is the ISO-week Monday the world's
-- UTC date maps to via the T-473 window arithmetic (a plain DATE, like dungeon_blue_claims).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/034_add_weekly_vault.sql

CREATE TABLE IF NOT EXISTS chars.character_weekly_progress (
    character_id BIGINT NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    week_key DATE NOT NULL,
    track TEXT NOT NULL,
    progress INTEGER NOT NULL DEFAULT 0 CHECK (progress >= 0),
    PRIMARY KEY (character_id, week_key, track)
);

CREATE TABLE IF NOT EXISTS chars.character_weekly_claims (
    character_id BIGINT NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    week_key DATE NOT NULL,
    choice TEXT NOT NULL,
    claimed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (character_id, week_key)
);

-- Keep the canonical coin-flow view honest: the weekly vault mints coin (a faucet, never a
-- transfer). Copied from the HIGHEST-numbered prior definition (032) + ONLY 'weekly_vault' added,
-- per the 032 un-drop rule.
CREATE OR REPLACE VIEW econ.coin_flow AS
SELECT
    l.id, l.ts, l.character_id, l.delta, l.reason, c.level,
    CASE
        WHEN l.reason IN (
            'quest_reward', 'achievement_reward', 'vendor_sell', 'kill_loot',
            'daily_reward', 'discovery_reward', 'weekly_vault'
        ) THEN 'faucet'
        WHEN l.reason IN (
            'trainer', 'guild_create', 'vendor_buy', 'service', 'auction_fee', 'repair',
            'vault_upgrade', 'recipe', 'flight'
        ) THEN 'sink'
        ELSE 'transfer'
    END AS flow
FROM econ.coin_ledger l
JOIN chars.characters c ON c.id = l.character_id;
