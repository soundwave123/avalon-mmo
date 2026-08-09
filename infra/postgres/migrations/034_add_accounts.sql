-- T-501: owner-provisioned tester credentials. The password_hash field contains only the
-- versioned salted digest; plaintext passwords are printed once by scripts/tester-accounts.sh.
CREATE TABLE IF NOT EXISTS auth.accounts (
    username      VARCHAR(20) PRIMARY KEY
                  CHECK (username ~ '^[a-z0-9_-]{3,20}$'),
    password_hash TEXT        NOT NULL
                  CHECK (password_hash ~ '^sha256\$[0-9a-f]{32}\$[0-9a-f]{64}$'),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_active     BOOLEAN     NOT NULL DEFAULT true
);
