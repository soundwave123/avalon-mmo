-- T-064: per-character spent talent ranks. The master is the single writer; ranks are
-- upserted by spend_talent and cleared wholesale on reroll.
CREATE TABLE IF NOT EXISTS chars.character_talents (
    character_id INTEGER NOT NULL REFERENCES chars.characters (id) ON DELETE CASCADE,
    talent_id TEXT NOT NULL,
    ranks INTEGER NOT NULL DEFAULT 1 CHECK (ranks >= 1),
    PRIMARY KEY (character_id, talent_id)
);
