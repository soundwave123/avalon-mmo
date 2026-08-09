-- T-392: PvP loss-aversion guardrail — the rank-shield charge count per rating row. `shield` is the
-- number of losses still BUFFERED at the current tier boundary before an actual demotion fires
-- (Valorant-style rank shield). It is SERVER state, mutated only inside the server-observed
-- PvpStore.record_match via RankShield; no client verb sets it. A fresh/seeded row starts with the
-- published default (data/pvp_matchmaking.json shield.charges = 3).
-- Apply: podman exec -i avalon-postgres psql -U avalon -d avalon < infra/postgres/migrations/024_add_pvp_shield.sql
ALTER TABLE pvp.ratings ADD COLUMN IF NOT EXISTS shield INT NOT NULL DEFAULT 3;
