-- T-360: Rested XP — the banked "log-off is a gift" pool (game-direction.md §2/§4).
-- Apply: psql -h 127.0.0.1 -U avalon -d avalon -f infra/postgres/migrations/012_add_rested_xp.sql
--
-- Two durable columns on the character, mirroring migration-011's ADD COLUMN IF NOT EXISTS pattern:
--   rested_pool        the banked rested XP-equivalent, spent as bonus XP on quest turn-ins
--                      (rested_logic.split_award drains it). 0 = nothing banked. Capped in code at
--                      1.5 * the current level's XP span (WoW's 150% ceiling), so no DB constraint.
--   rested_logout_at   unix seconds the character logged out = the start of the current offline
--                      accrual window. 0 (default) = currently online / no pending window. On login
--                      the server banks accrual for (now - rested_logout_at) then resets this to 0,
--                      so time spent ONLINE never accrues rested (accrual is offline-only, by
--                      design). A crash with no clean logout leaves it 0 -> zero accrual that
--                      session: conservative, never over-grants.

ALTER TABLE chars.characters
    ADD COLUMN IF NOT EXISTS rested_pool      INT    NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS rested_logout_at BIGINT NOT NULL DEFAULT 0;
