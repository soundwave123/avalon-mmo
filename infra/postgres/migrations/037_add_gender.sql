-- T-520: gender chosen at character creation, BEFORE class selection (login -> gender -> class ->
-- world). One text column on chars.characters, NULLABLE so every existing row is valid (a NULL/empty
-- gender is "not yet chosen" and re-triggers the gender panel). CHECK admits only the two values the
-- server accepts (mirrors the class validation in character_manager.set_class); NULL passes the CHECK.
-- Persistence + selection ship now; the visual female/male body-mesh swap is a documented art
-- follow-up (a single shared rig exists today — see appearance_resolver.resolve_player).
ALTER TABLE chars.characters ADD COLUMN IF NOT EXISTS gender TEXT;
ALTER TABLE chars.characters DROP CONSTRAINT IF EXISTS characters_gender_check;
ALTER TABLE chars.characters ADD CONSTRAINT characters_gender_check
    CHECK (gender IS NULL OR gender IN ('female', 'male'));
