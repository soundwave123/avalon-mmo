-- T-208: the three Highkeep services go real.
-- Coins: the single currency (copper); every price in the catalogs is copper.
ALTER TABLE chars.characters ADD COLUMN IF NOT EXISTS coins INTEGER NOT NULL DEFAULT 100;

-- Bank vault: reuses inventory.character_items with slot_type='vault' (same unique
-- constraint, same loaders) — no new table. Capacity is enforced in logic (12 slots).

-- Auction house: the cross-player economy pillar. Escrow model: a live high bid's coins
-- are already debited from the bidder (refunded on outbid/expiry-without-sale).
CREATE SCHEMA IF NOT EXISTS market;
CREATE TABLE IF NOT EXISTS market.auctions (
    id SERIAL PRIMARY KEY,
    seller_id INTEGER NOT NULL REFERENCES chars.characters (id) ON DELETE CASCADE,
    item_id TEXT NOT NULL,
    item_count INTEGER NOT NULL CHECK (item_count >= 1),
    min_bid INTEGER NOT NULL CHECK (min_bid >= 1),
    buyout INTEGER CHECK (buyout IS NULL OR buyout >= min_bid),
    high_bid INTEGER,
    high_bidder_id INTEGER REFERENCES chars.characters (id) ON DELETE SET NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    state TEXT NOT NULL DEFAULT 'live'  -- live | sold | expired
);
CREATE INDEX IF NOT EXISTS auctions_live_idx ON market.auctions (state, expires_at);

-- Trainer purchases: class-gated ability unlocks (the kit filter reads this).
CREATE TABLE IF NOT EXISTS chars.character_abilities (
    character_id INTEGER NOT NULL REFERENCES chars.characters (id) ON DELETE CASCADE,
    ability_id TEXT NOT NULL,
    PRIMARY KEY (character_id, ability_id)
);

-- vault rides inventory.character_items: the slot_type CHECK must admit it
ALTER TABLE inventory.character_items DROP CONSTRAINT IF EXISTS character_items_slot_type_check;
ALTER TABLE inventory.character_items ADD CONSTRAINT character_items_slot_type_check
    CHECK (slot_type IN ('bag', 'head', 'chest', 'legs', 'weapon', 'offhand', 'vault'));
