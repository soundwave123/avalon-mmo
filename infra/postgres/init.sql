-- Avalon initial schema
-- Single writer principle: ONLY the master server writes to these tables.
-- Gateway and world servers go through the master via RPC.

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS chars;
CREATE SCHEMA IF NOT EXISTS inventory;
CREATE SCHEMA IF NOT EXISTS world;
CREATE SCHEMA IF NOT EXISTS economy;
CREATE SCHEMA IF NOT EXISTS audit;

-- Set the application search path so unqualified names resolve sensibly.
ALTER DATABASE avalon SET search_path TO chars, world, economy, inventory, auth, audit, public;

-- A minimal table per schema so we can verify connectivity from each server.
-- These will be replaced by real tables in M0 proper.

CREATE TABLE auth.heartbeat (id SERIAL PRIMARY KEY, ts TIMESTAMPTZ DEFAULT NOW());
CREATE TABLE chars.heartbeat (id SERIAL PRIMARY KEY, ts TIMESTAMPTZ DEFAULT NOW());
CREATE TABLE inventory.heartbeat (id SERIAL PRIMARY KEY, ts TIMESTAMPTZ DEFAULT NOW());
CREATE TABLE world.heartbeat (id SERIAL PRIMARY KEY, ts TIMESTAMPTZ DEFAULT NOW());
CREATE TABLE economy.heartbeat (id SERIAL PRIMARY KEY, ts TIMESTAMPTZ DEFAULT NOW());
CREATE TABLE audit.heartbeat (id SERIAL PRIMARY KEY, ts TIMESTAMPTZ DEFAULT NOW());

INSERT INTO audit.heartbeat DEFAULT VALUES;

-- Confirm bootstrap visibly
DO $$
BEGIN
  RAISE NOTICE 'Avalon database initialized at %', NOW();
END
$$;
