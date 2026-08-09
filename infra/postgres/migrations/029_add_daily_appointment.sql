-- T-450: ethical daily appointment state. Claims are additive/idempotent; no row stores gear,
-- combat power, a countdown, or lost/banked rewards. The world injects the UTC date key.
CREATE TABLE IF NOT EXISTS chars.character_daily_state (
    character_id BIGINT PRIMARY KEY REFERENCES chars.characters(id) ON DELETE CASCADE,
    last_login_date DATE NOT NULL,
    streak INTEGER NOT NULL CHECK (streak >= 1)
);

CREATE TABLE IF NOT EXISTS chars.character_daily_claims (
    character_id BIGINT NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    date_key DATE NOT NULL,
    claim_kind TEXT NOT NULL,
    content_id TEXT NOT NULL DEFAULT '',
    claimed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (character_id, date_key, claim_kind, content_id)
);

-- Keep the canonical coin-flow view honest: daily gifts mint coin and are never transfers.
CREATE OR REPLACE VIEW econ.coin_flow AS
SELECT
    l.id, l.ts, l.character_id, l.delta, l.reason, c.level,
    CASE
        WHEN l.reason IN (
            'quest_reward', 'achievement_reward', 'vendor_sell', 'kill_loot', 'daily_reward'
        ) THEN 'faucet'
        WHEN l.reason IN (
            'trainer', 'guild_create', 'vendor_buy', 'service', 'auction_fee', 'repair',
            'vault_upgrade', 'recipe', 'flight'
        ) THEN 'sink'
        ELSE 'transfer'
    END AS flow
FROM econ.coin_ledger l
JOIN chars.characters c ON c.id = l.character_id;
