-- T-550: ACCOUNT-level onboarding state — the seam that makes tutorial-skip + control hints agree
-- across the multi-character era (T-507). Both halves of the T-426 teaching layer were scoped
-- differently (tutorial = per-character in chars.character_quests; hints = per-DEVICE in
-- user://onboarding.cfg), so an alt replayed the quest chain but got no hints. This table moves the
-- fire-once memory to the ACCOUNT (auth.accounts.username), server-authoritative:
--
--   * account_progress.tutorial_done — set exactly once, when ANY character on the account turns in
--     the graduation quest (q_tut_03). A new alt on a graduated account is NOT force-fed the chain
--     (still OFFERED from Drillmaster Hale — availability is unchanged); the account's first-ever
--     character still gets the full guided onboarding. The ONLY writer is the server-observed
--     turn-in path (TutorialOps.note_graduation) — no client verb can forge graduation.
--   * hint_seen — one row per (account, hint_id) the account has ever seen. Once the account has
--     seen a control hint on any character/device, alts don't re-nag; the account's first character
--     still gets every hint. Client reports a sighting (onboarding_hint_seen intent); the row only
--     ever gets SET, never cleared, so a forged report can suppress your OWN nag and nothing else.
--
-- Account keys are auth.accounts.username; the server resolves the account from the authenticated
-- character (never from client input) before reading/writing here.
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/047_add_account_onboarding.sql

CREATE SCHEMA IF NOT EXISTS onboarding;

CREATE TABLE IF NOT EXISTS onboarding.account_progress (
    account       TEXT        PRIMARY KEY,
    tutorial_done BOOLEAN     NOT NULL DEFAULT false,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS onboarding.hint_seen (
    account TEXT        NOT NULL,
    hint_id TEXT        NOT NULL,
    seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account, hint_id)
);
