-- T-034: Per-objective quest progress. One row per (character, quest, objective index).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/005_add_quest_objectives.sql

CREATE TABLE IF NOT EXISTS chars.character_quest_objectives (
    character_id     BIGINT  NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    quest_id         TEXT    NOT NULL,
    objective_index  INT     NOT NULL,
    progress         INT     NOT NULL DEFAULT 0 CHECK (progress >= 0),
    PRIMARY KEY (character_id, quest_id, objective_index)
);
CREATE INDEX IF NOT EXISTS idx_cqo_char_quest
    ON chars.character_quest_objectives (character_id, quest_id);
