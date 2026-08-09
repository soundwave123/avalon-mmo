-- T-734: world-global scalar state — the first world-scoped singleton store (the day/night
-- clock). The world server owns the live value (world_clock.gd) and checkpoints it here through
-- the master (world_state_op), so a world restart resumes the shared time of day instead of
-- resetting every player's sky to the boot default. One row per key; day_t (0..1, noon = 0.25,
-- the T-415 convention) is the only key today. The `world` schema itself already exists
-- (init.sql creates it with only a heartbeat table).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/056_add_world_clock.sql

CREATE TABLE IF NOT EXISTS world.state (
    key TEXT PRIMARY KEY,
    value DOUBLE PRECISION NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
