# T-414: world-side crafting seam — gathering nodes + recipe registry + the gather/craft/use_item/
# learn_recipe intents. T-145/T-208 trust shape: the client sends only DESIRES carrying ids; this
# service resolves every id from ITS OWN registries (nodes.json/recipes.json — server data), gates
# proximity from the session position, and the MASTER owns all persistent state. No client-named
# yield, output, or effect anywhere (test_adversarial_client asserts the boundary). Node respawn
# rides the T-411 variable-ratio machinery via spawn_respawn.gd — dwell drawn at DEPLETION time,
# ticked at broadcast cadence (world_rpc.tick_npcs forwards rng here).
# ECON NOTE (T-366): gathering MINTS materials — a faucet tracked BY ITEM (inventory rows), not
# coin; the only coin move is learn_recipe (sink, reason "recipe"), ledgered master-side.
# RefCounted; world_rpc owns an instance (the _ach pattern) and injects master + reply + registries.

extends RefCounted

const _SRESP = preload("res://scripts/spawn_respawn.gd")

const INTERACT_RADIUS := 3.0  # mirrors world_rpc.INTERACT_RADIUS (NPC + node reach)
const _INTENTS := ["gather", "gather_nodes", "craft", "use_item", "learn_recipe", "recipe_catalog"]
const _NODE_KINDS := ["herb", "ore", "timber", "fibre", "fishing"]

var _master = null  # MasterClient (call_master)
var _reply: Callable  # world_rpc._reply -> main._send_to_peer(peer_id, dict)
var _heal: Callable = Callable()  # main-injected: (peer_id, amount) -> live HP heal (server-side)
var _inv_push: Callable = Callable()  # T-570: world_rpc-injected (peer_id, slots) -> bag push
# T-657: world_rpc-injected (peer_id, username, quest_id) -> push_quest_delta, same seam as
# _inv_push/set_quest_defs — lets a successful gather/craft push the LIVE quest-tracker HUD update
# the equip path already gets (world_rpc.gd:707-712), instead of leaving it stale until turn-in.
var _quest_delta_push: Callable = Callable()
var _item_registry: Dictionary = {}  # item_id -> def incl. use_effect (content authority)
var _quest_defs: Dictionary = {}  # T-650: quest_id -> def, so gather/craft can credit collect
var _content_npcs: Dictionary = {}  # trainer proximity checks (reference, world_rpc owns)
var _recipes: Dictionary = {}  # recipe_id -> def (id, profession, inputs, output, trainer_id, ...)
var _nodes: Dictionary = {}  # node_id -> def (id, item_id, count, x, y, respawn/spawn fields)
var _node_state: Dictionary = {}  # node_id -> {"available": bool, "respawn_at": int}
# T-698: node_id -> region index (nodes never move; set_regions precomputes). Empty = no table
# injected -> every node polls every tick, the pre-T-698 behaviour.
var _node_region: Dictionary = {}
var _tick: int = 0  # broadcast-tick counter (tick() cadence)
var _rng = null  # injected via tick() — the rare-node respawn draw (none rare yet) uses it
var _gather_wait: Callable = Callable()  # test seam; production uses a SceneTreeTimer


# Loads recipes.json + gather/nodes.json fail-loud. Returns "" or an error string (boot aborts).
func setup(
	master, reply: Callable, base_path: String, item_registry: Dictionary, content_npcs: Dictionary
) -> String:
	_master = master
	_reply = reply
	_item_registry = item_registry
	_content_npcs = content_npcs
	var rec = _load_array(base_path.path_join("recipes/recipes.json"), "recipes")
	if rec == null:
		return "recipes.json missing or malformed"
	for entry: Dictionary in rec:
		var err := _validate_recipe(entry)
		if err != "":
			return err
		_recipes[str(entry["id"])] = entry
	var nds = _load_array(base_path.path_join("gather/nodes.json"), "nodes")
	if nds == null:
		return "gather/nodes.json missing or malformed"
	for entry: Dictionary in nds:
		var err := _validate_node(entry)
		if err != "":
			return err
		_nodes[str(entry["id"])] = entry
		_node_state[str(entry["id"])] = {"available": true, "respawn_at": 0}
	return ""


