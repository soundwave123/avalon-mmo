-- T-428: true per-character/per-equip-slot wardrobe state. T-375 reserved cosmetic columns on the
-- item row; this table completes the model so swapping stat gear cannot move/erase a chosen look.
-- Every column is presentation-only. Combat continues to read inventory.character_items.item_id.

CREATE TABLE IF NOT EXISTS inventory.character_appearance (
    character_id   BIGINT  NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    slot_type      TEXT    NOT NULL CHECK (
        slot_type IN ('weapon','offhand','head','chest','legs','shoulders')
    ),
    appearance_id  TEXT    NOT NULL DEFAULT '',
    display_item   TEXT    NOT NULL DEFAULT '',
    armor_type     TEXT    NOT NULL DEFAULT 'none',
    dye_id         TEXT    NOT NULL DEFAULT '',
    dye_color      TEXT    NOT NULL DEFAULT '',
    dye_mask       TEXT    NOT NULL DEFAULT 'all',
    hidden         BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (character_id, slot_type),
    CHECK (slot_type = 'head' OR hidden = FALSE)
);
