-- T-451: opt-in social discovery. Guilds are private by default until an invite-ranked member
-- explicitly opens recruitment; all characters default into the moderated help channel and may
-- persistently opt out. Both changes are additive and safe for existing rows.
ALTER TABLE chars.guilds
    ADD COLUMN IF NOT EXISTS recruitment_open BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS recruitment_blurb TEXT NOT NULL DEFAULT '';

ALTER TABLE chars.characters
    ADD COLUMN IF NOT EXISTS help_subscribed BOOLEAN NOT NULL DEFAULT true;
