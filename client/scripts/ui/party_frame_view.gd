class_name PartyFrameView
extends RefCounted

# T-511 carve: the pure party-frame row builder, lifted out of main.gd at the 1000-line cap
# (the npc_indicator_view / combat_snapshot precedent). Given the positions broadcast plus party
# membership + leader/subgroup state, it produces the rows PartyFrames.set_party() renders. No node
# access and no side effects, so it unit-tests directly.

const CryptGate = preload("res://scripts/world/crypt_gate.gd")


static func build_rows(
	data: Dictionary,
	party_members: Array,
	my_peer_id: int,
	party_leader: String,
	party_subgroups: Dictionary,
	ready_radius: float,
	party_range_m: float
) -> Array:
	var by_name := {}
	var my_pos := Vector3.ZERO
	for p: Dictionary in data.get("players", []):
		by_name[str(p.get("username", ""))] = p
		if int(p.get("peer_id", -1)) == my_peer_id:
			my_pos = Vector3(float(p.get("x", 0.0)), float(p.get("y", 0.0)), float(p.get("z", 0.0)))
	var rows := []
	for uname: String in party_members:
		var p: Dictionary = by_name.get(uname, {})
		var pos := Vector3(float(p.get("x", 0.0)), float(p.get("y", 0.0)), float(p.get("z", 0.0)))
		# T-334: ready = standing at the churchyard crypt stair (server ground x,y vs the T-330 porch
		# threshold) — the forming group sees who is already at the dungeon door.
		var at_stair := Vector2(pos.x, pos.y).distance_to(CryptGate.ENTER_POINT) <= ready_radius
		(
			rows
			. append(
				{
					"peer_id": int(p.get("peer_id", -1)),
					"name": uname,
					"hp": int(p.get("hp", 0)),
					"max_hp": int(p.get("max_hp", 0)),
					"resource": int(p.get("resource", 0)),
					"max_resource": int(p.get("max_resource", 0)),
					"char_class": str(p.get("char_class", "")),
					"leader": uname == party_leader,
					"in_range": my_pos.distance_to(pos) <= party_range_m,
					"ready": at_stair,
					"subgroup": int(party_subgroups.get(uname, 0)),  # T-472: raid column
				}
			)
		)
	return rows
