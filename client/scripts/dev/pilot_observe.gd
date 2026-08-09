class_name PilotObserve
# T-562: the SEMANTIC read layer for an autonomous LLM play-agent. The raw pilot ops speak in
# keycodes and node paths; a play-agent needs to reason over MEANING. `gather()` reads the live
# client (reusing the same internals the HUD/nameplate/positions plumbing already exposes) and
# `build()` normalizes those pieces into ONE stable JSON snapshot the agent skill reasons over.
#
# Split on purpose:
#   build(raw, prev)  — PURE. Shape + hp_delta + nearby-sort + log-tail. No Node/scene state, so it
#                       is unit-tested headlessly off a mock game-state (test_pilot_observe.gd).
#   gather(main, prev) — LIVE. Pulls raw pieces from the running client, then calls build(). This is
#                       the wiring verified by an orchestrator pilot run after merge.
#
# T-566: `inventory` now reflects the ACTUAL bag/equip contents whether or not the inventory panel
# has ever been opened — _live_inventory() forces a fresh get_inventory() request on every gather()
# instead of relying on the panel's I-keypress-only fetch (see _live_inventory()'s comment).
#
# Snapshot schema (documented in docs/tickets/zone/T-562.md — the contract the skill depends on):
#   { player: {hp, max_hp, mana, max_mana, resource_kind, class, level, alive, position:{x,z},
#              hp_delta},
#     active_quest: {name, objectives:[{text, done}]} | {},
#     inventory: [{name, count}],
#     nearby: [{name, kind:"npc"|"mob"|"player", distance, hostile}]  (sorted nearest-first),
#     recent_log: [str, ...]  (last ~8 combat/system lines),
#     ui_panel: "none"|"class"|"talents"|"quest_log"|"inventory"|"character_sheet"|"pvp" }

extends RefCounted

const LOG_TAIL := 8  # recent_log keeps the last N lines (a play-agent only needs the tail)

# main-field name of each major panel, in the order ui_panel reports the first open one.
const _PANELS := [
	["class", "class_panel"],
	["talents", "talent_panel"],
	["quest_log", "quest_log_panel"],
	["inventory", "inventory_panel"],
	["character_sheet", "character_sheet_panel"],
	["pvp", "pvp_panel"],
]

# ---- PURE serializer (unit-tested) --------------------------------------------------------------


# Normalize the raw gathered pieces into the stable snapshot. `prev` is the previous observe result
# (or {}) and is read ONLY to compute the player's hp_delta ("my HP is dropping").
static func build(raw: Dictionary, prev: Dictionary) -> Dictionary:
	return {
		"player": _norm_player(raw.get("player", {}), prev),
		"active_quest": _norm_quest(raw.get("active_quest", {})),
		"inventory": _norm_inventory(raw.get("inventory", [])),
		"nearby": _norm_nearby(raw.get("nearby", [])),
		"recent_log": _tail_log(raw.get("recent_log", [])),
		"ui_panel": str(raw.get("ui_panel", "none")),
		# T-721: the ability-press ledger (counts + recent events) — a combat QA agent can now SEE
		# every press verdict (sent/blocked/result/rejected:<reason>) instead of inferring from logs.
		"ability": raw.get("ability", {}) if raw.get("ability") is Dictionary else {},
		# T-734: the synced day clock ({day_t, day_frozen}) — the two-client E2E's tolerance oracle.
		"world": raw.get("world", {}) if raw.get("world") is Dictionary else {},
		# T-730/T-738: {world_map:{open,zone,marker_kinds,marker_names}, minimap:{visible,rotate,
		# zoom,counts}} — visual QA asserts marker presence here, never from a screenshot (T-559).
		"map": raw.get("map", {}) if raw.get("map") is Dictionary else {},
	}


static func _norm_player(p: Dictionary, prev: Dictionary) -> Dictionary:
	var hp := int(p.get("hp", 0))
	var prev_player: Dictionary = prev.get("player", {}) if prev.get("player") is Dictionary else {}
	var hp_delta := (hp - int(prev_player.get("hp", hp))) if prev_player.has("hp") else 0
	var pos: Dictionary = p.get("position", {}) if p.get("position") is Dictionary else {}
	return {
		"hp": hp,
		"max_hp": int(p.get("max_hp", 0)),
		"mana": int(p.get("mana", 0)),
		"max_mana": int(p.get("max_mana", 0)),
		"resource_kind": str(p.get("resource_kind", "none")),
		"class": str(p.get("class", "")),
		"level": int(p.get("level", 0)),
		"alive": bool(p.get("alive", hp > 0)),
		"position":
		{
			"x": snappedf(float(pos.get("x", 0.0)), 0.1),
			"z": snappedf(float(pos.get("z", 0.0)), 0.1)
		},
		"hp_delta": hp_delta,
	}


