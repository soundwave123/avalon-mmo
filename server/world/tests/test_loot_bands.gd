extends "res://addons/gut/test.gd"
# T-616: retrofit the SHIPPED 1-10 (Heartwold/Elmsvale) zone loot tables off the chance:1.0
# determinism trap and onto the adopted WoW bands (docs/design/spawn-loot-reference.md §3). The live
# kill path is loot_table.roll_weighted (tier-first, THEN per-item chance), so the bands are authored
# as per-item `chance` on the dominant common tier: a fixed-ratio-1 table is the weakest engagement
# schedule (kill #2 == kill #200), so at least one drop per farmable mob must be probabilistic. This
# is a DATA gate (value bands only — no loot schema/code change).

# The shipped 1-10 zone's NORMAL (non-elite) farmable mobs. Elites (greymaw/grexrok/elderthorn,
# difficulty 5) carry signature identity loot and are out of scope for this retrofit pass.
const ZONE_NORMAL_MOBS := ["wolf.json", "kobold_miner.json"]
# Coin-on-humanoid faucet targets. There is no `humanoid` flag on mob JSON yet, so the set is named
# explicitly (the Kobold Miner is the 1-10 zone's only normal humanoid).
const HUMANOID_MOBS := ["kobold_miner.json"]
# T-601/T-602 quest items whose (freshly re-sourced) drops stay at 1.0 for now — the explicit
# "known-authored, do not restack a probabilistic miss on a just-fixed source" allow-list.
const QUEST_ITEM_FLOOR_ALLOWLIST := ["itm_copper_ore", "itm_rugged_fiber"]
const BAND_MIN := 0.35  # anything below reads as a grind wall (spawn-loot-reference.md §3)


func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	assert_not_null(f, "missing data file %s" % path)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


func _loot(mob_file: String) -> Array:
	var data: Variant = _read_json("res://data/mobs/%s" % mob_file)
	if data is Dictionary:
		return (data as Dictionary).get("loot", [])
	return []


# Every collect-objective target across ALL quests — the reachability set the bands must not starve.
func _quest_collect_items() -> Dictionary:
	var out := {}
	var dir := DirAccess.open("res://data/quests")
	assert_not_null(dir, "quests dir opens")
	if dir == null:
		return out
	for name in dir.get_files():
		if not name.ends_with(".json"):
			continue
		var q: Variant = _read_json("res://data/quests/%s" % name)
		if not (q is Dictionary):
			continue
		for obj in (q as Dictionary).get("objectives", []):
			if obj is Dictionary and str(obj.get("type", "")) == "collect":
				out[str(obj.get("target", ""))] = true
	return out


func test_zone_normal_mobs_broke_the_determinism_trap() -> void:
	# At least one loot entry per farmable normal mob must be probabilistic (chance < 1.0) — the
	# variable-ratio "will this be the one" moment the chance:1.0 table killed.
	for mob_file in ZONE_NORMAL_MOBS:
		var loot := _loot(mob_file)
		assert_gt(loot.size(), 0, "%s has a loot table" % mob_file)
		var has_variance := false
		for entry in loot:
			if entry is Dictionary and float(entry.get("chance", 1.0)) < 1.0:
				has_variance = true
		assert_true(
			has_variance,
			"%s must have at least one sub-1.0 drop (no fixed-ratio-1 determinism trap)" % mob_file
		)


func test_zone_normal_loot_chances_sit_in_the_adopted_band() -> void:
	# Every drop is a real probability in (0, 1]; every sub-1.0 drop respects the band floor (0.35)
	# so nothing reads as a grind wall.
	for mob_file in ZONE_NORMAL_MOBS:
		for entry in _loot(mob_file):
			assert_true(entry is Dictionary, "%s loot entry is an object" % mob_file)
			var item := str((entry as Dictionary).get("item_id", ""))
			var chance := float((entry as Dictionary).get("chance", 1.0))
			assert_true(chance > 0.0 and chance <= 1.0, "%s: %s chance in (0,1]" % [mob_file, item])
			if chance < 1.0:
				assert_gte(
					chance, BAND_MIN, "%s: %s not below the grind-wall floor" % [mob_file, item]
				)


func test_quest_collect_items_stay_reachable() -> void:
	# A quest item must never become a rare drop: any zone-mob drop that a quest collects must stay
	# at/above the band floor. Protected (T-601/T-602) items may sit at 1.0 per the allow-list.
	var quest_items := _quest_collect_items()
	for mob_file in ZONE_NORMAL_MOBS:
		for entry in _loot(mob_file):
			if not (entry is Dictionary):
				continue
			var item := str(entry.get("item_id", ""))
			if not quest_items.has(item):
				continue
			var chance := float(entry.get("chance", 1.0))
			assert_gte(
				chance,
				BAND_MIN,
				"quest item %s on %s must stay reachable (>= %.2f)" % [item, mob_file, BAND_MIN]
			)


func test_humanoid_mobs_have_a_coin_faucet() -> void:
	# Coin only entered the game through quests (econ-11 faucet audit). Every normal humanoid now
	# rolls a sellable coin-proxy so trash-mobbing itself feeds the faucet.
	for mob_file in HUMANOID_MOBS:
		var has_coin := false
		for entry in _loot(mob_file):
			if entry is Dictionary and str(entry.get("item_id", "")).contains("coin"):
				has_coin = true
		assert_true(has_coin, "%s (humanoid) must roll a coin-proxy drop" % mob_file)