func set_heal(heal: Callable) -> void:
	_heal = heal


# T-570: world_rpc injects its shared enrich-and-push helper so a successful gather can refresh
# the client's bag panel the same way equip/unequip/drop already do.
func set_inventory_push(inv_push: Callable) -> void:
	_inv_push = inv_push


# T-650: world_rpc injects the same content-authority quest_defs snapshot equip/unequip/drop get
# per-request, so gather_op/craft_op can hand it to the master and get collect objectives credited.
func set_quest_defs(quest_defs: Dictionary) -> void:
	_quest_defs = quest_defs


# T-657: world_rpc injects its own push_quest_delta (bound Callable) so a successful gather/craft
# can push the same targeted quest-delta the equip-credit path already sends.
func set_quest_delta_push(cb: Callable) -> void:
	_quest_delta_push = cb


# T-659: tests inject a signal-backed wait to prove cast ordering without sleeping for 2.5 seconds.
# Live world code leaves this unset and uses the real SceneTreeTimer in _wait_for_gather.
func set_gather_wait(wait: Callable) -> void:
	_gather_wait = wait


func handles(msg_type: String) -> bool:
	return _INTENTS.has(msg_type)


# Advance one broadcast tick: bring due nodes back. rng is main's (injected, T-411 discipline).
# T-698: `awake` (main's sleeping-zone region set) skips nodes in unobserved regions. `_tick` still
# advances every call and `respawn_at` is an absolute tick, so a due node in a waking region pops
# available on its region's first awake poll — the same absolute-timer resume rule mobs use.
func tick(rng, awake = null) -> void:
	_rng = rng
	_tick += 1
	for node_id in _node_state:
		if not _node_awake(node_id, awake):
			continue
		var st: Dictionary = _node_state[node_id]
		if not bool(st["available"]) and _tick >= int(st["respawn_at"]):
			st["available"] = true


# T-698: precompute each gather node's static region (mirrors npc_director.set_regions).
func set_regions(regions) -> void:
	_node_region.clear()
	if regions == null or regions.region_count() == 0:
		return
	for node_id in _nodes:
		var node: Dictionary = _nodes[node_id]
		_node_region[node_id] = regions.region_index(float(node["x"]), float(node["y"]))


# T-698: unmapped/no-table/no-awake-set degrade to awake (poll), never to silently-asleep.
func _node_awake(node_id: String, awake) -> bool:
	if awake == null or _node_region.is_empty() or not _node_region.has(node_id):
		return true
	return (awake as Dictionary).has(_node_region[node_id])


func handle(msg_type: String, peer_id: int, player: Dictionary, data: Dictionary) -> void:
	match msg_type:
		"gather":
			await _gather(peer_id, player, data)
		"gather_nodes":
			_send_nodes(peer_id)
		"craft":
			await _craft(peer_id, player, data)
		"use_item":
			await _use_item(peer_id, player, data)
		"learn_recipe":
			await _learn_recipe(peer_id, player, data)
		"recipe_catalog":
			await _recipe_catalog(peer_id, player, data)


# ---- gathering -----------------------------------------------------------


