-- T-367: achievements / collections foundation — per-character progress + earned set.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/015_add_achievements.sql
--
-- Progress is a flat counter bag ("kill:*", "kill:wolf", "reach:crypt", "level", ...): the pure
-- AchievementProgress evaluator derives completion from these, so definitions stay data-only
-- (server/master/data/achievements.json) with NO schema change to add an achievement.
CREATE TABLE IF NOT EXISTS chars.character_achievement_counter (
    character_id INT  NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    counter_key  TEXT NOT NULL,
    value        INT  NOT NULL DEFAULT 0,
    PRIMARY KEY (character_id, counter_key)
);

-- character_achievement: the earned set. The row IS the unlock (title/cosmetic); its INSERT is the
-- once-only completion gate (ON CONFLICT DO NOTHING RETURNING → a coin reward is granted exactly
-- for a fresh insert, never twice). achievement_id references the JSON registry, not a table.
CREATE TABLE IF NOT EXISTS chars.character_achievement (
    character_id   INT  NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    achievement_id TEXT NOT NULL,
    earned_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (character_id, achievement_id)
);
