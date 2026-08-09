-- T-613: the mail system — mailbox NPC send/receive with coin+item attachments held IN the mail
-- row until taken (escrow semantics; a failed take never destroys an attachment). This is also the
-- designated fail-closed fallback landing spot for T-609 (AH settlement, bag-full) and T-649
-- (pending loot) — wiring those callers to mail is a follow-up, not part of this migration.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/049_add_mail.sql

BEGIN;

CREATE SCHEMA IF NOT EXISTS mail;

CREATE TABLE IF NOT EXISTS mail.messages (
    id BIGSERIAL PRIMARY KEY,
    from_cid INTEGER NOT NULL REFERENCES chars.characters(id),
    to_cid INTEGER NOT NULL REFERENCES chars.characters(id),
    subject TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    coins INTEGER NOT NULL DEFAULT 0 CHECK (coins >= 0),
    item_id TEXT NOT NULL DEFAULT '',
    item_count INTEGER NOT NULL DEFAULT 0 CHECK (item_count >= 0),
    sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    read_at TIMESTAMPTZ,
    taken_at TIMESTAMPTZ
);

-- The inbox read (WHERE to_cid = $1 ORDER BY sent_at DESC) is the hot path.
CREATE INDEX IF NOT EXISTS mail_messages_to_cid_idx ON mail.messages (to_cid, sent_at DESC);

COMMIT;
