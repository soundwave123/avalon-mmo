extends "res://addons/gut/test.gd"

const WorldPropsLayer = preload("res://scripts/world/world_props_layer.gd")


func _load_props() -> Array:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/props.json"))
	return raw["props"] if raw is Dictionary and raw.has("props") else raw


func test_highkeep_market_has_no_tropical_fruit_baskets() -> void:
	# T-493: the fruit-basket asset's strong yellow stacked fruit reads as bananas in the
	# Highkeep market shots. Market stall dressing uses period-neutral sacks/crates/barrels
	# instead of the suspect tropical-looking basket.
	var checked := 0
	for p in _load_props():
		if not (p is Dictionary):
			continue
		var tag := String(p.get("tag", ""))
		var in_highkeep_market := tag in ["highkeep", "t298"]
		var near_market := (
			Vector2(float(p.get("x", 999.0)), float(p.get("y", 999.0))).distance_to(
				Vector2(0.0, -216.0)
			)
			< 22.0
		)
		if in_highkeep_market and near_market:
			checked += 1
			assert_false(
				String(p.get("scene", "")).contains("prop_fruit_basket"),
				(
					"Highkeep market prop at (%s,%s) avoids suspect yellow fruit basket"
					% [p.get("x", "?"), p.get("y", "?")]
				)
			)
	assert_gt(checked, 20, "Highkeep market dressing was audited")


func test_highkeep_river_wall_has_culvert_marker() -> void:
	var found := false
	for p in _load_props():
		if not (p is Dictionary and String(p.get("tag", "")) == "t492_river"):
			continue
		found = true
		assert_eq(String(p.get("scene", "")), "res://assets/models/prop_bridge_stone.glb")
		assert_between(float(p.get("x", 0.0)), 50.0, 58.0, "culvert sits on the wall river x")
		assert_between(float(p.get("y", 0.0)), -360.0, -344.0, "culvert sits at the wall crossing")
		assert_false(
			bool(p.get("solid", true)), "culvert marker is visual-only and avoids nav blockage"
		)
	assert_true(found, "T-492 culvert marker placed")


func test_place_applies_explicit_terrain_height() -> void:
	var layer := WorldPropsLayer.new()
	var placed := (
		layer
		. _place(
			{
				"scene": "res://assets/models/prop_haybale_v2.glb",
				"x": 12.4,
				"y": 10.6,
				"terrain_y": -0.16,
				"solid": false,
			}
		)
	)
	add_child_autofree(layer)
	assert_true(placed, "fixture prop loads")
	assert_almost_eq(layer.get_child(0).position.y, -0.16, 0.001, "prop base follows grade")


func test_livestock_prop_registers_as_a_wandering_critter() -> void:
	# T-310: sheep/pig/cow/chicken/rabbit get a wander/flee brain instead of a static loop-idle.
	# autofree (not add_child_autofree): this stays OUT of the tree so _ready() never fires and
	# re-loads the real (thousand-plus-prop) props.json on top of our one fixture placement.
	var layer = autofree(WorldPropsLayer.new())
	var placed = layer._place({"scene": "res://assets/models/mob_sheep.glb", "x": 3.0, "y": 4.0})
	assert_true(placed, "fixture prop loads")
	assert_eq(layer.critter_count, 1, "sheep registers as a wandering critter")
	var home: Vector3 = layer._critters[0]["home"]
	assert_eq(home, Vector3(3.0, 0.0, 4.0), "home anchors at the placed position")


func test_non_livestock_prop_does_not_register_as_a_critter() -> void:
	var layer = autofree(WorldPropsLayer.new())
	layer._place({"scene": "res://assets/models/prop_haybale_v2.glb", "x": 0.0, "y": 0.0})
	assert_eq(layer.critter_count, 0, "static dressing isn't given a wander brain")


# T-187: interior volumes are derived, not hand-typed — a building's own socket_door (or, for the
# legacy procedural kit, a plain "door" node) marks it enterable, and the volume's footprint comes
# from the instanced GLB's own mesh bounds.
func test_building_with_door_socket_registers_an_interior_volume() -> void:
	var layer = autofree(WorldPropsLayer.new())
	layer._place(
		{"scene": "res://assets/models/prop_cottage_v2.glb", "x": 8.8, "y": 9.0, "rot_deg": 270}
	)
	assert_eq(layer.interior_volumes.size(), 1, "cottage's socket_door makes it enterable")
	var vol: Dictionary = layer.interior_volumes[0]
	assert_gt(vol["half_extents"].x, 0.0, "derived footprint has real width")
	assert_gt(vol["half_extents"].y, 0.0, "derived footprint has real depth")
	assert_gt(vol["height"], 0.0, "derived floor-to-roof height")


