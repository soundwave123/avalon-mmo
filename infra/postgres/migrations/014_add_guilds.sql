-- T-362 (guilds) — the highest-value retention system: persistent player guilds.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/014_add_guilds.sql
--
-- guilds: one row per guild. leader_id points at the founding character; a guild is disbanded by
-- deleting the row (ON DELETE CASCADE frees the memberships, and the case-insensitive name index
-- below then frees the name for reuse). Names are unique CASE-INSENSITIVELY so "Knights" and
-- "knights" can't both exist.
CREATE TABLE IF NOT EXISTS chars.guilds (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    leader_id  INT  NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS guilds_name_lower ON chars.guilds (lower(name));

-- guild_members: character_id is the PRIMARY KEY, so a character can belong to AT MOST one guild —
-- the "one guild per character" invariant enforced at the schema layer, not just in code. rank is
-- 0=Leader, 1=Officer, 2=Member (lower = higher authority; see guild_logic.gd). Dropping a guild
-- cascades its memberships away.
CREATE TABLE IF NOT EXISTS chars.guild_members (
    character_id INT NOT NULL PRIMARY KEY REFERENCES chars.characters(id) ON DELETE CASCADE,
    guild_id     INT NOT NULL REFERENCES chars.guilds(id) ON DELETE CASCADE,
    rank         INT NOT NULL DEFAULT 2 CHECK (rank >= 0 AND rank <= 2),
    joined_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS guild_members_guild ON chars.guild_members (guild_id);
