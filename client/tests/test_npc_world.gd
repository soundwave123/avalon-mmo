extends GutTest

# T-056: NPC bodies + !/? billboards + click-to-talk. Lifecycle, the !/? mapping, the click→intent
# handler, and the Perception gate (ADR 0009) are unit-tested; the billboard look is play-test.

const NpcWorldLayer = preload("res://scripts/world/npc_world_layer.gd")
const NpcMarker = preload("res://scripts/ui/npc_marker.gd")
const Perception = preload("res://scripts/world/perception.gd")
const SnapshotBuffer = preload("res://scripts/world/snapshot_buffer.gd")
const Relationship = preload("res://scripts/world/relationship.gd")


func _layer():
	var l = NpcWorldLayer.new()
	add_child_autofree(l)
	return l


func test_update_spawns_npc_with_billboard_and_remapped_position() -> void:
	var l = _layer()
	# T-559: (5,-6) is a flat-pad point — the old (5,6) fixture now sits on the training-yard
	# dry rise, so ground 0 only holds off the pad. The intent here is the coordinate REMAP.
	l.update([{"npc_id": "n1", "x": 5, "y": -6, "indicator": "!"}])
	assert_eq(l.npc_count(), 1)
	assert_eq(l.label_text("n1"), "!", "billboard shows the gold !")
	assert_eq(l.body_position("n1"), Vector3(5, 0, -6), "server (x,y) ground → Godot (x,0,y)")


func test_blank_indicator_hides_marker() -> void:
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": ""}])
	assert_eq(l.label_text("n1"), "", "no indicator → blank symbol")


func test_despawns_npc_no_longer_in_payload() -> void:
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": "!"}])
	assert_eq(l.npc_count(), 1)
	l.update([])
	assert_eq(l.npc_count(), 0, "NPC gone from payload → despawned")


func test_left_click_emits_npc_clicked() -> void:
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": "!"}])
	watch_signals(l)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	l._on_body_input("n1", ev)
	assert_signal_emitted_with_parameters(l, "npc_clicked", ["n1"])


# T-302b: a guard NPC gets a house-livery tabard attached to the chest bone; others do not.
func test_guard_gets_tabard_on_chest_bone() -> void:
	if not ResourceLoader.exists(NpcWorldLayer.TABARD_MESH):
		pass_test("tabard GLB not present in this checkout")
		return
	var l = _layer()
	l.update([{"npc_id": "g1", "x": 0, "y": 0, "indicator": "", "appearance": {"role": "guard"}}])
	var att := l.find_children("GuardTabard", "BoneAttachment3D", true, false)
	assert_eq(att.size(), 1, "guard wears exactly one tabard")
	var a: BoneAttachment3D = att[0]
	assert_eq(a.bone_name, "spine_02", "tabard rides the chest bone (weapon_socket precedent)")
	assert_true((a.get_parent() as Skeleton3D) != null, "attachment lives under the rig skeleton")
	assert_true(
		a.find_children("*", "MeshInstance3D", true, false).size() >= 1, "carries panel mesh"
	)
	# The tabard (authored in-place on the chest in skeleton space) is compensated by the chest
	# bone's rest inverse, so that once the live BoneAttachment applies the bone pose (rest * rest⁻¹
	# = identity at rest) the panels land exactly where authored. Verify that compensation directly
	# (deterministic; the live on-body placement is the pilot proof, which a headless frame can't run).
	var tabard: Node3D = a.get_child(0)
	var skel := a.get_parent() as Skeleton3D
	var expected := skel.get_bone_global_rest(skel.find_bone("spine_02")).affine_inverse()
	assert_true(
		tabard.transform.is_equal_approx(expected), "panel transform = chest-bone rest inverse"
	)


func test_non_guard_has_no_tabard() -> void:
	var l = _layer()
	l.update([{"npc_id": "p1", "x": 0, "y": 0, "indicator": "", "appearance": {"role": "peasant"}}])
	assert_eq(
		l.find_children("GuardTabard", "BoneAttachment3D", true, false).size(),
		0,
		"a peasant wears no livery tabard"
	)


func test_right_click_does_not_emit() -> void:
	var l = _layer()
	watch_signals(l)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = true
	l._on_body_input("n1", ev)
	assert_signal_not_emitted(l, "npc_clicked", "only left-click talks")


func test_marker_pixel_scale_clamps_close_and_far() -> void:
	# Mid-range → natural perspective (factor 1, proportionate to the NPC).
	assert_eq(
		NpcWorldLayer.marker_pixel_scale(20.0, 8.0, 40.0), 1.0, "natural perspective mid-range"
	)
	# Closer than near → factor < 1 caps the apparent size (no balloon when you walk up).
	assert_almost_eq(
		NpcWorldLayer.marker_pixel_scale(4.0, 8.0, 40.0), 0.5, 0.001, "capped up close"
	)
	# Farther than far → factor > 1 floors the apparent size (stays readable at distance).
	assert_almost_eq(
		NpcWorldLayer.marker_pixel_scale(80.0, 8.0, 40.0), 2.0, 0.001, "floored far away"
	)


