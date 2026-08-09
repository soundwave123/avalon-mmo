extends RefCounted

const _QD = preload("res://scripts/content/quest_data.gd")
const _ID = preload("res://scripts/content/item_data.gd")
const _ND = preload("res://scripts/content/npc_data.gd")

const _QK := [
	"id",
	"title",
	"giver_npc",
	"turnin_npc",
	"min_level",
	"prerequisite_quest",
	"description",
	"turnin_text",  # T-713: the giver's spoken line on the turn-in card
	"objectives",
	"rewards",
	"provided_items",
	"repeatable",  # T-293: re-acceptable after completion (bounty loop)
	"bounty",  # T-293: surfaced on the bounty board's list
	"location_hint",  # T-293: display copy — where to hunt the target
	"recommended_players",  # T-293: suggested group size
	"retired",  # T-707: kept loadable for mid-quest characters, but never offered/accepted again
]
const _RARITIES := ["junk", "common", "uncommon", "rare", "epic", "legendary"]  # T-230
const _IK := [
	"id",
	"name",
	"rarity",
	"slot",
	"stackable",
	"max_stack",
	"stats",
	"vendor_value",
	"description",
	"armor_type",
	"use_effect",
	"item_level",  # T-681: authored power budget (ledger dimension)
	"required_level",  # T-681: the equip/use gate
]
const _NK := [
	"id",
	"name",
	"x",
	"y",
	"gives_quests",
	"talk_text",
	"trainer",
	"service",
	"wares",
	"wander",
	"idle",
	"appearance"
]
const _OK := ["type", "target", "count", "desc"]
const _RK := ["type", "target", "count", "desc", "x", "y", "radius"]
const _REWK := ["xp", "coins", "items"]
const _RITEMK := ["item", "count"]
# T-426: equip + use_ability are the tutorial "learn as you play" verbs; interrupt is the tactical
# verb (breaking a mob's telegraphed channel — slice 4's teaching encounter).
const _OTYPES := ["kill", "collect", "talk", "reach", "equip", "use_ability", "interrupt"]
const _SLOTS := ["none", "head", "chest", "legs", "weapon", "offhand", "shoulders"]  # T-420

# T-064: talent validation vocab.
const _TALENT_CLASSES := ["warrior", "mage", "priest"]
const _TALENT_EFFECT_KINDS := ["stat_add", "ability_damage_pct", "ability_cost_pct"]
const _TALENT_STATS := ["str", "int", "dex", "spirit", "stamina"]


static func load_all(base_path: String) -> Dictionary:
	var out := {
		"quests": {},
		"items": {},
		"npcs": {},
		"mobs": {},
		"talents": {},
		"gather_nodes": {},
		"errors": []
	}
	_load_quests(base_path.path_join("quests"), out["quests"], out["errors"])
	_load_array_file(
		base_path.path_join("items").path_join("items.json"),
		"items",
		out["items"],
		out["errors"],
		"item"
	)
	_load_array_file(
		base_path.path_join("npcs").path_join("npcs.json"),
		"npcs",
		out["npcs"],
		out["errors"],
		"npc"
	)
	# T-073: spawned-mob defs (only mobs reachable via spawns.json count as killable).
	_load_spawned_mobs(base_path.path_join("mobs"), out["mobs"], out["errors"])
	# T-335: instance-scoped spawns (e.g. data/instances/hollowed_crypt.json, seeded live by
	# instance_service.gd on a party's descent) are equally "killable" for quest kill-target
	# validation — they just aren't open-world spawns.json entries.
	_load_instance_mobs(
		base_path.path_join("instances"), base_path.path_join("mobs"), out["mobs"], out["errors"]
	)
	# T-064: talent trees (per-class JSON) + the ability ids they may reference.
	_load_talents(base_path.path_join("talents"), out["talents"], out["errors"])
	# T-601/T-602: gather nodes are a legitimate collect-objective source alongside mob loot —
	# loaded here so validate_sources can see them (previously only mob loot/provided_items
	# counted, which let quest targets silently drift onto the wrong item tier — see nodes.json).
	_load_gather_nodes(base_path.path_join("gather").path_join("nodes.json"), out["gather_nodes"])
	out["errors"].append_array(validate(out["quests"], out["items"], out["npcs"]))
	out["errors"].append_array(
		validate_sources(out["quests"], out["mobs"], out["items"], out["gather_nodes"])
	)
	out["errors"].append_array(
		validate_talents(out["talents"], _ability_ids(base_path.path_join("abilities")))
	)
	return out