func test_legacy_plain_door_node_also_registers_an_interior_volume() -> void:
	# prop_farmhouse.glb predates the socket_ convention (gen_*_real.py kit): a plain "door" node,
	# not socket_door. Still enterable.
	var layer = autofree(WorldPropsLayer.new())
	layer._place(
		{"scene": "res://assets/models/prop_farmhouse.glb", "x": 44.0, "y": 20.0, "rot_deg": 250}
	)
	assert_eq(layer.interior_volumes.size(), 1, "plain 'door' node still counts as enterable")


func test_building_without_any_door_marker_gets_no_fabricated_interior_volume() -> void:
	# prop_barn.glb is a single decorative mesh with no door node/socket at all — honestly not
	# walk-in, so no volume is invented for it.
	var layer = autofree(WorldPropsLayer.new())
	layer._place(
		{"scene": "res://assets/models/prop_barn.glb", "x": 40.0, "y": 14.0, "rot_deg": 200}
	)
	assert_eq(layer.interior_volumes.size(), 0, "no door marker -> no interior volume")


# T-187: socket_chimney migration (already shipped at T-209) is verified against the real GLB;
# the legacy-name fallback covers generators that predate the socket convention entirely.
func test_socket_chimney_joins_the_smoke_group() -> void:
	var layer = autofree(WorldPropsLayer.new())
	layer._place({"scene": "res://assets/models/prop_cottage_v2.glb", "x": 0.0, "y": 0.0})
	assert_true(_has_chimney_socket(layer), "socket_chimney is discoverable via chimney_sockets")


func test_legacy_chimney_node_falls_back_into_the_smoke_group() -> void:
	var layer = autofree(WorldPropsLayer.new())
	layer._place({"scene": "res://assets/models/prop_farmhouse.glb", "x": 0.0, "y": 0.0})
	assert_true(
		_has_chimney_socket(layer), "legacy 'chimney' node falls back via _CHIMNEY_FALLBACK"
	)


# T-529: the roadside dock weed (prop_flora_dock) must stay a knee-high rosette, not the
# rhubarb/gunnera-sized clump the audit flagged. The size lives in the GLB (props.json "scale"
# is only per-instance jitter ~0.95-1.10, matching the sibling wildflowers), so the guard is on
# the mesh's own intrinsic height. Measured before this fix: 0.507 m; after: ~0.42 m — in line
# with poppy (0.39) / cornflower (0.41) / nettle (0.47).
func test_dock_flora_glb_is_knee_high() -> void:
	var inst: Node3D = (
		(load("res://assets/models/prop_flora_dock.glb") as PackedScene).instantiate()
	)
	autofree(inst)
	var aabb := _mesh_aabb(inst, inst.transform)
	assert_between(
		aabb.size.y, 0.30, 0.55, "dock reads as a knee-high weed, not a giant-leaf ornamental"
	)
	assert_almost_eq(aabb.position.y, 0.0, 0.02, "dock base sits on the ground (no reseat needed)")


func _t530_props() -> Array:
	var out := []
	for p in _load_props():
		if p is Dictionary and String(p.get("tag", "")) == "t530":
			out.append(p)
	return out


func _nearest_t530(scene_substrings: Array, anchor: Vector2) -> float:
	# metres from `anchor` to the closest t530 prop whose scene matches any substring (INF = none).
	var best := INF
	for p in _t530_props():
		var scene := String(p.get("scene", ""))
		var hit := false
		for s in scene_substrings:
			if scene.contains(String(s)):
				hit = true
				break
		if not hit:
			continue
		var d := Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0))).distance_to(anchor)
		best = minf(best, d)
	return best


