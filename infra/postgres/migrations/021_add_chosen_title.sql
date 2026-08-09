-- T-401: the player's CHOSEN display title — one selection off the T-375 cosmetic seam. A `title:`
-- unlock (earned on a PvP reward track, migration 020) is display-only; this column records which one
-- the character is currently wearing so the world can relay it on the positions/gear broadcast and
-- other clients render it under the nameplate. NULL = no title worn (every existing character), so
-- this is a zero-regression add. Never read by combat/stats — a title is pure appearance.
--
-- Server-authority: the ONLY write path is the pvp_track_op "set_title" action, which FAILS CLOSED
-- unless the chosen id is a `title:` unlock already in inventory.cosmetic_unlocks — a client can never
-- wear a title it has not earned (adversarial-tested in test_adversarial_client.gd).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/021_add_chosen_title.sql

ALTER TABLE chars.characters
    ADD COLUMN IF NOT EXISTS chosen_title TEXT;
