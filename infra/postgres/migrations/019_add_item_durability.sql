-- T-364: per-equipped-item DURABILITY channel — the bounded death penalty (gear wears on death) and
-- the repair coin sink (the first real sink T-366 was holding for; repair debits via
-- ServicesStore.adjust_coins reason "repair", so it lands in econ.coin_ledger).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/019_add_item_durability.sql
--
-- Kept in a SEPARATE table keyed to the equipped row's identity (character_id, slot_type, slot_index)
-- rather than as columns on inventory.character_items, so the shared inventory serialization
-- (inventory_persist: era-carry / transmog / player-trade all splice the same INSERT) is untouched.
-- FAIL-OPEN: a slot with no row here is INDESTRUCTIBLE — old items, bag items, anything never yet
-- worn on a death read as full-strength, so this migration is a zero-regression add.
CREATE TABLE IF NOT EXISTS inventory.item_durability (
    character_id  BIGINT  NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    slot_type     TEXT    NOT NULL,
    slot_index    INT     NOT NULL DEFAULT 0,
    current_dur   INT     NOT NULL CHECK (current_dur >= 0),
    max_dur       INT     NOT NULL CHECK (max_dur > 0),
    PRIMARY KEY (character_id, slot_type, slot_index)
);
