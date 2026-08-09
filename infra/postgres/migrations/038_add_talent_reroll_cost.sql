-- T-475 (T-525 fold-in): the talent reroll becomes a scaling coin sink. Persist the per-character
-- reroll counter that drives TalentLogic.reroll_cost (100 * 2^n, capped 1000), and register the
-- new 'talent_reroll' ledger reason as a sink in econ.coin_flow.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/038_add_talent_reroll_cost.sql

ALTER TABLE chars.characters
    ADD COLUMN IF NOT EXISTS talent_rerolls INT NOT NULL DEFAULT 0 CHECK (talent_rerolls >= 0);

-- Per the migration-032 un-drop rule: this CASE is COPIED from 032 (the highest-numbered prior
-- definition) with exactly one addition — 'talent_reroll' in the sink list. Never rewrite from
-- memory.
CREATE OR REPLACE VIEW econ.coin_flow AS
SELECT
    l.id, l.ts, l.character_id, l.delta, l.reason, c.level,
    CASE
        WHEN l.reason IN (
            'quest_reward', 'achievement_reward', 'vendor_sell', 'kill_loot',
            'daily_reward', 'discovery_reward'
        ) THEN 'faucet'
        WHEN l.reason IN (
            'trainer', 'guild_create', 'vendor_buy', 'service', 'auction_fee', 'repair',
            'vault_upgrade', 'recipe', 'flight', 'talent_reroll'
        ) THEN 'sink'
        ELSE 'transfer'
    END AS flow
FROM econ.coin_ledger l
JOIN chars.characters c ON c.id = l.character_id;