# T-530: the Highkeep gate-forecourt service vendors must each stand AT a workplace vignette of
# existing kit props (not alone on grass). Anchors mirror server/world/data/npcs/npcs.json; the
# assertion is that the trade-defining prop sits within arm's reach of the vendor, and that no
# vignette prop is jammed inside the vendor's ~0.4m capsule.
func test_gate_vendors_stand_at_a_workplace_vignette() -> void:
	var stations := {
		# vendor anchor -> scene substrings that make the trade read from the silhouette
		"Weaponsmith Brannick": [Vector2(13.5, -104.5), ["prop_forge", "prop_anvil"]],
		"Innkeeper Doran": [Vector2(16.0, -106.0), ["prop_trestle_set", "prop_barrel"]],
		"Cook Berta": [Vector2(22.0, -108.0), ["prop_campfire", "prop_trestle_set"]],
	}
	for name in stations:
		var anchor: Vector2 = stations[name][0]
		var scenes: Array = stations[name][1]
		assert_lt(
			_nearest_t530(scenes, anchor),
			3.6,
			"%s has a trade-defining workplace prop within reach" % name
		)


func test_gate_guard_post_has_banner_and_brazier() -> void:
	# The wandering gate guards get a fixed post (banner + brazier) on the west verge, not bare field.
	var gate := Vector2(-6.8, -100.5)
	assert_lt(_nearest_t530(["prop_hk_banner_pole"], gate), 6.0, "guard post has a banner")
	assert_lt(_nearest_t530(["prop_brazier"], gate), 6.0, "guard post has a brazier")


func test_no_t530_prop_overlaps_a_vendor_capsule() -> void:
	# Props ring the vendor but leave the ~0.4m capsule clear so nobody spawns inside a barrel.
	var anchors := [
		Vector2(13.5, -104.5), Vector2(16.0, -106.0), Vector2(22.0, -108.0), Vector2(28.0, -108.0)
	]
	for p in _t530_props():
		if String(p.get("scene", "")).contains("_comment"):
			continue
		var pos := Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0)))
		for a in anchors:
			assert_gt(
				pos.distance_to(a),
				0.8,
				"t530 prop %s clears the vendor capsule at %s" % [p.get("scene", "?"), a]
			)


# T-673: the two purpose-built territory props T-629 flagged as missing. The bramble patch
# replaces the nettle stopgaps at both thorn ranges; the bone pile lands the "predator lives
# here" read at Greymaw's den. All are ground dressing: non-solid (T-617 elite escape-buffer —
# territory props must never narrow a pull line) and base-at-y0 drop-ins.
func _t673_props() -> Array:
	var out := []
	for p in _load_props():
		if p is Dictionary and String(p.get("tag", "")) == "t673":
			out.append(p)
	return out


func _count_near(props: Array, scene_substring: String, anchor: Vector2, radius: float) -> int:
	var n := 0
	for p in props:
		if not String(p.get("scene", "")).contains(scene_substring):
			continue
		if Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0))).distance_to(anchor) < radius:
			n += 1
	return n


func test_t673_brambles_dress_both_thorn_ranges() -> void:
	var props := _t673_props()
	for anchor in [Vector2(-30, -25), Vector2(-36, -30), Vector2(-50, -45)]:
		assert_gte(
			_count_near(props, "prop_bramble_patch", anchor, 5.0),
			2,
			"thorn range at %s has at least two bramble patches" % anchor
		)


func test_t673_bone_piles_mark_greymaw_den() -> void:
	assert_gte(
		_count_near(_t673_props(), "prop_bone_pile", Vector2(48, 40), 4.0),
		2,
		"Greymaw's den carries a kill-scatter of at least two bone piles"
	)


func test_t673_nettle_stopgaps_are_fully_swapped_out() -> void:
	# The nettle clumps were T-629's explicit stopgap for the missing bramble read; once the
	# purpose-built prop exists none may linger at the thorn-range anchors.
	for p in _load_props():
		if not (p is Dictionary and String(p.get("scene", "")).contains("prop_flora_nettle")):
			continue
		var pos := Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0)))
		for anchor in [Vector2(-30, -25), Vector2(-36, -30), Vector2(-50, -45)]:
			assert_gt(
				pos.distance_to(anchor as Vector2),
				6.0,
				"no nettle stopgap remains at thorn-range anchor %s" % anchor
			)


func test_t673_territory_props_stay_non_solid() -> void:
	var props := _t673_props()
	assert_gte(props.size(), 9, "T-673 dressing present (7 brambles + 2 bone piles)")
	for p in props:
		assert_false(
			bool(p.get("solid", true)),
			(
				"%s at (%s,%s) is non-solid (T-617 escape buffer: no narrowed pull lines)"
				% [p.get("scene", "?"), p.get("x", "?"), p.get("y", "?")]
			)
		)


