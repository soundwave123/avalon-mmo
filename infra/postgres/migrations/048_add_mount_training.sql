-- T-658: one-time learn-to-ride coin cost. Mounts were free-by-keypress (learned_mount BOOLEAN
-- NOT NULL DEFAULT true, migration 028) with a decorative `learned` gate in mount_service.gd — the
-- world always seeded every peer as already-learned. This migration makes the gate real going
-- forward while grandfathering everyone who already has the free mount today:
--   (a) flips the DEFAULT to false, so every character CREATED from here on starts unlearned and
--       must pay TravelOps.learn_mount's level-gated coin sink (REASON_MOUNT_TRAINING) through the
--       riding trainer (reusing npc_hk_flightmaster's existing "flight" service hub — Gryphon
--       Master Kest already sells travel, teaching to ride is the same desk);
--   (b) backfills every EXISTING character to learned_mount = TRUE — no retroactive charge for a
--       mount they already had for free.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/048_add_mount_training.sql

BEGIN;

-- (b) grandfather every character that exists as of this migration.
UPDATE chars.characters SET learned_mount = TRUE;

-- (a) new characters start unlearned; ALTER COLUMN DEFAULT never touches existing rows.
ALTER TABLE chars.characters ALTER COLUMN learned_mount SET DEFAULT false;

-- Per the migration-032 un-drop rule: this CASE is COPIED from 038 (the highest-numbered prior
-- definition — 046 touched account-scoped faucets but explicitly left this view standing) with
-- exactly one addition, 'mount_training' in the sink list. Never rewrite from memory.
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
            'vault_upgrade', 'recipe', 'flight', 'talent_reroll', 'mount_training'
        ) THEN 'sink'
        ELSE 'transfer'
    END AS flow
FROM econ.coin_ledger l
JOIN chars.characters c ON c.id = l.character_id;

COMMIT;
