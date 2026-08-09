# T-035: XP curve + per-class stat table — pure, deterministic.
#
# `xp` is total accumulated XP; `level` is a pure function of it (capped at MAX_LEVEL).
# Stats are DERIVED from class + level — a level-up "increases stats" because stats follow
# level, so nothing extra is stored. Mirrors the pure-module idiom of T-033/T-034.
#
# HARD CONSTRAINTS: no DB, no OS time, deterministic, inputs never mutated.
# Curve uses 50*(L-1)*L (no division — (L-1)*L is always even) to stay integer-exact.

extends RefCounted

# T-368: era level-cap bands (owner-blessed 2026-07-12: Era-1 1-20, Era-2 20-40, Era-3 40-60).
# The cap is a PARAMETER of the active era, kept as a const TABLE so this pure module does NO I/O
# (no env reads) — flipping eras is a one-line ACTIVE_ERA change. Era-2 (Ashmoor) is live, so
# MAX_LEVEL = the Era-2 cap = 40. The XP curve 50*(L-1)*L is monotonic by construction, so extending
# the clamp from 20 to 40 leaves total_xp_for_level(1..20) BYTE-IDENTICAL (regression-tested,
# test_era1_curve_byte_identical) and only ADDS the L21-40 span.
# Growth is LINEAR (stats_for_level uses inc = level-1 against class_growth.json's flat per-level
# gains), so raising the cap extends stat growth to L40 automatically — no new data rows.
const ERA_LEVEL_CAPS := {1: 20, 2: 40, 3: 60}
const ACTIVE_ERA := 2
# == ERA_LEVEL_CAPS[ACTIVE_ERA]; kept a literal because GDScript const-init cannot subscript a const
# Dictionary. test_cap_matches_active_era_band guards the two from drifting apart.
const MAX_LEVEL := 40

# T-295: the per-class growth curve is authored CONTENT (data/class_growth.json) — promoted from
# T-061's hardcoded table. The JSON is the canonical source; the constants below are a deterministic
# in-code MIRROR used as a fallback if the file is missing (keeps this pure module test-safe:
# leveling tests never depend on disk). Load-once + cache; deterministic (static file, no OS time).
# Class identity: warrior = str + stamina (melee + HP); mage = int (+ a little stamina); priest =
# spirit + int (healing + mana). Unknown class falls back to "warrior". Adding a class is a new row
# in the JSON (mirror the row here too so the fallback stays correct). Roy to confirm (ADR 0010).
const _GROWTH_PATH := "res://data/class_growth.json"
const _BASE_FALLBACK := {"str": 10, "int": 10, "dex": 10, "spirit": 10, "stamina": 10}
const _CLASS_GROWTH_FALLBACK := {
	"warrior": {"str": 3, "int": 0, "dex": 1, "spirit": 0, "stamina": 3},
	"mage": {"str": 0, "int": 3, "dex": 1, "spirit": 1, "stamina": 1},
	"priest": {"str": 1, "int": 2, "dex": 0, "spirit": 3, "stamina": 1},
}

static var _base_cache: Dictionary = {}
static var _growth_cache: Dictionary = {}
static var _loaded: bool = false


# Load the authored growth curve once, caching it. Any load failure falls back to the in-code
# mirror so the module never throws and stays deterministic under headless tests.
static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_base_cache = _BASE_FALLBACK.duplicate(true)
	_growth_cache = _CLASS_GROWTH_FALLBACK.duplicate(true)
	if not FileAccess.file_exists(_GROWTH_PATH):
		return
	var file := FileAccess.open(_GROWTH_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		return
	if parsed.get("base") is Dictionary:
		_base_cache = parsed["base"]
	if parsed.get("per_level") is Dictionary:
		_growth_cache = parsed["per_level"]


static func total_xp_for_level(level: int) -> int:
	var lv: int = clampi(level, 1, MAX_LEVEL)
	return 50 * (lv - 1) * lv


# T-368: the level cap for a given era band. Unknown era falls back to the active MAX_LEVEL so a
# stray lookup never grants an out-of-band cap. The active cap is ERA_LEVEL_CAPS[ACTIVE_ERA].
static func cap_for_era(era: int) -> int:
	return int(ERA_LEVEL_CAPS.get(era, MAX_LEVEL))


static func level_for_total_xp(total_xp: int) -> int:
	var level := 1
	while level < MAX_LEVEL and total_xp >= total_xp_for_level(level + 1):
		level += 1
	return level


# T-060: XP-bar view of total XP — progress INTO the current level + the level's span.
# At MAX_LEVEL needed == 0 (the client renders a full bar).
static func progress(level: int, total_xp: int) -> Dictionary:
	var lv: int = clampi(level, 1, MAX_LEVEL)
	var floor_xp: int = total_xp_for_level(lv)
	if lv >= MAX_LEVEL:
		return {"xp_into_level": maxi(0, total_xp - floor_xp), "xp_for_next_level": 0}
	return {
		"xp_into_level": maxi(0, total_xp - floor_xp),
		"xp_for_next_level": total_xp_for_level(lv + 1) - floor_xp,
	}


static func apply_xp(level: int, xp: int, amount: int) -> Dictionary:
	var new_xp: int = maxi(0, xp + amount)
	var new_level := level_for_total_xp(new_xp)
	return {
		"level": new_level,
		"xp": new_xp,
		"leveled_up": new_level > level,
		"levels_gained": new_level - level,
	}


static func stats_for_level(char_class: String, level: int) -> Dictionary:
	_ensure_loaded()
	var growth: Dictionary = _growth_cache.get(char_class, _growth_cache.get("warrior", {}))
	var inc: int = clampi(level, 1, MAX_LEVEL) - 1
	# Loop over the stat set so adding a stat means editing the growth data only — not this.
	var out: Dictionary = {}
	for stat: String in _base_cache:
		out[stat] = int(_base_cache[stat]) + int(growth.get(stat, 0)) * inc
	return out
