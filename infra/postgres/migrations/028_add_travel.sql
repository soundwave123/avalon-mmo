-- T-431: persisted flight-roost discovery plus the baseline learned-mount profile.
-- Flight topology/prices remain world-authored data; this table stores only which nodes a
-- character has personally learned. Mount appearance is a cosmetic id from the T-375 unlock seam;
-- movement power never lives in this schema.
CREATE TABLE IF NOT EXISTS chars.character_flight_nodes (
    character_id BIGINT      NOT NULL REFERENCES chars.characters(id) ON DELETE CASCADE,
    node_id      TEXT        NOT NULL,
    discovered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (character_id, node_id)
);

ALTER TABLE chars.characters
    ADD COLUMN IF NOT EXISTS learned_mount BOOLEAN NOT NULL DEFAULT true,
    ADD COLUMN IF NOT EXISTS active_mount TEXT NOT NULL DEFAULT 'mount_common_gryphon',
    ADD COLUMN IF NOT EXISTS mount_skin TEXT;

-- coin_ledger.py reads this classified view. Re-publish the complete current sink vocabulary so
-- `flight` is counted as coin burned (not the ELSE transfer bucket), alongside later post-016 sinks.
CREATE OR REPLACE VIEW econ.coin_flow AS
SELECT
    l.id, l.ts, l.character_id, l.delta, l.reason, c.level,
    CASE
        WHEN l.reason IN ('quest_reward', 'achievement_reward', 'vendor_sell', 'kill_loot')
            THEN 'faucet'
        WHEN l.reason IN (
            'trainer', 'guild_create', 'vendor_buy', 'service', 'auction_fee', 'repair',
            'vault_upgrade', 'recipe', 'flight'
        ) THEN 'sink'
        ELSE 'transfer'
    END AS flow
FROM econ.coin_ledger l
JOIN chars.characters c ON c.id = l.character_id;
