-- T-361 item 2 (friends/ignore) + T-363 (trade) hardening.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/013_add_social.sql
--
-- character_social: per-character friends + ignore lists, by TARGET ID (rename-proof); names are
-- joined out at read time. One row per (owner, kind, target); both directions are independent
-- (friendship is not mutual, exactly like WoW).
CREATE TABLE IF NOT EXISTS chars.character_social (
    character_id INT  NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    kind         TEXT NOT NULL CHECK (kind IN ('friend', 'ignore')),
    target_id    INT  NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (character_id, kind, target_id)
);

-- T-363 belt-and-braces: the trade commit runs both coin moves inside one transaction; this CHECK
-- makes any overdraft (a validation bug, a future race) abort the WHOLE transaction instead of
-- silently skipping one guarded UPDATE — the atomic-swap invariant enforced at the schema layer.
ALTER TABLE chars.characters DROP CONSTRAINT IF EXISTS characters_coins_nonnegative;
ALTER TABLE chars.characters ADD CONSTRAINT characters_coins_nonnegative CHECK (coins >= 0);
