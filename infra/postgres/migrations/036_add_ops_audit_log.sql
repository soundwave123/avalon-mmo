BEGIN;

CREATE SCHEMA IF NOT EXISTS ops;

CREATE TABLE IF NOT EXISTS ops.audit_log (
    id BIGSERIAL PRIMARY KEY,
    actor TEXT NOT NULL CHECK (length(actor) BETWEEN 1 AND 80),
    action TEXT NOT NULL CHECK (action IN (
        'who', 'announce', 'broadcast', 'msg_group', 'whisper', 'kick', 'ban'
    )),
    target TEXT NOT NULL DEFAULT '',
    reason TEXT NOT NULL DEFAULT '',
    details JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ops_audit_log_created_at
    ON ops.audit_log (created_at DESC);

COMMIT;