# ---- T-664: tutorial quest-giver renders PRIMARY over side quest-givers ----


func test_tutorial_giver_marker_is_primary() -> void:
	# Drillmaster Hale gets BRIGHT_GOLD; Master-at-Arms Kessa (generic) stays standard GOLD.
	var hale_style := NpcMarker.marker_style("!", "npc_drillmaster")
	var kessa_style := NpcMarker.marker_style("!", "npc_trainer")
	assert_true(hale_style["color"] == NpcMarker.BRIGHT_GOLD, "tutorial giver → primary color")
	assert_true(kessa_style["color"] == NpcMarker.GOLD, "side quest giver → standard gold")


# T-668: the color delta alone was too subtle — the primary marker must also be measurably LARGER.
func test_tutorial_giver_marker_is_measurably_larger() -> void:
	var hale_style := NpcMarker.marker_style("!", "npc_drillmaster")
	var kessa_style := NpcMarker.marker_style("!", "npc_trainer")
	assert_gt(
		float(hale_style["scale"]),
		float(kessa_style["scale"]),
		"tutorial giver marker must render larger than a standard quest-giver marker"
	)
	assert_almost_eq(
		float(kessa_style["scale"]), 1.0, 0.001, "standard markers keep their natural size"
	)
	assert_gte(
		float(hale_style["scale"]) / float(kessa_style["scale"]),
		1.4,
		"the size delta must be unmistakable (>= 1.4x), not a subtle bump"
	)


func test_npc_world_layer_pixel_size_reflects_the_primary_marker_scale() -> void:
	var l = _layer()
	(
		l
		. update(
			[
				{"npc_id": "npc_drillmaster", "x": 0, "y": 0, "indicator": "!"},
				{"npc_id": "npc_trainer", "x": 0, "y": 0, "indicator": "!"},
			]
		)
	)
	var cam := Camera3D.new()
	add_child_autofree(cam)
	cam.global_position = Vector3(0, 2, 10)
	cam.look_at(Vector3(0, 1, 0))
	l._physics_process(0.016)  # T-753: the label-LOD pass moved to the physics callback
	var hale_size: float = l._npcs["npc_drillmaster"]["label"].pixel_size
	var kessa_size: float = l._npcs["npc_trainer"]["label"].pixel_size
	assert_gt(
		hale_size, kessa_size, "the tutorial giver's rendered marker is measurably larger on-screen"
	)


func test_marker_is_on_screen_for_a_facing_camera() -> void:  # reuse Perception (ADR 0009)
	var l = _layer()
	var cam := Camera3D.new()
	add_child_autofree(cam)
	cam.global_position = Vector3(0, 2, 6)
	cam.look_at(Vector3(0, 1, 0))
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": "!"}])
	await get_tree().process_frame
	assert_true(Perception.is_on_screen(cam, l.marker_position("n1")), "the NPC marker is in view")


# ---- T-076: trainer tint + nameplates ----


func test_npc_gets_nameplate_and_trainer_flag_styles() -> void:
	var layer := NpcWorldLayer.new()
	add_child_autofree(layer)
	(
		layer
		. update(
			[
				{"npc_id": "npc_a", "name": "Farmer Geld", "x": 1.0, "y": 2.0, "indicator": "!"},
				{
					"npc_id": "npc_t",
					"name": "Kessa",
					"x": 3.0,
					"y": 4.0,
					"indicator": "",
					"trainer": true,
				},
			]
		)
	)
	var named := 0
	for body in layer.get_children():
		for child in body.get_children():
			if child is Label3D and (child as Label3D).text in ["Farmer Geld", "Kessa"]:
				named += 1
	assert_eq(named, 2, "every NPC carries a nameplate")


# ---- T-311: ambient movement — interpolate live positions + walk/idle ----


func test_ingest_positions_creates_a_buffer_for_a_known_npc() -> void:
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": ""}])
	l.ingest_positions([{"npc_id": "n1", "x": 3.0, "y": 4.0}], 1000)
	var e: Dictionary = l._npcs["n1"]
	assert_not_null(e.get("buffer"), "a mover gets a SnapshotBuffer")
	assert_eq((e["buffer"] as SnapshotBuffer).size(), 1, "the live position was buffered")


func test_ingest_positions_ignores_unknown_npc() -> void:
	var l = _layer()  # no npc_indicators yet → no body to move
	l.ingest_positions([{"npc_id": "ghost", "x": 1.0, "y": 1.0}], 1000)
	assert_eq(l.npc_count(), 0, "positions for an unspawned NPC are ignored")


