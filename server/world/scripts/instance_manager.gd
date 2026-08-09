# T-331: soft-instance membership for the Hollowed Crypt — a logical partition on top of the
# single shared world, NOT full dynamic-map instancing. Same server, same ENet peer, one process;
# only mob spawns and the positions broadcast are scoped. A party descending the crypt stair gets
# its own `instance_id`; the broadcast is filtered to same-instance peers so two parties never
# collide on the three bosses. The T-280 party is the instance key (party-mates rejoin the same id;
# a solo entrant always gets a private instance).
#
# Pure store ops (party_logic.gd / npc_wander.gd precedent): every function operates on a passed
# store dict with no scene tree, no OS time, no side effects — so the full enter/leave/teardown
# transition matrix unit-tests headlessly. main.gd owns the LIVE store + spawn seeding + broadcast
# bucketing (instance_service.gd wires it); this module owns only membership truth.
extends RefCounted

const WORLD := 0  # the shared open world — unchanged "everyone sees everyone" behaviour


# A fresh store.
#   instances:   instance_id -> {party_id:int, members:Array[peer_id], spawns:Array[entity_id]}
#   instance_of: peer_id     -> instance_id   (absent == WORLD)
#   party_index: party_id    -> instance_id   (rejoin key; solo entrants, party_id -1, unindexed)
#   next_id:     monotonic, starts at 1       (0 reserved for WORLD)
static func new_store() -> Dictionary:
	return {"instances": {}, "instance_of": {}, "party_index": {}, "next_id": 1}


# The instance a peer is currently in (WORLD if none). The single membership-truth read.
static func instance_of(store: Dictionary, peer: int) -> int:
	return int(store["instance_of"].get(peer, WORLD))


# A peer enters an instance. `party_id` -1 == solo (always a fresh private instance). A party's
# FIRST entrant allocates the instance and needs spawns seeded (`created` == true); every later
# party-mate JOINS that same `instance_id` (created == false). Idempotent — a peer already inside
# is returned its current id and never double-added. Returns {instance_id:int, created:bool}.
static func enter(store: Dictionary, peer: int, party_id: int) -> Dictionary:
	if store["instance_of"].has(peer):
		return {"instance_id": instance_of(store, peer), "created": false}
	var iid: int
	var created := false
	if party_id != -1 and store["party_index"].has(party_id):
		iid = int(store["party_index"][party_id])
	else:
		iid = int(store["next_id"])
		store["next_id"] = iid + 1
		store["instances"][iid] = {"party_id": party_id, "members": [], "spawns": []}
		if party_id != -1:
			store["party_index"][party_id] = iid
		created = true
	store["instances"][iid]["members"].append(peer)
	store["instance_of"][peer] = iid
	return {"instance_id": iid, "created": created}


# A peer leaves its instance (exit stair, disband-then-exit, disconnect, or duplicate-login kick).
# When the LAST member leaves, the instance is torn down and its spawn ids returned to free.
# Party disband is deliberately NOT handled here: membership is decoupled from the live party, so a
# party that disbands mid-crypt keeps fighting where it stands until each member walks out — the
# instance survives on its remaining members, never on the now-dead party key. No-op for a WORLD
# peer. Returns {instance_id:int, torn_down:bool, freed_spawns:Array[entity_id]}.
static func leave(store: Dictionary, peer: int) -> Dictionary:
	if not store["instance_of"].has(peer):
		return {"instance_id": WORLD, "torn_down": false, "freed_spawns": []}
	var iid := int(store["instance_of"][peer])
	store["instance_of"].erase(peer)
	var inst: Dictionary = store["instances"].get(iid, {})
	if inst.is_empty():
		return {"instance_id": iid, "torn_down": false, "freed_spawns": []}
	inst["members"].erase(peer)
	if not inst["members"].is_empty():
		return {"instance_id": iid, "torn_down": false, "freed_spawns": []}
	var freed: Array = inst["spawns"].duplicate()
	var pkey: int = int(inst["party_id"])
	if pkey != -1 and int(store["party_index"].get(pkey, -1)) == iid:
		store["party_index"].erase(pkey)
	store["instances"].erase(iid)
	return {"instance_id": iid, "torn_down": true, "freed_spawns": freed}


# Record the spawn entity_ids seeded into a freshly-allocated instance so teardown frees exactly
# them. Silent no-op if the instance is already gone (its last member raced out first).
static func set_spawns(store: Dictionary, instance_id: int, spawn_ids: Array) -> void:
	var inst: Dictionary = store["instances"].get(instance_id, {})
	if not inst.is_empty():
		inst["spawns"] = spawn_ids.duplicate()


# The live members of an instance (copy). Empty for WORLD or a torn-down id.
static func members(store: Dictionary, instance_id: int) -> Array:
	var inst: Dictionary = store["instances"].get(instance_id, {})
	return inst.get("members", []).duplicate()


static func instance_count(store: Dictionary) -> int:
	return store["instances"].size()
