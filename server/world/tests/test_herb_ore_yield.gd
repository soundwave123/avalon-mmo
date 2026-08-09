extends GutTest

# T-677: herb/ore/timber gathering yields are variable-ratio, mirroring the shipped T-659 fishing
# loop (test_fishing_loop.gd). Every non-fishing node now carries a weighted bonus-yield `drops`
# table (mostly 1, sometimes 2-3 of the SAME base item — the guaranteed item is never displaced)
# plus an ADDITIVE `bonus_find` rare cross-find at honest low odds. Tests drive the real content
# data + the same server-side `_roll_node_yield` resolver, with rng injection for reproducibility.

const _CRAFT = preload("res://scripts/craft_service.gd")
const _CONTENT = preload("res://scripts/content/content_registry.gd")
const _CQ = preload("res://scripts/content/content_query.gd")
const _RARE_BAND := 0.05  # spawn-loot-reference.md "green" world-drop band ceiling (2-5%)

var _svc
var _loaded: Dictionary


func before_each() -> void:
	_svc = _CRAFT.new()
	_loaded = _CONTENT.load_all("res://data")
	assert_eq(str(_loaded["errors"]), "[]", "content loads clean")
	var err: String = _svc.setup(
		null,
		func(_pid: int, _msg: Dictionary) -> void: pass,
		"res://data",
		_CQ.item_registry(_loaded["items"]),
		_loaded["npcs"]
	)
	assert_eq(err, "", "craft service loads herb/ore content clean")


func _rng(seed_value: int = 677) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


# herb/ore/timber nodes — the surfaces this ticket retrofits (fishing is excluded, it keeps T-659).
func _gather_nodes() -> Array:
	var out: Array = []
	for node: Dictionary in _loaded.get("gather_nodes", {}).values():
		if str(node.get("kind", "")) in ["herb", "ore", "timber"]:
			out.append(node)
	return out


# Every collect-objective target item across the live quest data — the guardrail set.
func _quest_collect_targets() -> Dictionary:
	var targets: Dictionary = {}
	# Quests load as QuestDef objects (content_registry._quest), objectives are an Array of Dicts.
	for quest in _loaded.get("quests", {}).values():
		for objective: Dictionary in quest.objectives:
			if str(objective.get("type", "")) == "collect":
				targets[str(objective.get("target", ""))] = true
	return targets


func test_every_herb_ore_node_got_the_variable_ratio_retrofit() -> void:
	var nodes := _gather_nodes()
	assert_true(nodes.size() >= 20, "the herb/ore/timber pool is retrofitted, not just one node")
	for node: Dictionary in nodes:
		assert_true(node.has("drops"), "%s carries a weighted yield table" % node["id"])
		assert_true(node.has("bonus_find"), "%s carries a rare cross-find" % node["id"])


func test_bonus_yield_table_is_honest_and_never_displaces_the_base() -> void:
	for node: Dictionary in _gather_nodes():
		var base := str(node["item_id"])
		var drops: Array = node.get("drops", [])
		assert_true(
			drops.size() >= 2, "%s has a real amount-surprise, not a fixed count" % node["id"]
		)
		var total := 0.0
		for drop: Dictionary in drops:
			var chance := float(drop.get("chance", 0.0))
			total += chance
			assert_true(chance > 0.0 and chance < 1.0, "%s drop is an honest band" % node["id"])
			# The whole POINT of the guardrail: every primary entry is the SAME base item, so the
			# guaranteed drop is never displaced — only the amount varies.
			assert_eq(
				str(drop.get("item_id", "")),
				base,
				"%s primary never swaps the base item" % node["id"]
			)
		assert_almost_eq(total, 1.0, 0.0001, "%s primary chances total 1.0" % node["id"])


