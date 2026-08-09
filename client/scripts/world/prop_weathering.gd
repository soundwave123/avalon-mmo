# T-290: sun-keyed weathering (moss/lichen/damp-stain) — the per-class intensity table + the
# material_overlay applier, extracted verbatim from world_props_layer.gd (T-688 kept that file
# under the 1000-line cap the way T-692 did with transform_aabb). Pure/static: no layer state.
extends RefCounted

const WEATHER_SHADER := preload("res://shaders/moss_overlay.gdshader")


# Weathering intensity by prop class. Returns {amount, roof, climb} or {} to leave a prop clean.
# Physics-consistent grading (docs/tickets/art/T-290.md, T-288 wealth/age story):
#   * damp stone (wells, churchyard, boulders) mosses hardest;
#   * old rural timber (barn/palisade/mill/village houses) weathers moderately;
#   * civic keep/walls a touch less; the wealthier city (hk_house_*) stays nearly clean;
#   * tree trunks moss only at the shaded base (roof=0 keeps the canopy untinted);
#   * cloth/metal/movable goods/foliage/furniture/animals/young saplings are never mossed.
# climb = metres moss climbs from the base; roof = whether north up-faces (roof slopes/kerbs) moss.
static func weathering_for(base: String) -> Dictionary:
	# Damp stone — the wettest, most-colonised surfaces.
	if base.begins_with("prop_well"):
		return {"amount": 0.72, "roof": 1.0, "climb": 1.3}
	if base.begins_with("prop_boulder") or base.begins_with("prop_rock"):
		return {"amount": 0.62, "roof": 1.0, "climb": 1.1}
	if (
		base.begins_with("prop_churchyard_wall")
		or base.begins_with("prop_headstone")
		or base.begins_with("prop_hk_cross")
		or base.begins_with("prop_waystone")
		or base.begins_with("prop_wayshrine")
		or base.begins_with("prop_mounting_block")
		or base.begins_with("prop_hk_cathedral")
		or base.begins_with("prop_church")
		or base.begins_with("prop_trough")
	):
		return {"amount": 0.55, "roof": 1.0, "climb": 1.6}
	# T-288 poor-folk cottages — owner-built, neglected, the most weathered dwellings of all
	# (mossy north thatch, damp daub); heavier than the tended village houses below.
	if base.begins_with("prop_cottage_poor"):
		return {"amount": 0.52, "roof": 1.0, "climb": 2.0}
	# Old rural timber/thatch — weathers plainly.
	if (
		base.begins_with("prop_palisade")
		or base.begins_with("prop_barn")
		or base.begins_with("prop_watchtower")
		or base.begins_with("prop_watermill")
		or base.begins_with("prop_windmill")
		or base.begins_with("prop_dovecote")
	):
		return {"amount": 0.5, "roof": 1.0, "climb": 1.9}
	# Civic stone — kept, dressed, so a touch cleaner than the byres.
	if (
		base.begins_with("prop_hk_keep")
		or base.begins_with("prop_hk_walls")
		or base.begins_with("prop_hk_gatehouse")
		or base.begins_with("prop_hk_bank")
		or base.begins_with("prop_hk_auction")
		or base.begins_with("prop_hk_trainer")
	):
		return {"amount": 0.4, "roof": 1.0, "climb": 2.3}
	# Older village houses/inns — lived-in but tended.
	if (
		base.begins_with("prop_inn")
		or base.begins_with("prop_tavern")
		or base.begins_with("prop_farmhouse")
		or base.begins_with("prop_cottage")
		or base.begins_with("prop_house_")
		or base.begins_with("prop_smithy")
	):
		return {"amount": 0.33, "roof": 1.0, "climb": 1.7}
	# Fences — low timber, mosses at the ground line only.
	if base.begins_with("prop_fence"):
		return {"amount": 0.28, "roof": 0.35, "climb": 1.0}
	# The wealthier capital houses — newest/best-kept, barely touched (T-296 owns their regen).
	if base.begins_with("prop_hk_house"):
		return {"amount": 0.16, "roof": 1.0, "climb": 1.6}
	# Tree trunks / stumps — moss only on the shaded lower trunk; canopy stays clean (roof=0).
	if (
		base.begins_with("prop_oak")
		or base.begins_with("prop_tree")
		or base.begins_with("prop_stump")
	):
		return {"amount": 0.42, "roof": 0.0, "climb": 2.6}
	return {}


# Attach the moss/weathering overlay to every mesh of a placed prop. One ShaderMaterial per prop
# (shared across its surfaces) carries the age/height params; material_overlay draws it as a
# second pass on top of the base material, so the GLB is never modified.
static func apply(node: Node, base: String, world_y: float) -> void:
	var cfg := weathering_for(base)
	if cfg.is_empty():
		return
	var mat := ShaderMaterial.new()
	mat.shader = WEATHER_SHADER
	mat.set_shader_parameter("moss_amount", float(cfg["amount"]))
	mat.set_shader_parameter("roof_weight", float(cfg["roof"]))
	mat.set_shader_parameter("climb_h", float(cfg["climb"]))
	mat.set_shader_parameter("ground_y", world_y)
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		# The overlay triggers Godot's per-frame tangent warning (a known perf hog,
		# godotengine/godot#106276) on tangent-less meshes. Leaf-dense card GLBs can't
		# afford baked tangents inside the 3MB cap (T-312 broadleafs) — skip them honestly;
		# every other prop got tangents via tools/assetgen/add_tangents.py.
		var tangentless := false
		if mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				var arrays: Array = mi.mesh.surface_get_arrays(s)
				if arrays.size() > Mesh.ARRAY_TANGENT and arrays[Mesh.ARRAY_TANGENT] == null:
					tangentless = true
					break
		if tangentless:
			continue
		mi.material_overlay = mat
