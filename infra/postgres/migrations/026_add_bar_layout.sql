-- T-422c: the character's ACTION-BAR LAYOUT — an ordered list of ability ids naming which ability
-- sits in which bar slot (slot i is always hotkey i, so the order IS the key binding). This is a pure
-- PREFERENCE/customization (never read by combat or gating), persisted so a player's arrangement
-- follows the character across logins. Stored as a JSON array of ability ids in one column; NULL =
-- no custom layout (every existing character), so this is a zero-regression add and the world falls
-- back to the default registry kit order.
--
-- Server-authority: the ONLY write path is the world's set_bar_layout intent, which the world
-- VALIDATES is a permutation of the character's KNOWN kit ids (rejecting any unknown/duplicate/unowned
-- ability id) BEFORE it calls master to persist here — a client can never place an ability it has not
-- learned (adversarial-tested via BarLayoutOps.sanitize in test_adversarial_client.gd). Master only
-- stores the already-validated order.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/026_add_bar_layout.sql
ALTER TABLE chars.characters
    ADD COLUMN IF NOT EXISTS bar_layout JSONB;
