extends RefCounted
# T-426 (carve): the client-facing NPC-view payload builder, extracted from world_rpc.gd where it
# was duplicated between the full indicator query (_npc_indicators) and the targeted delta push
# (_push_npc_indicator_delta). Pure: content + the resolved {npc_id: indicator} map -> the Array of
# per-NPC render dicts the client draws over each NPC. No RPC, no state.


# Build the render payload for `npc_ids` (each must exist in content_npcs). `indicators` is the
# resolved !/? map; a missing entry renders as "" (no marker).
static func build(content_npcs: Dictionary, npc_ids: Array, indicators: Dictionary) -> Array:
	var out: Array = []
	for npc_id: String in npc_ids:
		if not content_npcs.has(npc_id):
			continue
		var n = content_npcs[npc_id]
		(
			out
			. append(
				{
					"npc_id": npc_id,
					"name": n.name,
					"x": n.x,
					"y": n.y,
					"indicator": indicators.get(npc_id, ""),
					"trainer": n.trainer,  # T-076: trainers get a distinct look
					"appearance": n.appearance,  # T-302: role/sex/scale/seed → client rig + tint
				}
			)
		)
	return out
