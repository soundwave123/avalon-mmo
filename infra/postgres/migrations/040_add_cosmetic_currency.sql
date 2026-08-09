-- T-476: back the phantom `cosmetic_currency` with a real, persisted, server-authoritative balance,
-- and give the store loop its earn/spend ledger. Path (b): earned currency minted by the power-neutral
-- earn hooks (daily/streak/discovery/vault), spent in the cosmetic store on wardrobe.json catalog
-- looks, granted through WardrobeOps.grant_unlock. T-482: record the grant `source` so a store grant
-- is auditably distinct from an earned/achievement/drop grant (the charter seam guard).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/040_add_cosmetic_currency.sql

-- The balance. Copper-style single integer, never negative (the store validates before debit; this
-- CHECK is the last line of defence). Zero for every existing character = no behaviour change.
ALTER TABLE chars.characters
    ADD COLUMN IF NOT EXISTS cosmetic_currency INT NOT NULL DEFAULT 0
        CHECK (cosmetic_currency >= 0);

-- T-482 charter: every unlock records HOW it was acquired. 'grant' is the neutral default for the
-- existing achievement/drop/mentor grants; the store writes 'store'. This makes a store-sourced grant
-- auditably distinct and lets the seam-guard prove no randomized path ever wrote a store unlock.
ALTER TABLE inventory.cosmetic_unlocks
    ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'grant';

-- Append-only record of every cosmetic-currency movement (mirrors econ.coin_ledger). SERVER-OBSERVED
-- ONLY: written from ServicesStore.adjust_cosmetic_currency (mint from earn hooks = +, store spend = -),
-- never from a client verb. Lets a future report show mint-vs-spend so the currency can't silently
-- inflate or become dead (no sink).
CREATE TABLE IF NOT EXISTS econ.cosmetic_currency_ledger (
    id           BIGSERIAL   PRIMARY KEY,
    ts           TIMESTAMPTZ NOT NULL DEFAULT now(),
    character_id BIGINT      NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    delta        INT         NOT NULL,   -- signed: + mint (earn hook), - spend (store purchase)
    reason       TEXT        NOT NULL    -- daily_cosmetic | discovery_cosmetic | vault_cosmetic | cosmetic_purchase
);
CREATE INDEX IF NOT EXISTS cosmetic_currency_ledger_ts_idx
    ON econ.cosmetic_currency_ledger (ts);
CREATE INDEX IF NOT EXISTS cosmetic_currency_ledger_reason_idx
    ON econ.cosmetic_currency_ledger (reason, ts);
