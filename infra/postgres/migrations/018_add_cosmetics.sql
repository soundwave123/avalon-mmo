-- T-375: cosmetic / transmog data seam (game-direction.md §1.6/§4 — cosmetics-only store).
-- Reserves the monetization-canon seam BEFORE more gear ships: an equipped item's APPEARANCE channel
-- (what it renders as) becomes separable from its STATS channel (item_id, the only thing combat ever
-- reads). No store, no purchase flow, no economy here — this is the data model the future
-- wardrobe/store fills. (013–017 taken by parallel work; this is the next free slot.)
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/018_add_cosmetics.sql

-- Per-character cosmetic unlock set — the wardrobe's inventory. A future store/quest/drop inserts
-- rows here; server-side cosmetics.can_apply gates every transmog on membership, so a client can
-- never wear a look it hasn't unlocked. Empty for every existing character (nothing unlocked yet =
-- zero behaviour change).
CREATE TABLE IF NOT EXISTS inventory.cosmetic_unlocks (
    character_id   BIGINT       NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    appearance_id  TEXT         NOT NULL,
    unlocked_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (character_id, appearance_id)
);

-- The APPEARANCE channel on an equipped slot. NULL appearance_override = render the real item
-- (every existing row), so this is a zero-regression add. tint is a reserved dye field — stored, not
-- yet rendered (client dye is deferred visual work). Neither column is ever read by combat/stats.
ALTER TABLE inventory.character_items
    ADD COLUMN IF NOT EXISTS appearance_override TEXT,
    ADD COLUMN IF NOT EXISTS tint                TEXT;