func test_indicators_do_not_teleport_a_mover() -> void:
	# Once a mover is buffered, the interpolator owns its position — a later npc_indicators post
	# must not snap the body back (that fight caused a visible stutter).
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": ""}])
	l.ingest_positions([{"npc_id": "n1", "x": 5.0, "y": 5.0}], 1000)
	(l._npcs["n1"]["body"] as Node3D).position = Vector3(5, 0, 5)
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": ""}])  # stale post
	assert_eq(
		(l._npcs["n1"]["body"] as Node3D).position,
		Vector3(5, 0, 5),
		"interpolator keeps the position"
	)


func test_process_animates_walk_over_a_moving_trail() -> void:
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": ""}])
	# Lay a dense position trail spanning past→future around render_t (now - 100 ms). As frames
	# advance, the interpolated sample walks along the trail → sustained movement → walk clip.
	var base := Time.get_ticks_msec()
	for k in range(16):
		l.ingest_positions([{"npc_id": "n1", "x": float(k) * 0.6, "y": 0.0}], base - 300 + k * 60)
	var saw_walk := false
	for i in range(20):
		await get_tree().process_frame
		if str(l._npcs["n1"].get("anim_state")) == "walk":
			saw_walk = true
	assert_true(saw_walk, "a moving position trail drives the walk animation")
	# Report #15 (moonwalk): the walker must FACE its +X travel. Hero rigs face +Z in-file and
	# _process yaws the body so body-local +Z tracks the walk direction, so the model's world +Z
	# is the visual's forward. The old 180° model flip drove this dot product to -1 (NPCs
	# translated one way while facing the other — the owner's "walking backwards" defect).
	var model: Node3D = l._npcs["n1"]["model"]
	var fwd: Vector3 = (model.global_transform.basis * Vector3(0, 0, 1)).normalized()
	assert_gt(fwd.x, 0.8, "visual forward tracks +X travel (fwd.x=%.2f, no moonwalk)" % fwd.x)


func test_process_stays_idle_for_a_stationary_npc() -> void:
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": ""}])
	# A single fixed position: the body settles there and never moves again → idle.
	l.ingest_positions([{"npc_id": "n1", "x": 5.0, "y": 0.0}], Time.get_ticks_msec())
	for i in range(8):
		await get_tree().process_frame
	assert_eq(l._npcs["n1"].get("anim_state"), "idle", "a stationary NPC holds the idle clip")


# ---- T-446: idle life — server facing drift + role act pulses ----


func test_act_state_maps_role_acts_to_existing_clips() -> void:
	assert_eq(NpcWorldLayer.act_state("hammer"), "attack", "smith work idle = the swing one-shot")
	assert_eq(NpcWorldLayer.act_state("pray"), "kneel", "clergy pray = kneel one-shot")
	assert_eq(NpcWorldLayer.act_state("gesture"), "point", "vendor gesture = point one-shot")
	assert_eq(NpcWorldLayer.act_state(""), "idle", "no pulse = plain idle")
	assert_eq(NpcWorldLayer.act_state("moonwalk"), "idle", "unknown act degrades to idle")


func test_ingest_positions_stores_facing_and_act() -> void:
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": ""}])
	l.ingest_positions([{"npc_id": "n1", "x": 0.0, "y": 0.0, "f": 1.57, "act": "hammer"}], 1000)
	var e: Dictionary = l._npcs["n1"]
	assert_almost_eq(float(e.get("srv_facing")), 1.57, 0.0001, "broadcast facing kept")
	assert_eq(str(e.get("act")), "hammer", "act pulse kept")
	l.ingest_positions([{"npc_id": "n1", "x": 0.0, "y": 0.0, "f": 1.57}], 1100)
	assert_eq(str(l._npcs["n1"].get("act")), "", "a row without act clears the pulse")


func test_stationary_npc_with_act_plays_the_mapped_one_shot() -> void:
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": ""}])
	l.ingest_positions(
		[{"npc_id": "n1", "x": 5.0, "y": 0.0, "f": 0.5, "act": "pray"}], Time.get_ticks_msec()
	)
	for i in range(8):
		await get_tree().process_frame
	assert_eq(str(l._npcs["n1"].get("anim_state")), "kneel", "act pulse drives the kneel one-shot")


func test_stationary_npc_turns_toward_the_broadcast_facing() -> void:
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": ""}])
	l.ingest_positions([{"npc_id": "n1", "x": 5.0, "y": 0.0, "f": 1.2}], Time.get_ticks_msec())
	var body: Node3D = l._npcs["n1"]["body"]
	body.rotation.y = 0.0
	for i in range(20):
		await get_tree().process_frame
	assert_gt(body.rotation.y, 0.3, "the idle facing drift turns the body (no frozen statue)")