func test_t673_glbs_are_ground_based_drop_ins() -> void:
	# Both new GLBs: base at y=0 (drop-in, no reseat) and territory-prop scale — the bramble
	# knee-to-waist, the bone pile a low ground scatter.
	var checks := {
		"res://assets/models/prop_bramble_patch.glb": [0.55, 1.1],
		"res://assets/models/prop_bone_pile.glb": [0.2, 0.7],
	}
	for path in checks:
		var inst: Node3D = (load(String(path)) as PackedScene).instantiate()
		autofree(inst)
		var aabb := _mesh_aabb(inst, inst.transform)
		assert_almost_eq(
			aabb.position.y, 0.0, 0.05, "%s base sits on the ground (no reseat)" % path
		)
		var lo: float = checks[path][0]
		var hi: float = checks[path][1]
		assert_between(aabb.size.y, lo, hi, "%s height fits its ground-prop read" % path)


func _mesh_aabb(node: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	var have := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var local := (node as MeshInstance3D).mesh.get_aabb()
		for i in range(8):
			var w: Vector3 = xf * local.get_endpoint(i)
			if not have:
				out = AABB(w, Vector3.ZERO)
				have = true
			else:
				out = out.expand(w)
	for ch in node.get_children():
		var ct: Transform3D = xf * (ch.transform if ch is Node3D else Transform3D.IDENTITY)
		var sub := _mesh_aabb(ch, ct)
		if sub.size != Vector3.ZERO or sub.position != Vector3.ZERO:
			out = out.merge(sub) if have else sub
			have = true
	return out


# T-619: the Ashmoor gaslamp socket must carry an OMNIDIRECTIONAL point light. T-346's 4.7
# upgrade attached an AreaLight3D — a one-sided panel emitter that fires along the node's -Z
# only — on a translation-only socket, so every High Street lamp read stone-cold at night
# while the omni-lit rift/hearth sockets in the same pass glowed.
func test_gaslamp_socket_gets_an_omnidirectional_dusk_gated_light() -> void:
	var layer = autofree(WorldPropsLayer.new())
	var placed = layer._place(
		{"scene": "res://assets/models/prop_ashmoor_gaslamp.glb", "x": 0.0, "y": 0.0}
	)
	assert_true(placed, "gaslamp prop loads")
	var lights := _socket_lights(layer, "socket_gaslamp")
	assert_eq(lights.size(), 1, "the gaslamp socket carries exactly one light")
	var l: Light3D = lights[0]
	assert_true(l is OmniLight3D, "gas glow is a point light, not a directional panel emitter")
	assert_gt((l as OmniLight3D).omni_range, 6.0, "the amber pool reaches the street")
	assert_true(l.is_in_group("night_lights"), "dusk-gated via the T-298 night tick")
	assert_almost_eq(l.light_energy, 0.0, 0.001, "off by day; WorldView drives it after dusk")
	assert_gt(float(l.get_meta("base_energy", 0.0)), 0.0, "carries its lit energy in meta")
	assert_false(l.shadow_enabled, "many small street lamps: no per-lamp shadow cost")


# T-632: the Highkeep cathedral nave must carry candle light down its FULL length. The audit
# found the altar glowing but the pews/aisle near-black: the two nave sockets hung too high
# (3.65m starves the floor by inverse-square) and too sparse (a 10m unlit hole mid-nave,
# nothing at the door end). The chain now runs door -> dais with no gap wider than one
# candle-tier pool radius (omni_range 8 in world_props_layer.gd).
func test_cathedral_nave_candle_chain_covers_door_to_dais() -> void:
	var layer = autofree(WorldPropsLayer.new())
	var placed = layer._place(
		{"scene": "res://assets/models/prop_hk_cathedral.glb", "x": 0.0, "y": 0.0}
	)
	assert_true(placed, "cathedral prop loads")
	var lights := _socket_lights(layer, "socket_candles")
	assert_gte(lights.size(), 7, "altar + both aisles + a full nave chain of candle sockets")
	# Anchors: the north door sits at z~+19, the altar socket at z~-15.4 (prop-local space).
	var chain_z := [19.2, -15.4]
	for l in lights:
		var sock := l.get_parent() as Node3D
		assert_gt(l.light_energy, 0.0, "interior candle tier is always-on (not dusk-gated)")
		assert_true(l is OmniLight3D, "candle tier is the proven omni socket light")
		if absf(sock.position.x) < 1.0 and sock.position.z > -15.0:
			chain_z.append(sock.position.z)  # centerline nave socket
			assert_lt(
				sock.position.y,
				3.0,
				"nave sockets sit at candle height so the pool reaches the pews/floor"
			)
	assert_gte(chain_z.size(), 6, "at least four centerline nave sockets between door and altar")
	chain_z.sort()
	var max_gap := 0.0
	for i in range(1, chain_z.size()):
		max_gap = maxf(max_gap, float(chain_z[i]) - float(chain_z[i - 1]))
	assert_lt(
		max_gap,
		8.0,
		"no stretch of nave longer than one candle pool radius (omni_range 8) goes unlit"
	)


# T-758: the socket->light allow-list. The old `else` catch-all in _place lit EVERY unmatched
# socket, so 67 non-light sockets glowed (55 of them shop signboards). socket_light_spec is now the
# single classifier: only the fire/candle/lamp families resolve to a spec; everything else is {} (no
# light). These assertions lock that an unknown/decorative socket gets NOTHING.
func test_unrecognized_socket_gets_no_light() -> void:
	for decorative in [
		"socket_sign",  # 55 shop signboards — the loudest offender
		"socket_sign_shop_left",
		"socket_sigil",  # the Grey Gull chalk circle
		"socket_service",  # the constabulary desk-sergeant NPC anchor
		"socket_cellar_stair",  # the Gull Cellars descent
		"socket_url",
		"socket_totally_unknown_marker",
	]:
		assert_true(
			WorldPropsLayer.socket_light_spec(decorative).is_empty(),
			"%s must resolve to NO light (the else catch-all is gone)" % decorative
		)


func test_interior_light_sockets_are_always_on() -> void:
	# Hearth + candle stay always-on (energy > 0, not dusk-gated) so interiors read by day and the
	# T-632 cathedral nave chain keeps its load-bearing omni_range 8.
	for interior in ["socket_hearth", "socket_hearth_c", "socket_candles", "socket_candles_nave"]:
		var spec := WorldPropsLayer.socket_light_spec(interior)
		assert_false(spec.is_empty(), "%s is a real interior light" % interior)
		assert_gt(float(spec.get("energy", 0.0)), 0.0, "%s is always-on interior fill" % interior)
		assert_false(bool(spec.get("night", false)), "%s is NOT dusk-gated" % interior)
	assert_almost_eq(
		float(WorldPropsLayer.socket_light_spec("socket_candles")["range"]),
		8.0,
		0.001,
		"candle pool radius stays 8 (T-632 nave coverage)"
	)


func test_fire_and_lamp_sockets_are_dusk_gated() -> void:
	# Gaslamp + brazier are EXTERIOR fire: dusk-gated (energy 0 by day, lit energy carried in the
	# night_lights meta). Brazier used to be an always-on candle under the catch-all — a wall brazier
	# blazing at noon; it now matches the standalone brazier prop.
	for exterior in ["socket_gaslamp", "socket_brazier", "socket_brazier_gate_1"]:
		var spec := WorldPropsLayer.socket_light_spec(exterior)
		assert_false(spec.is_empty(), "%s is a real exterior light" % exterior)
		assert_true(bool(spec.get("night", false)), "%s is dusk-gated" % exterior)
		assert_almost_eq(float(spec.get("energy", 0.0)), 0.0, 0.001, "%s dark by day" % exterior)
		assert_gt(
			float(spec.get("base_energy", 0.0)), 0.0, "%s carries lit energy in meta" % exterior
		)


func _socket_lights(layer: WorldPropsLayer, socket_prefix: String) -> Array:
	var out := []
	for n in layer.get_children():
		for c in n.find_children("socket_*", "Node3D", true, false):
			if String(c.name).begins_with(socket_prefix):
				for ch in c.get_children():
					if ch is Light3D:
						out.append(ch)
	return out


func _has_chimney_socket(layer: WorldPropsLayer) -> bool:
	for n in layer.get_children():
		for c in n.find_children("*", "Node3D", true, false):
			if c.is_in_group("chimney_sockets"):
				return true
	return false
