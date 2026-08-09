-- T-481: additive, power-neutral mentor recognition. Credit advances only through the master's
-- server-observed completion path; grant rows are the idempotency ledger for prestige thresholds.
CREATE TABLE IF NOT EXISTS chars.character_mentor_credit (
    character_id BIGINT      PRIMARY KEY REFERENCES chars.characters(id) ON DELETE CASCADE,
    credit       INTEGER     NOT NULL DEFAULT 0 CHECK (credit >= 0),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS chars.character_mentor_grant (
    character_id BIGINT      NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    grant_key    TEXT        NOT NULL CHECK (grant_key <> ''),
    granted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (character_id, grant_key)
);