# The client names ONLY a node_id; yield item + count come from THIS registry, never the wire.
func _gather(peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var node_id := str(data.get("node_id", ""))
	if not _nodes.has(node_id):
		_fail(peer_id, "gather_result", {"node_id": node_id, "reason": "unknown_node"})
		return
	var node: Dictionary = _nodes[node_id]
	var ppos: Vector3 = player.get("pos", Vector3.ZERO)
	if ppos.distance_to(Vector3(float(node["x"]), float(node["y"]), 0.0)) > INTERACT_RADIUS:
		_fail(peer_id, "gather_result", {"node_id": node_id, "reason": "too_far"})
		return
	var st: Dictionary = _node_state[node_id]
	if not bool(st["available"]):
		_fail(peer_id, "gather_result", {"node_id": node_id, "reason": "depleted"})
		return
	# T-641 (portal #87): claim the node BEFORE the master await, synchronously — the check above and
	# this write happen with no yield between them, so a second gather racing the same node sees
	# available=false here and is rejected honestly instead of also passing the check and minting a
	# second yield from one node availability window (the TOCTOU: old code only wrote `available =
	# false` AFTER the await returned). Roll back if the master round-trip itself fails (bag full,
	# unknown character, etc.) — nothing was actually minted, so the node was never truly consumed.
	st["available"] = false
	var gather_seconds := maxf(0.0, float(node.get("gather_seconds", 0.0)))
	if gather_seconds > 0.0:
		await _wait_for_gather(gather_seconds)
	var caught: Dictionary = _roll_node_yield(node, _rng)
	var result: Dictionary = await (
		_master
		. call_master(
			"gather_op",
			{
				"username": str(player.get("username", "")),
				"item_id": str(caught["item_id"]),
				"count": int(caught["count"]),
				"bonus": caught.get("bonus", {}),  # T-677: additive rare cross-find ({} = none)
				"item_registry": _item_registry,
				"quest_defs": _quest_defs,  # T-650: lets the master credit collect on a gather
			}
		)
	)
	var ok := bool(result.get("ok", false)) and not result.has("error")
	if ok:  # draw the next dwell NOW (T-411: geometric fold at depletion time)
		st["respawn_at"] = (
			_tick
			+ _SRESP.next_ticks(
				int(node.get("respawn_ticks", 600)), float(node.get("spawn_chance", 1.0)), _rng
			)
		)
	else:  # T-641: master-side failure — release the claim, nothing was minted
		st["available"] = true
	(
		_reply
		. call(
			peer_id,
			{
				"type": "gather_result",
				"ok": ok,
				"node_id": node_id,
				"item_id": str(caught["item_id"]) if ok else "",
				"count": int(caught["count"]) if ok else 0,
				# T-677: the additive rare cross-find, surfaced honestly so the client can toast
				# the surprise (empty when no proc fired). Never displaces the primary yield above.
				"bonus_item_id": str(caught.get("bonus", {}).get("item_id", "")) if ok else "",
				"bonus_count": int(caught.get("bonus", {}).get("count", 0)) if ok else 0,
				"reason": str(result.get("error", result.get("reason", ""))),
			}
		)
	)
	# T-570 (report #30): gather_op mints the item server-side (result["slots"]), but the
	# "gather_result" reply above isn't a type client_net.gd routes to the bag panel — push a
	# real inventory update too, the same way equip/unequip/drop already do.
	if ok and result.has("slots") and _inv_push.is_valid():
		_inv_push.call(peer_id, result["slots"])
	if ok:
		await _push_collect_credits(peer_id, str(player.get("username", "")), result)


# The weighted-roll resolver shared by every gather kind. The PRIMARY yield is a categorical roll
# over `drops` (authored chances sum to 1.0): fishing catches exactly one fish per relaxing cast;
# herb/ore/timber roll their bonus-yield amount (mostly 1, sometimes 2-3) off the SAME base item,
# so the guaranteed item is never displaced. T-677 then folds an ADDITIVE rare cross-find on top: an
# independent low-odds Bernoulli proc (`bonus_find`) that mints a rare item ALONGSIDE the primary,
# never in place of it. Fishing carries no `bonus_find`, so its catch stays byte-identical: no extra
# rng draw and no `bonus` key. Legacy nodes with neither field keep the fixed item_id/count path.
func _roll_node_yield(node: Dictionary, rng) -> Dictionary:
	var result: Dictionary = _roll_primary_yield(node, rng)
	var bonus: Dictionary = node.get("bonus_find", {})
	if not bonus.is_empty() and rng.randf() < float(bonus.get("chance", 0.0)):
		var bmin := maxi(1, int(bonus.get("count_min", 1)))
		var bmax := maxi(bmin, int(bonus.get("count_max", bmin)))
		result["bonus"] = {"item_id": str(bonus["item_id"]), "count": rng.randi_range(bmin, bmax)}
	return result


# The categorical primary pick — unchanged from the shipped T-659 fishing resolver.
func _roll_primary_yield(node: Dictionary, rng) -> Dictionary:
	var drops: Array = node.get("drops", [])
	if drops.is_empty():
		return {
			"item_id": str(node.get("item_id", "")), "count": maxi(1, int(node.get("count", 1)))
		}
	var roll_point: float = rng.randf()
	var cumulative := 0.0
	for drop: Dictionary in drops:
		cumulative += float(drop.get("chance", 0.0))
		if roll_point < cumulative:
			var count_min := maxi(1, int(drop.get("count_min", 1)))
			var count_max := maxi(count_min, int(drop.get("count_max", count_min)))
			return {"item_id": str(drop["item_id"]), "count": rng.randi_range(count_min, count_max)}
	var fallback: Dictionary = drops[-1]
	return {
		"item_id": str(fallback["item_id"]), "count": maxi(1, int(fallback.get("count_min", 1)))
	}


func _wait_for_gather(seconds: float) -> void:
	if _gather_wait.is_valid():
		await _gather_wait.call(seconds)
		return
	await Engine.get_main_loop().create_timer(seconds).timeout


# Read-only marker feed — kind + display_name are server-authored cosmetic data; they grant no
# client authority. display_name is the clean world label ("Bloodthorn"); the interaction VERB
# ("Gather") lives in the client UI, never baked into the name — see _node_display_name.
func _send_nodes(peer_id: int) -> void:
	var out: Array = []
	for node_id in _nodes:
		var node: Dictionary = _nodes[node_id]
		var row := {"id": node_id, "x": float(node["x"]), "y": float(node["y"])}
		row["item_id"] = str(node["item_id"])
		row["kind"] = str(node["kind"])
		row["display_name"] = _node_display_name(node)
		row["available"] = bool(_node_state[node_id]["available"])
		out.append(row)
	_reply.call(peer_id, {"type": "gather_nodes", "nodes": out})


# The world label for a node: the authored display_name, else the item's registry name, else a
# cleaned item id. Never carries the "Gather" verb — that is the client's interaction prompt.
func _node_display_name(node: Dictionary) -> String:
	var explicit := str(node.get("display_name", "")).strip_edges()
	if explicit != "":
		return explicit
	var item: Dictionary = _item_registry.get(str(node.get("item_id", "")), {})
	var iname := str(item.get("name", "")).strip_edges()
	if iname != "":
		return iname
	return str(node.get("item_id", "")).trim_prefix("itm_").replace("_", " ")


# ---- crafting ------------------------------------------------------------


# The client names ONLY a recipe_id; inputs/output come from THIS registry (server-named output).
func _craft(peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var recipe_id := str(data.get("recipe_id", ""))
	if not _recipes.has(recipe_id):
		_fail(peer_id, "craft_result", {"recipe_id": recipe_id, "reason": "unknown_recipe"})
		return
	var result: Dictionary = await (
		_master
		. call_master(
			"craft_op",
			{
				"username": str(player.get("username", "")),
				"recipe": _recipes[recipe_id],
				"item_registry": _item_registry,
				"quest_defs": _quest_defs,  # T-650: lets the master credit collect on a craft output
			}
		)
	)
	var ok := bool(result.get("ok", false))
	(
		_reply
		. call(
			peer_id,
			{
				"type": "craft_result",
				"ok": ok,
				"recipe_id": recipe_id,
				"output": _recipes[recipe_id].get("output", {}) if ok else {},
				"reason": str(result.get("error", result.get("reason", ""))),
			}
		)
	)
	# T-583 (report #39): craft_op consumes inputs + grants the output master-side (result["slots"]),
	# but "craft_result" isn't a type client_net.gd renders bag state from — mirrors the T-570 gather
	# push (same seam) so the bag panel doesn't go stale until a manual reopen.
	if ok and result.has("slots") and _inv_push.is_valid():
		_inv_push.call(peer_id, result["slots"])
	if ok:
		await _push_collect_credits(peer_id, str(player.get("username", "")), result)


# The client names ONLY a bag slot_index; the item AND its effect resolve master/content-side.
func _use_item(peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var slot_index := int(data.get("slot_index", -1))
	var result: Dictionary = await (
		_master
		. call_master(
			"use_item_op",
			{
				"username": str(player.get("username", "")),
				"slot_index": slot_index,
				"item_registry": _item_registry,
			}
		)
	)
	var ok := bool(result.get("ok", false))
	var effect: Dictionary = result.get("effect", {})
	# heal is WORLD state (live combat resources) — applied here from the master-returned effect,
	# which the master read off ITEM DATA. rested/repair were already applied master-side.
	if ok and str(effect.get("kind", "")) == "heal" and _heal.is_valid():
		_heal.call(peer_id, int(effect.get("amount", 0)))
	(
		_reply
		. call(
			peer_id,
			{
				"type": "use_item_result",
				"ok": ok,
				"slot_index": slot_index,
				"effect": effect if ok else {},
				"reason": str(result.get("error", result.get("reason", ""))),
			}
		)
	)
	# T-583 (report #39): use_item_op consumes the item master-side (result["slots"]), same gap as
	# craft above — push the fresh bag through the shared T-570 seam so the consumed item disappears
	# without a manual panel reopen.
	if ok and result.has("slots") and _inv_push.is_valid():
		_inv_push.call(peer_id, result["slots"])


# ---- recipe learning (trainer surface; coin sink reason "recipe") ---------


# Proximity + taught-here are gated HERE (world owns NPC positions + recipe->trainer mapping);
# the master owns already-known/coins and debits via the ledgered "recipe" reason.
func _learn_recipe(peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var npc_id := str(data.get("npc_id", ""))
	var recipe_id := str(data.get("recipe_id", ""))
	var gate := _trainer_gate(npc_id, player)
	if gate == "" and str(_recipes.get(recipe_id, {}).get("trainer_id", "")) != npc_id:
		gate = "not_taught_here"
	if gate != "":
		_fail(peer_id, "learn_recipe_result", {"recipe_id": recipe_id, "reason": gate})
		return
	var result: Dictionary = await (
		_master
		. call_master(
			"recipe_op",
			{
				"username": str(player.get("username", "")),
				"action": "learn",
				"recipe": _recipes[recipe_id],
			}
		)
	)
	(
		_reply
		. call(
			peer_id,
			{
				"type": "learn_recipe_result",
				"ok": not result.has("error"),
				"recipe_id": recipe_id,
				"known": result.get("known", []),
				"coins": int(result.get("coins", 0)),
				"reason": str(result.get("error", "")),
			}
		)
	)


func _recipe_catalog(peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var npc_id := str(data.get("npc_id", ""))
	var gate := _trainer_gate(npc_id, player)
	if gate != "":
		_fail(peer_id, "recipe_catalog", {"npc_id": npc_id, "reason": gate})
		return
	var result: Dictionary = await _master.call_master(
		"recipe_op", {"username": str(player.get("username", "")), "action": "list"}
	)
	var taught: Array = []
	for recipe_id in _recipes:
		if str(_recipes[recipe_id].get("trainer_id", "")) == npc_id:
			taught.append(_recipes[recipe_id])
	(
		_reply
		. call(
			peer_id,
			{
				"type": "recipe_catalog",
				"ok": true,
				"npc_id": npc_id,
				"recipes": taught,
				"known": result.get("known", []),
			}
		)
	)


# "" when npc exists + player is in range; else the rejection reason.
func _trainer_gate(npc_id: String, player: Dictionary) -> String:
	if not _content_npcs.has(npc_id):
		return "unknown_npc"
	var npc = _content_npcs[npc_id]
	var ppos: Vector3 = player.get("pos", Vector3.ZERO)
	if ppos.distance_to(Vector3(npc.x, npc.y, 0.0)) > INTERACT_RADIUS:
		return "too_far"
	return ""


# ---- internals -------------------------------------------------------------


# T-657: T-650 credited collect-quest progress master-side (result["collect_refreshed"], a list of
# quest ids) on a successful gather/craft, but neither caller ever forwarded it to the client — the
# quest-tracker HUD stayed stuck at a stale count until an unrelated event (or turn-in) refreshed
# it. Mirrors world_rpc.gd:707-712's equip-credit push, one call per credited quest id.
func _push_collect_credits(peer_id: int, username: String, result: Dictionary) -> void:
	if not _quest_delta_push.is_valid():
		return
	for quest_id in result.get("collect_refreshed", []):
		await _quest_delta_push.call(peer_id, username, str(quest_id))


func _fail(peer_id: int, reply_type: String, extra: Dictionary) -> void:
	var msg := {"type": reply_type, "ok": false}
	msg.merge(extra)
	_reply.call(peer_id, msg)


func _validate_recipe(entry: Dictionary) -> String:
	var rid := str(entry.get("id", ""))
	if rid == "" or _recipes.has(rid):
		return "recipe missing/duplicate id: %s" % rid
	var output: Dictionary = entry.get("output", {})
	if not _item_registry.has(str(output.get("item", ""))):
		return "recipe %s output item unknown: %s" % [rid, str(output.get("item", ""))]
	for input: Dictionary in entry.get("inputs", []):
		if not _item_registry.has(str(input.get("item", ""))):
			return "recipe %s input item unknown: %s" % [rid, str(input.get("item", ""))]
	if not _content_npcs.has(str(entry.get("trainer_id", ""))):
		return "recipe %s trainer unknown: %s" % [rid, str(entry.get("trainer_id", ""))]
	return ""


func _validate_node(entry: Dictionary) -> String:
	var nid := str(entry.get("id", ""))
	if nid == "" or _nodes.has(nid):
		return "gather node missing/duplicate id: %s" % nid
	if not _item_registry.has(str(entry.get("item_id", ""))):
		return "gather node %s yields unknown item: %s" % [nid, str(entry.get("item_id", ""))]
	if not _NODE_KINDS.has(str(entry.get("kind", ""))):
		return "gather node %s has unknown kind: %s" % [nid, str(entry.get("kind", ""))]
	var drops_err := _validate_node_drops(nid, entry.get("drops", []))
	if drops_err != "":
		return drops_err
	return _validate_bonus_find(nid, entry.get("bonus_find", {}))


func _validate_node_drops(node_id: String, drops: Array) -> String:
	if not drops.is_empty():
		var total_chance := 0.0
		for drop: Dictionary in drops:
			var item_id := str(drop.get("item_id", ""))
			if not _item_registry.has(item_id):
				return "gather node %s drop item unknown: %s" % [node_id, item_id]
			var chance := float(drop.get("chance", 0.0))
			if chance <= 0.0 or chance >= 1.0:
				return "gather node %s drop chance must be between 0 and 1: %s" % [node_id, chance]
			total_chance += chance
		if not is_equal_approx(total_chance, 1.0):
			return "gather node %s drop chances must total 1.0: %s" % [node_id, total_chance]
	return ""


# T-677: the additive rare cross-find is server-authoritative + honest — its item must exist and its
# odds must be a real proc (0 < chance < 1). A rare tier at chance 1.0 would be a hidden guaranteed
# drop wearing a rare label; boot aborts on it, the same fail-loud discipline the drop table gets.
func _validate_bonus_find(node_id: String, bonus: Dictionary) -> String:
	if bonus.is_empty():
		return ""
	var item_id := str(bonus.get("item_id", ""))
	if not _item_registry.has(item_id):
		return "gather node %s bonus_find item unknown: %s" % [node_id, item_id]
	var chance := float(bonus.get("chance", 0.0))
	if chance <= 0.0 or chance >= 1.0:
		return "gather node %s bonus_find chance must be between 0 and 1: %s" % [node_id, chance]
	return ""


# Parse {array_key: [...]} out of a JSON file, or null on missing/malformed.
func _load_array(path: String, array_key: String):
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not (parsed.get(array_key, null) is Array):
		return null
	return parsed[array_key]
