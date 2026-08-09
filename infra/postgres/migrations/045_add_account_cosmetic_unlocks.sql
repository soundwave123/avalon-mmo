-- T-548: account-wide cosmetic ownership for ACCOUNT-EARNED prestige (the T-395 account-mastery
-- track). Mastery is earned by the whole ACCOUNT (subject = auth/login username), but the pre-existing
-- inventory.cosmetic_unlocks is keyed on character_id (migration 018) — so a mastery reward used to
-- land on only the single alt that happened to trigger the level-up, leaving the account's other
-- characters (who helped earn it) unable to wear it. This table owns account-earned unlocks at the
-- ACCOUNT level, so every character on the account — current AND future — can wear them. Store
-- cosmetics (T-476) stay per-character (their cosmetic_currency wallet is per-character); only the
-- account-wide EARNED track lands here.
--
-- WardrobeOps.unlocks_for(character_id) UNIONs this account set (by the character's account username)
-- with the per-character set, so apply/list/decorate all treat account unlocks as wearable. Grants
-- are idempotent (ON CONFLICT DO NOTHING); `source` preserves T-482 provenance ("mastery").
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/045_add_account_cosmetic_unlocks.sql

CREATE TABLE IF NOT EXISTS inventory.account_cosmetic_unlocks (
    account        TEXT         NOT NULL,
    appearance_id  TEXT         NOT NULL,
    source         TEXT         NOT NULL DEFAULT 'grant',
    unlocked_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (account, appearance_id)
);

-- Roster read path: resolve an account's wearable set when decorating any of its characters.
CREATE INDEX IF NOT EXISTS idx_account_cosmetic_unlocks_account
    ON inventory.account_cosmetic_unlocks (account);