static func _norm_quest(q: Dictionary) -> Dictionary:
	if q.is_empty():
		return {}
	var objectives: Array = []
	for o in q.get("objectives", []):
		if o is Dictionary:
			objectives.append({"text": str(o.get("text", "")), "done": bool(o.get("done", false))})
	return {"name": str(q.get("name", "")), "objectives": objectives}


static func _norm_inventory(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array:
		for it in raw:
			if it is Dictionary and str(it.get("name", "")) != "":
				out.append({"name": str(it.get("name", "")), "count": int(it.get("count", 1))})
	return out


static func _norm_nearby(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array:
		for e in raw:
			if e is Dictionary:
				(
					out
					. append(
						{
							"name": str(e.get("name", "")),
							"kind": str(e.get("kind", "")),
							"distance": snappedf(float(e.get("distance", 0.0)), 0.1),
							"hostile": bool(e.get("hostile", false)),
						}
					)
				)
	out.sort_custom(func(a, b): return float(a["distance"]) < float(b["distance"]))
	return out


static func _tail_log(raw: Variant) -> Array:
	var lines: Array = []
	if raw is Array:
		for line in raw:
			lines.append(str(line))
	return lines.slice(maxi(0, lines.size() - LOG_TAIL))


# ---- LIVE gather (orchestrator-pilot-verified after merge) --------------------------------------


static func gather(main: Node, prev: Dictionary) -> Dictionary:
	return build(
		{
			"player": _live_player(main),
			"active_quest": _live_quest(main),
			"inventory": _live_inventory(main),
			"nearby": _live_nearby(main),
			"recent_log": _live_log(main),
			"ui_panel": _live_ui_panel(main),
			"ability": _live_ability(main),
			"world": _live_world(main),
			"map": _live_map(main),
		},
		prev
	)


# T-730/T-738: both map surfaces expose observe() (mounted panels, so they live under HUD by name
# rather than as main fields — the pilot.gd _dump_state mounted-panel idiom).
static func _live_map(main: Node) -> Dictionary:
	var out := {}
	var hud = main.get_node_or_null("HUD")
	if hud == null:
		return out
	var world_map = hud.get_node_or_null("WorldMapPanel")
	if world_map != null and world_map.has_method("observe"):
		out["world_map"] = world_map.observe()
	var minimap = hud.get_node_or_null("MinimapPanel")
	if minimap != null and minimap.has_method("observe"):
		out["minimap"] = minimap.observe()
	return out


# T-734: the synced world day clock — the E2E oracle for "both clients share one time of day"
# (and a QA read: day_frozen shows whether AVALON_FREEZE_DAY is pinning this client).
static func _live_world(main: Node) -> Dictionary:
	var wv = main.get("world_view")
	if wv == null:
		return {}
	return {
		"day_t": snappedf(float(wv.get("_day_t")), 0.0001),
		"day_frozen": bool(wv.get("_day_frozen")),
	}


# T-721: the AbilityCastQueue ledger — whole-session press/verdict counters + recent events.
static func _live_ability(main: Node) -> Dictionary:
	var q = main.get("_cast_queue")
	return q.summary() if q != null else {}


# Own vitals from the last positions broadcast entry (the same authoritative source the HUD reads)
# and player_stats from character_sheet_panel (where level and max_mana come from server authority);
# position from the live LocalPlayer node so it tracks between broadcasts.
# T-581: prefer character_sheet_panel's _last player_stats for level and derived.max_mana, falling
# back to entry values (from positions broadcast) when stats haven't arrived yet (headless/early).
static func _live_player(main: Node) -> Dictionary:
	var my_id := int(main.get("_my_peer_id"))
	var entry: Dictionary = {}
	var lp = main.get("last_positions")
	if lp is Dictionary:
		for p in (lp as Dictionary).get("players", []):
			if p is Dictionary and int(p.get("peer_id", -1)) == my_id:
				entry = p
				break
	var node = main.get("local_player")
	var pos := {"x": float(entry.get("x", 0.0)), "z": float(entry.get("z", 0.0))}
	if node is Node3D:
		pos = {"x": (node as Node3D).global_position.x, "z": (node as Node3D).global_position.z}

	# Prefer authoritative level and max_mana from character_sheet_panel's last player_stats.
	var level := int(entry.get("level", 0))
	var max_mana := int(entry.get("max_resource", 0))
	var panel = main.get("character_sheet_panel")
	if panel != null and panel.has_method("get_last"):
		var stats: Dictionary = panel.get_last()
		if stats is Dictionary and not stats.is_empty():
			level = int(stats.get("level", level))
			var derived: Dictionary = stats.get("derived", {})
			if derived is Dictionary:
				max_mana = int(derived.get("max_mana", max_mana))

	return {
		"hp": int(entry.get("hp", 0)),
		"max_hp": int(entry.get("max_hp", 0)),
		"mana": int(entry.get("resource", 0)),
		"max_mana": max_mana,
		"resource_kind": str(entry.get("resource_kind", "none")),
		"class": str(entry.get("char_class", "")),
		"level": level,
		"alive": int(entry.get("hp", 0)) > 0,
		"position": pos,
	}


# First ACTIVE quest from the quest-log view-model; current/required -> a per-objective done flag.
static func _live_quest(main: Node) -> Dictionary:
	var panel = main.get("quest_log_panel")
	var quests = panel.get("_quests") if panel != null else null
	if not (quests is Array):
		return {}
	for q in quests:
		if q is Dictionary and str(q.get("state", "")) == "active":
			var objs: Array = []
			for o in q.get("objectives", []):
				if o is Dictionary:
					var req := int(o.get("required", 0))
					var cur := int(o.get("current", 0))
					objs.append({"text": str(o.get("desc", "")), "done": req > 0 and cur >= req})
			return {"name": str(q.get("title", "")), "objectives": objs}
	return {}


# Compact bag/equipped summary from the inventory panel's live cells (each ItemCell holds an entry).
# T-566: the server only PUSHES inventory truth when the client explicitly asks — main.gd's KEY_I
# handler calls ClientNet.get_inventory() ONLY when the player opens the panel, and item grants
# (e.g. a quest turn-in reward) never trigger a server-side push on their own (world_rpc.gd's
# _turn_in() replies with turn_in_result only, no slots — confirmed by reading world_rpc.gd). A
# play-agent that only ever calls `observe` (never presses I) saw a permanently empty inventory
# array even with real items in the bag. Mirroring the T-401 _dump_pvp() precedent ("introspecting
# FORCES the request"), gather() now fires get_inventory() itself on every observe. The read below
# stays synchronous off the panel's cells, which render() already rebuilds regardless of the panel's
# VISIBILITY (inventory_panel.gd's render() runs off every "inventory" server message, not off
# toggle) — so results are self-correcting: the observe call that triggers a fetch may still read
# the prior snapshot, but the reply lands within a frame or two on a local dev server, so the very
# next observe reflects it (same "settles across calls" idiom _norm_player's hp_delta already uses).
static func _live_inventory(main: Node) -> Array:
	var net = main.get("_net")
	if net != null and net.has_method("get_inventory"):
		net.get_inventory()
	var panel = main.get("inventory_panel")
	if panel == null or not panel.has_method("get_cells"):
		return []
	var out: Array = []
	for cell in panel.get_cells():
		var entry = cell.get("_entry")
		if entry is Dictionary and str((entry as Dictionary).get("name", "")) != "":
			out.append({"name": str(entry.get("name", "")), "count": int(entry.get("count", 1))})
	return out


# Nearby players + mobs (remote_entities) and NPCs (npc_world), using the SAME relationship
# the nameplates use for hostility. build() rounds distance and sorts nearest-first.
static func _live_nearby(main: Node) -> Array:
	var out: Array = []
	var node = main.get("local_player")
	if not (node is Node3D):
		return out
	var origin: Vector3 = (node as Node3D).global_position
	var viewer := {"peer_id": int(main.get("_my_peer_id"))}
	var rem = main.get("remote_entities")
	var ents = rem.get("_entities") if rem != null else null
	if ents is Dictionary:
		for eid in ents:
			var e: Dictionary = ents[eid]
			var enode = e.get("node")
			if not (enode is Node3D):
				continue
			var is_player := bool(e.get("is_player", false))
			var unit := (
				{
					"peer_id": int(e.get("target_id", -1)),
					"party_id": int(e.get("party_id", 0)),
					"pvp_flag": bool(e.get("pvp_flag", false)),
				}
				if is_player
				else {"is_mob": true}
			)
			var nm := str(e.get("mob_name", ""))
			if nm == "":
				nm = str(e.get("char_class", "")) if is_player else str(eid)
			(
				out
				. append(
					{
						"name": nm,
						"kind": "player" if is_player else "mob",
						"distance": (enode as Node3D).global_position.distance_to(origin),
						"hostile": Relationship.of(viewer, unit) == Relationship.Rel.HOSTILE,
					}
				)
			)
	var npc = main.get("npc_world")
	var npcs = npc.get("_npcs") if npc != null else null
	if npcs is Dictionary:
		for nid in npcs:
			var e: Dictionary = npcs[nid]
			var body = e.get("body")
			if not (body is Node3D):
				continue
			var label = e.get("name_label")
			(
				out
				. append(
					{
						"name": str(label.get("text")) if label != null else str(nid),
						"kind": "npc",
						"distance": (body as Node3D).global_position.distance_to(origin),
						"hostile": false,
					}
				)
			)
	return out


static func _live_log(main: Node) -> Array:
	var cf = main.get("combat_feedback")
	if cf == null or not cf.has_method("get_combat_log"):
		return []
	var log = cf.get_combat_log()
	if log == null or not log.has_method("get_lines"):
		return []
	return log.get_lines()


static func _live_ui_panel(main: Node) -> String:
	for pair in _PANELS:
		var p = main.get(pair[1])
		if p != null and bool(p.get("visible")):
			return str(pair[0])
	return "none"
