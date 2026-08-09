-- T-032: Add M2 tables — chars.characters, inventory.character_items, chars.character_quests.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/004_add_m2_tables.sql

CREATE TABLE IF NOT EXISTS chars.characters (
    id         BIGSERIAL    PRIMARY KEY,
    username   TEXT         UNIQUE NOT NULL,
    class      TEXT         NOT NULL DEFAULT 'warrior',
    xp         BIGINT       NOT NULL DEFAULT 0 CHECK (xp >= 0),
    level      INT          NOT NULL DEFAULT 1 CHECK (level >= 1),
    spawn_x    FLOAT        NOT NULL DEFAULT 5.0,
    spawn_y    FLOAT        NOT NULL DEFAULT 5.0,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_characters_username ON chars.characters (username);

CREATE TABLE IF NOT EXISTS inventory.character_items (
    id            BIGSERIAL  PRIMARY KEY,
    character_id  BIGINT     NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    slot_type     TEXT       NOT NULL CHECK (slot_type IN ('bag','head','chest','legs','weapon','offhand')),
    slot_index    INT        NOT NULL DEFAULT 0,
    item_id       TEXT       NOT NULL,
    item_count    INT        NOT NULL DEFAULT 1 CHECK (item_count >= 1),
    UNIQUE (character_id, slot_type, slot_index)
);
CREATE INDEX IF NOT EXISTS idx_character_items_char ON inventory.character_items (character_id);

CREATE TABLE IF NOT EXISTS chars.character_quests (
    character_id  BIGINT       NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    quest_id      TEXT         NOT NULL,
    state         TEXT         NOT NULL DEFAULT 'active'
                               CHECK (state IN ('active','complete','abandoned')),
    accepted_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    completed_at  TIMESTAMPTZ,
    abandoned_at  TIMESTAMPTZ,
    PRIMARY KEY (character_id, quest_id)
);
CREATE INDEX IF NOT EXISTS idx_character_quests_char ON chars.character_quests (character_id);