# T-193: NPC name nameplates depth-test against world geometry (walls occlude them), unlike
# the quest !/? marker which stays always-on-top by design.
func test_npc_name_label_depth_tests() -> void:
	var l = _layer()
	var name_label: Label3D = l._make_name_label("Guard")
	assert_false(name_label.no_depth_test, "NPC name label depth-tests so walls occlude it")
	var marker: Label3D = l._make_label()
	assert_true(marker.no_depth_test, "the quest !/? marker stays always-on-top (unchanged)")


# ---- T-667: static NPC nameplate colour routes through Relationship, not hardcoded white ----


func test_npc_name_label_color_is_not_hardcoded_white() -> void:
	var l = _layer()
	var name_label: Label3D = l._make_name_label("Cleric Ansa")
	assert_true(
		name_label.modulate != Color(0.95, 0.95, 0.85),
		"nameplate colour must not fall back to the old hardcoded off-white"
	)


func test_npc_name_label_color_matches_the_relationship_picker() -> void:
	var l = _layer()
	var name_label: Label3D = l._make_name_label("Drillmaster Hale")
	var expected := Relationship.plate_color(Relationship.of({}, {}))
	assert_eq(
		name_label.modulate,
		expected,
		"a static NPC (never a mob, no peer/party/pvp facts) reads FRIENDLY via the T-665 picker"
	)


func test_npc_name_label_color_via_update_matches_remote_layer_friendly_green() -> void:
	var l = _layer()
	l.update([{"npc_id": "villager1", "x": 0, "y": 0, "indicator": "", "name": "Villager"}])
	assert_eq(
		l.name_label_for("villager1").modulate,
		Relationship.FRIENDLY_PLATE,
		"a plain villager reads the same friendly green a friendly player/mob nameplate gets"
	)


# ---- T-463: nameplate legibility + declutter (fade band, crowd stagger, hard outline) --------


func test_name_label_carries_a_hard_outline() -> void:
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": "", "name": "Scout Mira"}])
	var label: Label3D = l.name_label_for("n1")
	assert_gte(label.outline_size, 8, "outline carries the legibility over bright grass/sky")
	assert_almost_eq(
		label.outline_modulate.a, 0.95, 0.01, "outline is explicitly near-opaque black"
	)
	assert_eq(label.outline_modulate.r, 0.0, "outline is black, not the default-dependent value")


func test_name_lod_fades_with_distance() -> void:
	var l = _layer()
	(
		l
		. update(
			[
				{"npc_id": "near", "x": 0, "y": 0, "indicator": "", "name": "Near"},
				{"npc_id": "far", "x": 100, "y": 0, "indicator": "", "name": "Far"},
			]
		)
	)
	l._apply_name_lod(Vector3.ZERO)  # camera at origin
	assert_eq(l.name_label_for("near").modulate.a, 1.0, "inside the band -> fully readable")
	assert_true(l.name_label_for("near").visible)
	assert_eq(l.name_label_for("far").modulate.a, 0.0, "past the band -> faded out")
	assert_false(l.name_label_for("far").visible, "fully faded plates stop rendering entirely")


func test_name_lod_staggers_a_bunched_crowd() -> void:
	var l = _layer()
	(
		l
		. update(
			[
				{"npc_id": "a", "x": 0, "y": 0, "indicator": "", "name": "A"},
				{"npc_id": "b", "x": 0.5, "y": 0, "indicator": "", "name": "B"},
				{"npc_id": "c", "x": 0.2, "y": 0.3, "indicator": "", "name": "C"},
				{"npc_id": "d", "x": 0.4, "y": 0.4, "indicator": "", "name": "D"},
			]
		)
	)
	l._apply_name_lod(Vector3(0, 1.6, 5))
	var heights := {}
	for id in ["a", "b", "c", "d"]:
		var h: float = l.name_label_for(id).position.y
		assert_false(heights.has(h), "no two bunched plates share a height (id %s)" % id)
		heights[h] = true
	assert_eq(
		l.name_label_for("a").position.y,
		NpcWorldLayer.NAME_BASE_HEIGHT,
		"first plate of the bunch sits at rest height"
	)


func test_name_lod_respects_the_labels_hidden_toggle() -> void:
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": "", "name": "Scout"}])
	l.set_labels_visible(false)
	l._apply_name_lod(Vector3.ZERO)
	assert_false(l.name_label_for("n1").visible, "T-227 toggle wins over the LOD rule")


func test_npc_body_is_off_the_default_physics_layer() -> void:  # T-656
	var l = _layer()
	l.update([{"npc_id": "n1", "x": 0, "y": 0, "indicator": "!"}])
	assert_eq(
		l.body_for("n1").collision_layer,
		2,
		(
			"NPC body must NOT be on layer 1 — standing point-blank next to a quest-giver/vendor"
			+ " shouldn't jam the follow camera's SpringArm3D probe into them either (T-656)"
		)
	)
