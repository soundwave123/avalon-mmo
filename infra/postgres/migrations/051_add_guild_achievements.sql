-- T-679 (guild collective progression) — guild-SCOPED achievement progress + earned set.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/051_add_guild_achievements.sql
--
-- Mirrors the T-367/T-676 per-character achievement tables (015_add_achievements.sql) but keyed on
-- the GUILD, not the character: a collective milestone (roster kills/gathers/quests, N members at
-- cap, first dungeon/raid clear, N online together) is credited ONCE to the guild, so a member
-- joining a guild that already earned a milestone never re-fires it. The pure AchievementProgress
-- evaluator derives completion from these counters, so guild achievements stay DATA-ONLY
-- (server/master/data/guild_achievements.json) with NO schema change to add one.
CREATE TABLE IF NOT EXISTS chars.guild_achievement_counter (
    guild_id    INT  NOT NULL REFERENCES chars.guilds(id) ON DELETE CASCADE,
    counter_key TEXT NOT NULL,
    value       INT  NOT NULL DEFAULT 0,
    PRIMARY KEY (guild_id, counter_key)
);

-- guild_achievement: the guild's earned set. The row IS the collective unlock (the guild-earned
-- tabard/crest/cloak eligibility is DERIVED from it); its INSERT is the once-only completion gate
-- (ON CONFLICT DO NOTHING RETURNING). achievement_id references the JSON registry, not a table.
-- ON DELETE CASCADE: disbanding the guild frees its trophy wall (identity dies with the guild).
CREATE TABLE IF NOT EXISTS chars.guild_achievement (
    guild_id       INT  NOT NULL REFERENCES chars.guilds(id) ON DELETE CASCADE,
    achievement_id TEXT NOT NULL,
    earned_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (guild_id, achievement_id)
);