func test_rare_cross_find_is_honest_low_odds_never_a_hidden_certainty() -> void:
	for node: Dictionary in _gather_nodes():
		var bonus: Dictionary = node.get("bonus_find", {})
		assert_false(bonus.is_empty(), "%s has a rare cross-find" % node["id"])
		var chance := float(bonus.get("chance", 0.0))
		# The rare tier must be a real proc — never a chance:1.0 guaranteed drop in a rare costume.
		assert_true(chance > 0.0 and chance < 1.0, "%s rare find is honest odds < 1.0" % node["id"])
		assert_true(
			chance <= _RARE_BAND, "%s rare find sits in the green world-drop band" % node["id"]
		)
		var items := _CQ.item_registry(_loaded["items"])
		assert_true(
			items.has(str(bonus.get("item_id", ""))), "%s rare find item exists" % node["id"]
		)
		assert_true(
			str(items[str(bonus["item_id"])].get("rarity", "")) in ["uncommon", "rare"],
			"%s rare find is an uncommon/rare item, not a common staple" % node["id"]
		)


func test_observed_frequencies_track_the_published_odds() -> void:
	assert_true(_svc.has_method("_roll_node_yield"), "yield uses a server-side roll")
	# Pick a representative ore node and sample its rare-find + count distribution.
	var node: Dictionary = {}
	for n: Dictionary in _gather_nodes():
		if str(n.get("kind", "")) == "ore":
			node = n
			break
	assert_false(node.is_empty(), "an ore node exists to sample")
	var bonus: Dictionary = node["bonus_find"]
	var rng := _rng(101)
	var n_rolls := 40000
	var rare_hits := 0
	var count_two_or_three := 0
	for _i in range(n_rolls):
		var caught: Dictionary = _svc._roll_node_yield(node, rng)
		if caught.has("bonus"):
			rare_hits += 1
			assert_eq(
				str(caught["bonus"]["item_id"]),
				str(bonus["item_id"]),
				"the rare find is the authored item"
			)
		if int(caught["count"]) >= 2:
			count_two_or_three += 1
	var observed_rare := float(rare_hits) / float(n_rolls)
	assert_true(
		absf(observed_rare - float(bonus["chance"])) < 0.02,
		"rare find rate %.4f tracks published %.4f" % [observed_rare, float(bonus["chance"])]
	)
	var observed_bonus := float(count_two_or_three) / float(n_rolls)
	assert_true(
		absf(observed_bonus - 0.25) < 0.02,
		"bonus-yield (count>=2) rate %.4f tracks the published 0.25 band" % observed_bonus
	)


func test_yield_roll_is_rng_injected_and_reproducible() -> void:
	var node: Dictionary = _gather_nodes()[0]
	var seq_a: Array = []
	var seq_b: Array = []
	var rng_a := _rng(555)
	var rng_b := _rng(555)
	for _i in range(500):
		seq_a.append(_svc._roll_node_yield(node, rng_a))
		seq_b.append(_svc._roll_node_yield(node, rng_b))
	assert_eq(
		str(seq_a), str(seq_b), "same injected seed -> identical yields (server-authoritative)"
	)
	# A different seed must actually diverge — the roll is real, not a constant.
	var rng_c := _rng(999)
	var seq_c: Array = []
	for _i in range(500):
		seq_c.append(_svc._roll_node_yield(node, rng_c))
	assert_ne(str(seq_a), str(seq_c), "a different seed produces a different yield stream")


# The T-616 guardrail: any node a quest collect-objective depends on must yield its guaranteed base
# item on EVERY harvest — the procs are additive on top, they never displace the quest item.
func test_quest_item_gather_nodes_keep_their_guaranteed_item_every_harvest() -> void:
	var targets := _quest_collect_targets()
	assert_true(targets.size() > 0, "the live quest data has collect objectives to guard")
	var guarded := 0
	var rng := _rng(2222)
	for node: Dictionary in _gather_nodes():
		var base := str(node["item_id"])
		if not targets.has(base):
			continue
		guarded += 1
		for _i in range(3000):
			var caught: Dictionary = _svc._roll_node_yield(node, rng)
			assert_eq(str(caught["item_id"]), base, "%s always yields its quest item" % node["id"])
			assert_true(
				int(caught["count"]) >= 1, "%s yields at least the guaranteed one" % node["id"]
			)
	assert_true(guarded >= 3, "quest-critical herb/ore/timber nodes were actually exercised")
