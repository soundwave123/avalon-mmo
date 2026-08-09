-- T-007: Add refresh_token_id to auth.sessions for JWT refresh token rotation.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/002_add_refresh_tokens.sql

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'auth' AND table_name = 'sessions' AND column_name = 'refresh_token_id'
    ) THEN
        ALTER TABLE auth.sessions ADD COLUMN refresh_token_id TEXT;
    END IF;
END $$;

-- Index for the atomic rotation query:
-- UPDATE auth.sessions SET refresh_token_id = $1
-- WHERE refresh_token_id = $2 AND revoked = false RETURNING username;
CREATE INDEX IF NOT EXISTS idx_sessions_refresh_token_id
    ON auth.sessions (refresh_token_id)
    WHERE revoked = false;
