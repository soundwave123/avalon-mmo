-- T-610: the starting 100 coins (chars.characters.coins DEFAULT 100, migration 008) were never
-- written to econ.coin_ledger — every character that has ever existed carries an exact 100-coin
-- gap between its true balance and its ledger sum (confirmed on all 21 live characters, session
-- econ-11), so the coin_flow/coin_flow_daily faucet rollups undercount the real money supply by
-- 100 × character count, forever. From this migration on the two INSERT paths
-- (master CharacterManager.ensure_character, gateway CharacterRoster.create_character) write the
-- grant into the ledger atomically via a CTE in the same statement as the character row; this
-- migration backfills the historical gap and registers the new reason in the classified view.
-- Reconciliation invariant (tools/coin_ledger.py --reconcile): for every character,
-- characters.coins == sum(coin_ledger.delta) for that character.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/050_ledger_starting_grant.sql

BEGIN;

-- Backfill: one starting_grant row per character for its measured gap (exactly 100 everywhere
-- today; computed per-row so the invariant lands exact even if a row has drifted differently).
-- Soft-deleted characters are included — their ledger rows exist and must reconcile too.
-- A NEGATIVE gap (ledger > balance) is left alone deliberately: that would be a real discrepancy
-- with a different cause, and --reconcile will surface it rather than have us paper over it here.
INSERT INTO econ.coin_ledger (character_id, delta, reason)
SELECT c.id, c.coins - COALESCE(l.balance, 0), 'starting_grant'
FROM chars.characters c
LEFT JOIN (
    SELECT character_id, SUM(delta) AS balance
    FROM econ.coin_ledger GROUP BY character_id
) l ON l.character_id = c.id
WHERE c.coins - COALESCE(l.balance, 0) > 0;

-- Per the migration-032 un-drop rule: this CASE is COPIED from 048 (the highest-numbered prior
-- definition) with exactly one addition, 'starting_grant' in the faucet list. Never rewrite from
-- memory. It IS a faucet — it mints supply — but tools/coin_ledger.py excludes it from the band
-- sink-ratio guard (one-time seed, not loop income). coin_flow_daily (migration 016) selects
-- FROM this view, so the supply dashboard picks the classification up automatically.
CREATE OR REPLACE VIEW econ.coin_flow AS
SELECT
    l.id, l.ts, l.character_id, l.delta, l.reason, c.level,
    CASE
        WHEN l.reason IN (
            'quest_reward', 'achievement_reward', 'vendor_sell', 'kill_loot',
            'daily_reward', 'discovery_reward', 'starting_grant'
        ) THEN 'faucet'
        WHEN l.reason IN (
            'trainer', 'guild_create', 'vendor_buy', 'service', 'auction_fee', 'repair',
            'vault_upgrade', 'recipe', 'flight', 'talent_reroll', 'mount_training'
        ) THEN 'sink'
        ELSE 'transfer'
    END AS flow
FROM econ.coin_ledger l
JOIN chars.characters c ON c.id = l.character_id;

COMMIT;
