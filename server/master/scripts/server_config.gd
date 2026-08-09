extends Node
# Autoload singleton — accessible as ServerConfig from anywhere

const SERVER_NAME := "master"
const RPC_LISTEN_PORT := 9100

# PostgreSQL connection constants (per T-006)
# Note: PG_PASSWORD comes from AVALON_PG_PASSWORD env var only (D-008)
const PG_HOST := "127.0.0.1"
const PG_PORT := 5432
const PG_DB := "avalon"
const PG_USER := "avalon"

# JWT configuration (loaded from environment at runtime)
# AVALON_JWT_SECRET — 32+ byte signing secret (required)
# AVALON_JWT_TTL_SECONDS — token lifetime in seconds (default: 7200)

# T-364: bounded death penalty + repair sink tuning. Data-tunable end-to-end — retune death severity
# here with no code change (Durability holds the same values as module DEFAULT_* fallbacks).
const DURABILITY_MAX := 100  # a freshly-worn equipped item seeds at this max durability
const DURABILITY_WEAR_PCT := 0.10  # fraction of MAX each equipped item loses per death (10%)
const DURABILITY_REPAIR_RATE := 1  # BASE coin cost per missing durability point (identity/L1 row)

# T-412: right-size the repair sink to the value of what it mends — coin cost PER missing durability
# point scales with the item's rarity. The base/"common" row equals DURABILITY_REPAIR_RATE, so a
# starter kit repairs at exactly the old flat number (identity); a rare/epic set is a felt coin
# decision. An item whose rarity is unknown (no registry row) falls back to base rate (never free,
# never a crash). One-line retune, no logic change.
const DURABILITY_REPAIR_RATE_TABLE := {
	"junk": 1,
	"common": 1,
	"uncommon": 2,
	"rare": 4,
	"epic": 8,
	"legendary": 12,
}

# T-412: auction-house LISTING FEE — a non-punitive coin SINK charged up-front when a lot is listed
# (a "deposit" the house keeps). Flat base + a proportional cut of the asking price (basis points).
# Data-tunable; set both to 0 to disable. Debited via adjust_coins reason "auction_fee".
const AUCTION_LISTING_FEE_FLAT := 5  # base copper burned per listing
const AUCTION_LISTING_FEE_BPS := 200  # + this many basis points (2%) of min_bid

# T-412: bank vault capacity TIER ladder — a non-punitive coin SINK (buy more storage; zero power).
# Tier 0 is the shipped base capacity, so every existing character reads tier 0 (zero regression).
# VAULT_TIER_COSTS[i] = cost to advance FROM tier i TO tier i+1; an empty array disables upgrades.
const VAULT_TIER_BASE_SLOTS := 12  # tier 0 capacity (matches VaultLogic.VAULT_SLOTS)
const VAULT_TIER_SLOTS_PER := 6  # additional vault slots granted per purchased tier
const VAULT_TIER_COSTS := [500, 1500, 4000]  # to reach tier 1, 2, 3 (data-tunable)


# T-736 (T-745 isolation rule): a harness master must be able to bind OFF the live :9100 —
# AVALON_MASTER_PORT overrides the listen port (the same env the world already reads to find
# its master). Default unchanged; the DB side is already env-tunable (pg_query.sh reads
# PG_HOST/PG_PORT with the subprocess driver).
static func listen_port() -> int:
	var env := OS.get_environment("AVALON_MASTER_PORT")
	return int(env) if env != "" else RPC_LISTEN_PORT
