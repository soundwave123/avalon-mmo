-- T-470: migration 031 rebuilt econ.coin_flow from a pre-028 baseline, silently dropping the
-- flight/repair/auction_fee/vault_upgrade/recipe sinks and the daily_reward faucet — the T-412
-- inflation guard went blind to them (they fell to 'transfer'). This restores the FULL union:
-- 029's complete vocabulary + 031's discovery_reward. RULE for future migrations (the un-drop
-- guard): never rewrite this CASE from memory — copy the HIGHEST-numbered prior definition and
-- add only your new reason. tools/coin_ledger.py --check cross-checks reasons vs this view.
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
            'vault_upgrade', 'recipe', 'flight'
        ) THEN 'sink'
        ELSE 'transfer'
    END AS flow
FROM econ.coin_ledger l
JOIN chars.characters c ON c.id = l.character_id;
