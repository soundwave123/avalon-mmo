-- T-420: the "shoulders" equip slot lights the T-224 pauldrons. inventory.character_items stores
-- worn gear by slot_type; the slot_type CHECK must admit 'shoulders' (mirrors the 008 'vault' add).
-- No new table/column — a shoulders item is just another single-equip row (slot_index 0).
ALTER TABLE inventory.character_items DROP CONSTRAINT IF EXISTS character_items_slot_type_check;
ALTER TABLE inventory.character_items ADD CONSTRAINT character_items_slot_type_check
    CHECK (slot_type IN ('bag', 'head', 'chest', 'legs', 'weapon', 'offhand', 'vault', 'shoulders'));
