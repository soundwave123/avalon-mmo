-- T-507: multi-character accounts — account (auth.accounts.username) -> N characters.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/044_add_multi_character.sql
--
-- ONE-TIME MIGRATION (non-destructive): the existing 1:1 character per account becomes
-- slot 0, keeping its id — so every per-character table (inventory, quests, talents,
-- discoveries, vault, cosmetic_currency, ... all keyed on character_id) is untouched and
-- all existing data survives intact.
--
--   * name: the character's unique display/gameplay identity. Backfilled from username so
--     the world/master RPC surface (which now flows the character NAME where it used to
--     flow the username) behaves identically for every pre-migration character.
--   * slot: 0..N-1 within the account (cap enforced app-side; 3 for the playtest).
--   * deleted_at: soft delete — frees the name/slot (partial unique indexes) while
--     preserving rows for support/undelete. Gameplay reads filter it out.
--
-- The old UNIQUE(username) drops: an account may now own several characters. Uniqueness
-- moves to (name) and (username, slot) over LIVE rows only.

ALTER TABLE chars.characters
    ADD COLUMN IF NOT EXISTS name TEXT,
    ADD COLUMN IF NOT EXISTS slot SMALLINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Backfill: the pre-existing single character per account lands at slot 0 (column default)
-- with name = username. Idempotent — re-running never overwrites a chosen name.
UPDATE chars.characters SET name = username WHERE name IS NULL;

ALTER TABLE chars.characters ALTER COLUMN name SET NOT NULL;

-- Multi-character unlock: one account, many rows.
ALTER TABLE chars.characters DROP CONSTRAINT IF EXISTS characters_username_key;

-- Live-row uniqueness: character names are globally unique among non-deleted characters;
-- an account can hold each slot at most once. Deleting a character frees both.
CREATE UNIQUE INDEX IF NOT EXISTS uq_characters_name_live
    ON chars.characters (name) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_characters_account_slot_live
    ON chars.characters (username, slot) WHERE deleted_at IS NULL;

-- Account-roster listing path (login char-select).
CREATE INDEX IF NOT EXISTS idx_characters_account_live
    ON chars.characters (username) WHERE deleted_at IS NULL;
