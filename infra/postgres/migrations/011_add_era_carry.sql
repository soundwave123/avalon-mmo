-- T-353: Era gear-carry marks on inventory rows (era-direction.md S4, Rule A).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/011_add_era_carry.sql
--
-- At the rift, instance_service.enter_era -> character_manager.carry_gear_across_era re-scales each
-- held epic/legendary exactly ONE hop and retires (flags, never deletes) everything else. Three
-- nullable/defaulted columns record that decision durably so it survives relog:
--   era_scaled_to  the NEW home era of a carried relic (Ashmoor = 2); NULL = untouched item.
--                  It is ALSO the one-hop guard: a row with a non-NULL value was already carried and
--                  does not re-scale again at the next rift.
--   era_index      the relic's re-scaled abstract power index (S4.1; epic->660, legendary->750 into
--                  Era 2). NULL for untouched items. The balance pass maps this to authored Era-2
--                  stats (S4.4); persisted because it cannot be recomputed on read without rarities.
--   retired        common-through-rare (and spent relics) flagged vendor-only at the crossing. The
--                  honest non-destructive UX: the player KEEPS the row, it is just no longer live.

ALTER TABLE inventory.character_items
    ADD COLUMN IF NOT EXISTS era_scaled_to INT     DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS era_index     INT     DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS retired       BOOLEAN NOT NULL DEFAULT FALSE;
