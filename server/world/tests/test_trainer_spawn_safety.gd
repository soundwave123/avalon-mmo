extends "res://addons/gut/test.gd"
# T-585: hostile mobs must not be spawned on top of a trainer/service NPC (portal report #40 —
# two level-6 Kobold Miners spawned/patrolled within ~1.4-1.5m of Alchemist Vell, mauling a fresh
# level-1 player who walked up to learn a recipe — a safe-hub ambush). Mirrors test_spawn_safety.gd
# (T-515, which protects player spawn HUBS from dangerous mobs); this protects TRAINER/SERVICE NPCs
# instead, from ANY hostile mob regardless of level — a low-level pack camping a trainer is just as
# much a grief as a high-level one, and T-402's level-relative aggro means an under-leveled visitor
# actually sees an INFLATED effective aggro radius against a higher-level mob (floor/ceiling in
# mob_aggro.gd), so "low level" is no safety margin here.
#
# The keep-out distance is each mob's OWN leash_radius, not a flat guess: mob_aggro.gd clamps a
# mob's effective aggro reach to `minf(AGGRO_MAX, leash_radius)`, so leash_radius IS the mob's true
# worst-case reach from its spawn by construction. A trainer sitting at or beyond that distance can
# never be aggroed onto, no matter how under-leveled the visiting player is.


func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	assert_not_null(f, "missing data file %s" % path)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


# A mob is "hostile" for this check unless it's a pure training prop (dummy) or passive-until-
# attacked (retaliate_only — can't ambush a player who never swung first, e.g. the sparring effigy).
# Returns leash_radius (>= 0.0) when hostile, or -1.0 when the mob should be skipped.
func _hostile_leash_radius(mob_file: String) -> float:
	var data: Variant = _read_json("res://data/mobs/%s" % mob_file)
	if not (data is Dictionary):
		return -1.0
	var d: Dictionary = data
	if bool(d.get("dummy", false)) or bool(d.get("retaliate_only", false)):
		return -1.0
	return float(d.get("leash_radius", 15.0))


func _trainer_npcs() -> Array:
	var npc_doc: Variant = _read_json("res://data/npcs/npcs.json")
	assert_true(npc_doc is Dictionary, "npcs.json parses")
	var recipe_doc: Variant = _read_json("res://data/recipes/recipes.json")
	var trainer_ids := {}
	_collect_trainer_ids(recipe_doc, trainer_ids)

	var out: Array = []
	for npc: Dictionary in (npc_doc as Dictionary).get("npcs", []):
		var is_trainer := bool(npc.get("trainer", false))
		var has_service := str(npc.get("service", "")) != ""
		var teaches_recipes := trainer_ids.has(str(npc.get("id", "")))
		if is_trainer or has_service or teaches_recipes:
			out.append(npc)
	return out


# recipes.json is a flat/nested blob of recipe records, each optionally carrying a "trainer_id" —
# walk it generically rather than assume a fixed shape (content-lint style, not a strict schema).
func _collect_trainer_ids(node: Variant, out: Dictionary) -> void:
	if node is Dictionary:
		if node.has("trainer_id"):
			out[str(node["trainer_id"])] = true
		for v in (node as Dictionary).values():
			_collect_trainer_ids(v, out)
	elif node is Array:
		for v in node:
			_collect_trainer_ids(v, out)


func test_no_hostile_spawn_within_its_own_leash_of_a_trainer_or_service_npc() -> void:
	var trainers: Array = _trainer_npcs()
	assert_gt(trainers.size(), 0, "at least one trainer/service NPC is defined")
	var vell_present := false
	for n: Dictionary in trainers:
		if str(n.get("id", "")) == "npc_alchemist":
			vell_present = true
	assert_true(vell_present, "Alchemist Vell (npc_alchemist) must be recognized as a trainer NPC")

	var spawns_doc: Variant = _read_json("res://data/mobs/spawns.json")
	var spawns: Array = (spawns_doc as Dictionary).get("spawns", [])

	for entry: Dictionary in spawns:
		var mob_file := str(entry.get("mob_file", ""))
		var leash: float = _hostile_leash_radius(mob_file)
		if leash < 0.0:
			continue
		for pos in entry.get("positions", []):
			var p := Vector2(float(pos[0]), float(pos[1]))
			for n: Dictionary in trainers:
				var npc_pos := Vector2(float(n.get("x", 0.0)), float(n.get("y", 0.0)))
				var dist := p.distance_to(npc_pos)
				assert_true(
					dist >= leash,
					(
						(
							"%s spawn %s is %.1f m from trainer %s (need >= its own leash_radius "
							% [mob_file, p, dist, str(n.get("id", ""))]
						)
						+ "%.1f m; a fresh player at the trainer could be aggroed/ambushed)" % leash
					)
				)