# T-073: cross-check quest objectives against actual runtime sources. Every kill target must
# be a SPAWNED mob and every collect target must have a producer (a mob loot table or a gather
# node) — quests naming ghosts used to lint clean and ship uncompletable (q001/q002/q004/q005).
# T-601/T-602: gather_nodes defaults to {} so existing direct callers (test_content_registry.gd)
# keep compiling; load_all always passes the real loaded set.
static func validate_sources(
	quests: Dictionary, mobs: Dictionary, items: Dictionary, gather_nodes: Dictionary = {}
) -> Array:
	var errors: Array = []
	var producible := {}
	# T-058: quest-provided items are legitimate collect sources (delivery-quest pattern).
	for key in quests:
		for entry in _arr(_val(quests[key], "provided_items", [])):
			if entry is Dictionary:
				var pid := str(entry.get("item", ""))
				producible[pid] = true
				if not items.is_empty() and not items.has(pid):
					errors.append("quest %s provides unknown item: %s" % [key, pid])
	for mob_id in mobs:
		for entry in _arr(mobs[mob_id].get("loot", [])):
			if entry is Dictionary:
				var item_id := str(entry.get("item_id", ""))
				producible[item_id] = true
				if not items.is_empty() and not items.has(item_id):
					errors.append("mob %s loot names unknown item: %s" % [mob_id, item_id])
	# T-601/T-602: gather nodes are an equally real collect-objective source (the herb/ore/timber
	# yields any player can walk up and harvest, no combat required).
	for node_id in gather_nodes:
		var node_item := str(gather_nodes[node_id].get("item_id", ""))
		producible[node_item] = true
		if not items.is_empty() and not items.has(node_item):
			errors.append("gather node %s yields unknown item: %s" % [node_id, node_item])
	for key in quests:
		for objective in _arr(_val(quests[key], "objectives", [])):
			var type := str(_val(objective, "type", ""))
			var target := str(_val(objective, "target", ""))
			if type == "kill" and not mobs.has(target):
				errors.append("quest %s kill target has no spawned mob: %s" % [key, target])
			elif type == "interrupt" and target != "*" and not mobs.has(target):
				# T-426: interrupt target names the mob whose telegraphed channel is broken (a real
				# spawned mob, like kill); "*" is the tutorial wildcard (interrupt any channel).
				errors.append("quest %s interrupt target has no spawned mob: %s" % [key, target])
			elif type == "collect" and not producible.has(target):
				errors.append(
					"quest %s collect target has no producer (no mob loots it): %s" % [key, target]
				)
	return errors


# T-073: read spawns.json + the mob JSONs it references; key defs by mob_id. A def on disk
# that no spawn entry references is NOT killable and stays out of the returned dict.
static func _load_spawned_mobs(dir_path: String, mobs: Dictionary, errors: Array) -> void:
	var parsed = _parse(dir_path.path_join("spawns.json"), errors)
	if not (parsed is Dictionary) or not (parsed.get("spawns", null) is Array):
		errors.append("mobs spawns.json missing or malformed: %s" % dir_path)
		return
	for entry in parsed["spawns"]:
		if not (entry is Dictionary):
			errors.append("spawn entry must be an object")
			continue
		var mob_file := str(entry.get("mob_file", ""))
		var mob_def = _parse(dir_path.path_join(mob_file), errors)
		if not (mob_def is Dictionary):
			continue
		var mob_id := str(mob_def.get("mob_id", ""))
		if mob_id == "":
			errors.append("mob file missing mob_id: %s" % mob_file)
			continue
		mobs[mob_id] = mob_def


# T-335: mirror _load_spawned_mobs for instance spawn files (data/instances/*.json), whose
# {"spawns":[{"mob_file":...}]} shape matches spawns.json's per-entry mob_file field —
# instance_service.gd seeds these live on a party's descent, so their mobs are real kill
# targets even though content_registry's normal reachability scan (spawns.json) never sees them.
static func _load_instance_mobs(
	dir_path: String, mob_dir_path: String, mobs: Dictionary, errors: Array
) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return  # not every world ships an instances dir
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			var parsed = _parse(dir_path.path_join(fname), errors)
			if parsed is Dictionary and parsed.get("spawns", null) is Array:
				for entry in parsed["spawns"]:
					if not (entry is Dictionary):
						continue
					var mob_file := str(entry.get("mob_file", ""))
					var mob_def = _parse(mob_dir_path.path_join(mob_file), errors)
					if mob_def is Dictionary:
						var mob_id := str(mob_def.get("mob_id", ""))
						if mob_id != "":
							mobs[mob_id] = mob_def
		fname = dir.get_next()
	dir.list_dir_end()


