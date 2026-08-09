-- T-683 (guild bank) — a rank-gated, ledgered shared coin/item vault, keyed on the guild.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/052_add_guild_bank.sql
--
-- The shared-SPACE half of the guild loop (the trophy-wall/identity half shipped in T-679, migration
-- 051). Mirrors the T-360/T-475 balance idiom (a persisted coin column) but the SUBJECT is the guild
-- id, not a character — so pooled coin lives OFF the per-character econ.coin_ledger reconciliation
-- (which is keyed on character_id). Every player-side move still writes its own coin_ledger row
-- through ServicesStore.adjust_coins, so characters.coins == sum(coin_ledger.delta) stays exact; the
-- guild vault is a holding account, not a character. NO schema change to chars.guilds itself.
--
-- IDENTITY/UTILITY, NEVER POWER (the T-679/T-482 anti-power-creep charter continues to apply): these
-- tables carry coin + ordinary item_id/count ONLY. There is deliberately no stat, xp, rested, cheaper-
-- anything, or content-entry column anywhere near the bank — it is a shared wallet, not a perk track.

BEGIN;

-- Per-guild coin balance. BIGINT because many members pool into one vault (a character wallet is INT,
-- but the guild sum can exceed a single purse). CHECK (coins >= 0) is the fail-closed floor: an
-- over-withdraw attempt trips the constraint and rolls the whole move back (T-609 no-dupe/no-loss).
-- ON DELETE CASCADE: disband drops the row — GuildBankStore.resolve_on_disband() returns the balance
-- to the leader in the SAME transaction BEFORE the guild row is deleted, so no coin is orphaned.
CREATE TABLE IF NOT EXISTS chars.guild_bank (
    guild_id INT    NOT NULL PRIMARY KEY REFERENCES chars.guilds(id) ON DELETE CASCADE,
    coins    BIGINT NOT NULL DEFAULT 0 CHECK (coins >= 0)
);

-- Per-guild item vault — ORDINARY items only, aggregated by item_id (one row per stack-kind, not a
-- slot layout: a shared vault has no personal bag geometry). item_count > 0 is enforced so a fully-
-- withdrawn stack deletes its row rather than lingering at zero. The item's identity is its item_id;
-- the bank never reads item stats/power — it only holds the count.
CREATE TABLE IF NOT EXISTS chars.guild_bank_item (
    guild_id   INT  NOT NULL REFERENCES chars.guilds(id) ON DELETE CASCADE,
    item_id    TEXT NOT NULL,
    item_count INT  NOT NULL CHECK (item_count > 0),
    PRIMARY KEY (guild_id, item_id)
);

-- Per the migration-032 un-drop rule: this CASE is COPIED verbatim from 050 (the highest-numbered
-- prior definition) with exactly two additions — 'guild_bank_deposit' in the sink list and
-- 'guild_bank_withdraw' in the faucet list. Never rewrite from memory.
--   deposit  = wallet -> bank : money LEAVES the player-coin supply into the holding vault (SINK-side)
--   withdraw = bank -> wallet : money RETURNS to the player-coin supply (FAUCET-side)
-- Over a deposit+withdraw cycle this is NET-ZERO and never mints new money; parked bank coin is coin
-- not chasing inflation (the T-475 economy audit wants exactly this holding). The disband payout to
-- the leader reuses 'guild_bank_withdraw' (it IS a bank->wallet return), so no third reason is added.
CREATE OR REPLACE VIEW econ.coin_flow AS
SELECT
    l.id, l.ts, l.character_id, l.delta, l.reason, c.level,
    CASE
        WHEN l.reason IN (
            'quest_reward', 'achievement_reward', 'vendor_sell', 'kill_loot',
            'daily_reward', 'discovery_reward', 'starting_grant', 'guild_bank_withdraw'
        ) THEN 'faucet'
        WHEN l.reason IN (
            'trainer', 'guild_create', 'vendor_buy', 'service', 'auction_fee', 'repair',
            'vault_upgrade', 'recipe', 'flight', 'talent_reroll', 'mount_training',
            'guild_bank_deposit'
        ) THEN 'sink'
        ELSE 'transfer'
    END AS flow
FROM econ.coin_ledger l
JOIN chars.characters c ON c.id = l.character_id;

COMMIT;
