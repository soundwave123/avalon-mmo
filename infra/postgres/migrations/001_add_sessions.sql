-- T-003: Create auth.sessions table for session token persistence.
-- Apply manually: make dev-psql < infra/postgres/migrations/001_add_sessions.sql
-- Or: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/001_add_sessions.sql

CREATE TABLE IF NOT EXISTS auth.sessions (
    token      TEXT        PRIMARY KEY,
    username   TEXT        NOT NULL,
    issued_at  TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    revoked    BOOLEAN     DEFAULT FALSE
);

-- Index for validation queries (token is PK, so already indexed).
-- Index for cleanup/audit queries:
CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON auth.sessions (expires_at);
CREATE INDEX IF NOT EXISTS idx_sessions_revoked    ON auth.sessions (revoked) WHERE revoked = FALSE;