# T-601/T-602: read gather/nodes.json (kept lenient here — craft_service.gd owns the strict
# kind/item validation at boot; this loader only needs id -> {item_id,...} for source-reachability
# cross-checks in validate_sources). Missing/malformed file is a silent no-op (nodes are optional
# content, same posture as _load_instance_mobs for an optional dir).
static func _load_gather_nodes(path: String, nodes: Dictionary) -> void:
	var parsed = _parse(path, [])
	if not (parsed is Dictionary) or not (parsed.get("nodes", null) is Array):
		return
	for entry in parsed["nodes"]:
		if entry is Dictionary:
			var node_id := str(entry.get("id", ""))
			if node_id != "":
				nodes[node_id] = entry


# T-064: talents are content — same fail-loud pipeline as quests. defs keyed by id.
static func _load_talents(dir_path: String, talents: Dictionary, errors: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		errors.append("cannot open talents dir: %s" % dir_path)
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			var parsed = _parse(dir_path.path_join(fname), errors)
			if parsed is Dictionary and parsed.get("talents", null) is Array:
				for raw in parsed["talents"]:
					if raw is Dictionary:
						_store("talent", talents, str(raw.get("id", "")), raw, errors)
					else:
						errors.append("talent entry must be an object: %s" % fname)
			elif parsed != null:
				errors.append("talent file missing talents array: %s" % fname)
		fname = dir.get_next()
	dir.list_dir_end()


# T-064: structural + referential talent validation (fail-loud at boot, tested in lint).
static func validate_talents(talents: Dictionary, ability_ids: Dictionary) -> Array:
	var errors: Array = []
	for id in talents:
		var tal: Dictionary = talents[id]
		if not _TALENT_CLASSES.has(str(tal.get("class", ""))):
			errors.append("talent %s has unknown class: %s" % [id, tal.get("class", "")])
		if str(tal.get("tree", "")) == "":
			errors.append("talent %s missing tree" % id)
		if int(tal.get("tier", 0)) < 1:
			errors.append("talent %s tier must be >= 1" % id)
		if int(tal.get("max_ranks", 0)) < 1:
			errors.append("talent %s max_ranks must be >= 1" % id)
		var prereq = tal.get("prereq")
		if prereq != null and str(prereq) != "":
			var pre: Dictionary = talents.get(str(prereq), {})
			if pre.is_empty():
				errors.append("talent %s prereq does not exist: %s" % [id, prereq])
			elif str(pre.get("tree", "")) != str(tal.get("tree", "")):
				errors.append("talent %s prereq must be in the same tree" % id)
		var effect: Dictionary = tal.get("effect", {}) if tal.get("effect") is Dictionary else {}
		var kind := str(effect.get("kind", ""))
		if not _TALENT_EFFECT_KINDS.has(kind):
			errors.append("talent %s has unknown effect kind: %s" % [id, kind])
		elif kind == "stat_add" and not _TALENT_STATS.has(str(effect.get("stat", ""))):
			errors.append(
				"talent %s stat_add names unknown stat: %s" % [id, effect.get("stat", "")]
			)
		elif kind != "stat_add":
			var aid: int = int(effect.get("ability_id", -1))
			if aid != 0 and not ability_ids.has(aid):
				errors.append("talent %s references unknown ability id: %d" % [id, aid])
	return errors


# T-064: the set of ability ids on disk ({id: true}) for talent reference validation.
static func _ability_ids(dir_path: String) -> Dictionary:
	var ids: Dictionary = {}
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return ids
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			var parsed = _parse(dir_path.path_join(fname), [])
			if parsed is Dictionary and parsed.has("id"):
				ids[int(parsed["id"])] = true
		fname = dir.get_next()
	dir.list_dir_end()
	return ids


static func validate(quests: Dictionary, items: Dictionary, npcs: Dictionary) -> Array:
	var errors: Array = []
	_duplicates("quest", quests, errors)
	_duplicates("item", items, errors)
	_duplicates("npc", npcs, errors)
	for key in quests:
		_validate_quest(key, quests[key], quests, items, npcs, errors)
	for key in items:
		_validate_item(key, items[key], errors)
	for key in npcs:
		_validate_npc(key, npcs[key], quests, items, errors)
	return errors


static func _load_quests(dir_path: String, quests: Dictionary, errors: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		errors.append("cannot open quests dir: %s" % dir_path)
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			var parsed = _parse(dir_path.path_join(fname), errors)
			if parsed is Dictionary:
				var quest = _quest(parsed)
				_store("quest", quests, quest.id, quest, errors)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_array_file(path, array_key, dest, errors, kind) -> void:
	var parsed = _parse(path, errors)
	if not (parsed is Dictionary):
		return
	_unknown("%s file" % array_key, parsed.keys(), [array_key], errors)
	if not (parsed.get(array_key) is Array):
		errors.append("%s file missing %s array: %s" % [array_key, array_key, path])
		return
	for raw in parsed.get(array_key, []):
		if not (raw is Dictionary):
			errors.append("%s entry must be an object: %s" % [kind, path])
			continue
		var entry = _item(raw) if kind == "item" else _npc(raw)
		_store(kind, dest, entry.id, entry, errors)


static func _parse(path: String, errors: Array):
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		errors.append("failed to open content file: %s" % path)
		return null
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null:
		errors.append("failed to parse content file: %s" % path)
	return parsed


static func _quest(data: Dictionary):
	var quest = _QD.new()
	quest._source_keys = data.keys()
	quest.id = str(data.get("id", ""))
	quest.title = str(data.get("title", ""))
	quest.giver_npc = str(data.get("giver_npc", ""))
	quest.turnin_npc = str(data.get("turnin_npc", quest.giver_npc))
	quest.min_level = int(data.get("min_level", 1))
	var prereq = data.get("prerequisite_quest", null)
	quest.prerequisite_quest = "" if prereq == null else str(prereq)
	quest.description = str(data.get("description", ""))
	quest.turnin_text = str(data.get("turnin_text", ""))  # T-713
	for raw in data.get("objectives", []):
		if raw is Dictionary:
			quest.objectives.append(_objective(raw))
	quest.rewards = _rewards(data.get("rewards", {}))
	quest.provided_items = (
		data.get("provided_items", []) if data.get("provided_items", []) is Array else []
	)
	quest.repeatable = bool(data.get("repeatable", false))  # T-293
	quest.bounty = bool(data.get("bounty", false))  # T-293
	quest.location_hint = str(data.get("location_hint", ""))  # T-293
	quest.recommended_players = int(data.get("recommended_players", 1))  # T-293
	quest.retired = bool(data.get("retired", false))  # T-707
	return quest


static func _item(data: Dictionary):
	var item = _ID.new()
	item._source_keys = data.keys()
	item.id = str(data.get("id", ""))
	item.name = str(data.get("name", ""))
	item.rarity = str(data.get("rarity", "common"))  # T-230: WoW color-language tier
	item.slot = str(data.get("slot", ""))
	item.armor_type = str(data.get("armor_type", "none"))  # T-063
	item.stackable = bool(data.get("stackable", false))
	item.max_stack = int(data.get("max_stack", 1))
	item.stats = data.get("stats", {}) if data.get("stats", {}) is Dictionary else {}
	item.vendor_value = int(data.get("vendor_value", 0))
	item.description = str(data.get("description", ""))
	item.use_effect = data.get("use_effect", {}) if data.get("use_effect", {}) is Dictionary else {}
	# T-681: absent = 1 (ungated), the back-compat default the equip/use gate fails open on.
	item.item_level = maxi(1, int(data.get("item_level", 1)))
	item.required_level = maxi(1, int(data.get("required_level", 1)))
	return item


static func _npc(data: Dictionary):
	var npc = _ND.new()
	npc._source_keys = data.keys()
	npc.id = str(data.get("id", ""))
	npc.name = str(data.get("name", ""))
	npc.x = float(data.get("x", 0.0))
	npc.y = float(data.get("y", 0.0))
	npc.gives_quests = data.get("gives_quests", []) if data.get("gives_quests", []) is Array else []
	npc.talk_text = str(data.get("talk_text", ""))
	npc.trainer = bool(data.get("trainer", false))  # T-065
	npc.service = str(data.get("service", ""))  # T-145: service-hub tag (bank|vendor|inn|flight)
	npc.wares = data.get("wares", []) if data.get("wares", []) is Array else []  # T-430
	npc.wander = data.get("wander", {}) if data.get("wander", {}) is Dictionary else {}  # T-311
	npc.idle = data.get("idle", {}) if data.get("idle", {}) is Dictionary else {}  # T-446
	# T-302: optional look block → client rig + tint
	npc.appearance = data.get("appearance", {}) if data.get("appearance", {}) is Dictionary else {}
	return npc


static func _objective(data: Dictionary) -> Dictionary:
	var objective := {
		"type": str(data.get("type", "")),
		"target": str(data.get("target", "")),
		"count": int(data.get("count", 0)),
		"desc": str(data.get("desc", "")),
		"_source_keys": data.keys(),
	}
	for key in ["x", "y", "radius"]:
		if data.has(key):
			objective[key] = float(data.get(key, 0.0))
	return objective


static func _rewards(data) -> Dictionary:
	var rewards := {"xp": 0, "coins": 0, "items": [], "_source_keys": []}
	if not (data is Dictionary):
		return rewards
	rewards["xp"] = int(data.get("xp", 0))
	rewards["coins"] = int(data.get("coins", 0))
	rewards["_source_keys"] = data.keys()
	for raw in data.get("items", []):
		if raw is Dictionary:
			(
				rewards["items"]
				. append(
					{
						"item": str(raw.get("item", "")),
						"count": int(raw.get("count", 0)),
						"_source_keys": raw.keys(),
					}
				)
			)
	return rewards


static func _store(kind, registry, id, entry, errors) -> void:
	if registry.has(id):
		errors.append("duplicate %s id: %s" % [kind, id])
	registry[id] = entry


static func _duplicates(kind, entries, errors) -> void:
	var seen := {}
	for key in entries:
		var id := str(_val(entries[key], "id", key))
		if seen.has(id):
			errors.append("duplicate %s id: %s" % [kind, id])
		seen[id] = true


static func _validate_quest(key, quest, quests, items, npcs, errors) -> void:
	var id := str(_val(quest, "id", key))
	_unknown("quest %s" % id, _keys(quest), _QK, errors)
	_ref(npcs, _val(quest, "giver_npc", ""), "quest %s missing giver_npc" % id, errors)
	_ref(
		npcs,
		_val(quest, "turnin_npc", _val(quest, "giver_npc", "")),
		"quest %s missing turnin_npc" % id,
		errors
	)
	var prereq := str(_val(quest, "prerequisite_quest", ""))
	if prereq == id:
		errors.append("quest %s has self-referential prerequisite_quest" % id)
	elif prereq != "" and not quests.has(prereq):
		errors.append("quest %s references missing prerequisite_quest: %s" % [id, prereq])
	var objectives: Array = _arr(_val(quest, "objectives", []))
	if objectives.is_empty():
		errors.append("quest %s objectives must be non-empty" % id)
	for objective in objectives:
		_validate_objective(id, objective, items, npcs, errors)
	var rewards = _val(quest, "rewards", {})
	if not (rewards is Dictionary):
		errors.append("quest %s rewards must be an object" % id)
		return
	_unknown("quest %s rewards" % id, _keys(rewards), _REWK, errors)
	if int(rewards.get("xp", 0)) < 0:
		errors.append("quest %s reward xp must be >= 0" % id)
	if int(rewards.get("coins", 0)) < 0:
		errors.append("quest %s reward coins must be >= 0" % id)
	for item in _arr(rewards.get("items", [])):
		_unknown("quest %s reward item" % id, _keys(item), _RITEMK, errors)
		_ref(items, _val(item, "item", ""), "quest %s missing reward item" % id, errors)
		if int(_val(item, "count", 0)) < 1:
			errors.append(
				"quest %s reward item count must be >= 1: %s" % [id, _val(item, "item", "")]
			)


static func _validate_objective(id, objective, items, npcs, errors) -> void:
	var type := str(_val(objective, "type", ""))
	_unknown(
		"quest %s objective %s" % [id, type],
		_keys(objective),
		_RK if type == "reach" else _OK,
		errors
	)
	if not _OTYPES.has(type):
		errors.append("quest %s objective has unknown type: %s" % [id, type])
	if int(_val(objective, "count", 0)) < 1:
		errors.append("quest %s objective count must be >= 1: %s" % [id, type])
	var target := str(_val(objective, "target", ""))
	if type == "collect":
		_ref(items, target, "quest %s objective missing item" % id, errors)
	elif type == "equip":  # T-426: target is an item the player equips (must be a real item)
		_ref(items, target, "quest %s equip objective missing item" % id, errors)
	elif type == "talk":
		_ref(npcs, target, "quest %s objective missing npc" % id, errors)
	elif type == "kill":
		# mob kill target resolution deferred to T-034
		pass
	elif type == "interrupt":
		# T-426: target is a mob alias (or "*"); resolved against spawned mobs in validate_sources,
		# mirroring the kill-target deferral here.
		pass
	elif type == "use_ability":
		# T-426: target is an ability icon slug; abilities aren't loaded in this registry, so
		# the slug is not cross-checked here (mirrors kill/reach target deferral).
		pass
	elif type == "reach":
		# reach location ids are not registered; deferred
		for key in ["x", "y", "radius"]:
			if not _has(objective, key):
				errors.append(
					"quest %s reach objective missing %s for target: %s" % [id, key, target]
				)


static func _validate_item(key, item, errors) -> void:
	var id := str(_val(item, "id", key))
	_unknown("item %s" % id, _keys(item), _IK, errors)
	if not _RARITIES.has(str(_val(item, "rarity", "common"))):
		errors.append("item %s has invalid rarity: %s" % [id, _val(item, "rarity", "")])
	if not _SLOTS.has(str(_val(item, "slot", ""))):
		errors.append("item %s has invalid slot: %s" % [id, _val(item, "slot", "")])
	if int(_val(item, "max_stack", 1)) < 1:
		errors.append("item %s max_stack must be >= 1" % id)
	if not bool(_val(item, "stackable", false)) and int(_val(item, "max_stack", 1)) > 1:
		errors.append("item %s max_stack must be 1 when stackable is false" % id)
	if int(_val(item, "vendor_value", 0)) < 0:
		errors.append("item %s vendor_value must be >= 0" % id)
	# T-681: the gear-ladder invariant, enforced at content load so a bad hand-edit never boots.
	# Absent fields default to 1/1 (ungated), so this only ever bites authored values.
	var item_level := int(_val(item, "item_level", 1))
	var required_level := int(_val(item, "required_level", 1))
	if item_level < 1:
		errors.append("item %s item_level must be >= 1" % id)
	if required_level < 1:
		errors.append("item %s required_level must be >= 1" % id)
	if required_level > item_level:
		errors.append(
			"item %s required_level %d exceeds item_level %d" % [id, required_level, item_level]
		)
	if str(_val(item, "slot", "none")) != "none" and not _has(item, "item_level"):
		errors.append("item %s is equippable but carries no item_level (T-681)" % id)


static func _validate_npc(key, npc, quests, items, errors) -> void:
	var id := str(_val(npc, "id", key))
	_unknown("npc %s" % id, _keys(npc), _NK, errors)
	for quest_id in _arr(_val(npc, "gives_quests", [])):
		_ref(quests, str(quest_id), "npc %s missing gives_quests entry" % id, errors)
	var wares := _arr(_val(npc, "wares", []))
	if not wares.is_empty() and str(_val(npc, "service", "")) != "vendor":
		errors.append("npc %s has wares but is not a vendor" % id)
	for item_id in wares:
		_ref(items, str(item_id), "npc %s missing ware item" % id, errors)


static func _ref(registry, id, label, errors) -> void:
	if not registry.has(str(id)):
		errors.append("%s: %s" % [label, str(id)])


static func _unknown(context, keys, allowed, errors) -> void:
	for key in keys:
		var key_str := str(key)
		if not key_str.begins_with("_") and not allowed.has(key_str):
			errors.append("%s unknown key: %s" % [context, key_str])


static func _val(entry, key: String, default_value):
	if entry is Dictionary:
		return entry.get(key, default_value)
	if entry == null:
		return default_value
	var value = entry.get(key)
	return default_value if value == null else value


static func _has(entry, key: String) -> bool:
	return entry.has(key) if entry is Dictionary else entry != null and entry.get(key) != null


static func _keys(entry) -> Array:
	if entry is Dictionary:
		return _arr(entry.get("_source_keys", entry.keys()))
	return [] if entry == null else _arr(entry.get("_source_keys"))


static func _arr(value) -> Array:
	return value if value is Array else []
