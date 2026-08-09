-- T-740: provisioned accounts are handed a ONE-TIME password, not a permanent one.
--
-- While this flag is true the gateway refuses to open a session for that account: correct
-- credentials answer `password_change_required` instead of tokens, and only the `set_password`
-- round trip (which re-hashes the player's own choice and clears the flag in the same UPDATE)
-- yields a login. The flag is the ONLY source of truth for "this password is still the one we
-- mailed out" — the gateway never takes that fact from the client.
--
-- Every existing account defaults to false and keeps working exactly as before.
ALTER TABLE auth.accounts
    ADD COLUMN IF NOT EXISTS password_is_otp BOOLEAN NOT NULL DEFAULT false;
