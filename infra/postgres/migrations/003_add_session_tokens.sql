-- T-010: Create auth.session_tokens table for JWT revocation tracking.
-- Fixes defect: session_manager.gd references session_tokens but no migration
-- previously created it. Placed in auth schema to match auth.sessions.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/003_add_session_tokens.sql

CREATE TABLE IF NOT EXISTS auth.session_tokens (
    token       TEXT        PRIMARY KEY,
    revoked     BOOLEAN     DEFAULT FALSE,
    revoked_at  TIMESTAMPTZ DEFAULT NULL
);

-- Index for revocation check queries:
-- SELECT revoked FROM auth.session_tokens WHERE token = $1
-- (token is PK, already indexed). Partial index for cleanup of revoked tokens:
CREATE INDEX IF NOT EXISTS idx_session_tokens_revoked
    ON auth.session_tokens (revoked_at)
    WHERE revoked = TRUE;
