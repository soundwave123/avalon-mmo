-- T-333: one soft-lockout stamp per character and dungeon boss.
CREATE TABLE IF NOT EXISTS chars.dungeon_blue_claims (
    character_id BIGINT NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    boss_id TEXT NOT NULL,
    last_blue_date DATE NOT NULL,
    PRIMARY KEY (character_id, boss_id)
);
