extends GutTest

# T-055: the remote-entity lifecycle (spawn/despawn from the broadcast) + the axis remap are
# headless-testable; snapshot interpolation is covered separately and the visual is play-tested.

const RemoteEntitiesLayer = preload("res://scripts/world/remote_entities_layer.gd")
const TargetSelection = preload("res://scripts/world/target_selection.gd")


func _layer():
	var l = RemoteEntitiesLayer.new()
	add_child_autofree(l)
	return l


func test_ingest_spawns_players_and_mobs_excluding_local() -> void:
	var l = _layer()
	(
		l
		. ingest(
			{
				"players":
				[{"peer_id": 1, "x": 5, "y": 6, "z": 0}, {"peer_id": 99, "x": 0, "y": 0, "z": 0}],
				"mobs": [{"mob_id": 1001, "x": 10, "y": 10, "z": 0}],
			},
			99,
			1000
		)
	)
	assert_eq(l.entity_count(), 2, "player 1 + mob 1001 (local peer 99 excluded)")
	assert_true(l.has_entity("player_1"))
	assert_true(l.has_entity("mob_1001"))
	assert_false(l.has_entity("player_99"), "the local player is not a remote entity")


func test_player_count_excludes_mobs() -> void:
	var l = _layer()
	l.ingest(
		{
			"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0}],
			"mobs": [{"mob_id": 9, "x": 0, "y": 0, "z": 0}]
		},
		99,
		1000
	)
	assert_eq(l.entity_count(), 2, "1 player + 1 mob")
	assert_eq(
		l.player_count(), 1, "player_count counts only other players (the harness asserts this)"
	)


func test_despawns_entities_no_longer_in_broadcast() -> void:
	var l = _layer()
	l.ingest({"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0}], "mobs": []}, 99, 1000)
	assert_eq(l.entity_count(), 1)
	l.ingest({"players": [], "mobs": []}, 99, 1100)  # player 1 left
	assert_eq(l.entity_count(), 0, "stale entity despawned")


func test_ingest_remaps_axes_into_the_buffer() -> void:
	var l = _layer()
	l.ingest({"players": [{"peer_id": 1, "x": 5, "y": 6, "z": 2}], "mobs": []}, 99, 1000)
	# server (5, 6 ground, 2 height) → Godot (5, 2, 6); single snapshot → sample returns it.
	assert_eq(
		l.buffer_for("player_1").sample(9999), Vector3(5, 2, 6), "axes remapped (x,y,z → x,z,y)"
	)


func test_left_click_emits_entity_clicked() -> void:  # T-057: click a mob → target it
	var l = _layer()
	l.ingest(
		{"players": [], "mobs": [{"mob_id": 1001, "x": 0, "y": 0, "z": 0, "hp": 50}]}, 99, 1000
	)
	watch_signals(l)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	l._on_entity_input(1001, ev)
	assert_signal_emitted_with_parameters(l, "entity_clicked", [1001])
	assert_eq(
		TargetSelection.target_id_for_collider(l.get("_entities"), l.node_for("mob_1001")),
		1001,
		"the ray-pick collider resolves to the same server entity id"
	)


func test_tab_cycles_nearest_living_mobs() -> void:
	var l = _layer()
	(
		l
		. ingest(
			{
				"players": [{"peer_id": 7, "x": 1, "y": 0, "z": 0, "hp": 100, "max_hp": 100}],
				"mobs":
				[
					{"mob_id": 1001, "x": 4, "y": 0, "z": 0, "hp": 50, "max_hp": 50},
					{"mob_id": 1002, "x": 9, "y": 0, "z": 0, "hp": 50, "max_hp": 50},
					{"mob_id": 1003, "x": 2, "y": 0, "z": 0, "hp": 0, "max_hp": 50},
				],
			},
			99,
			1000
		)
	)
	# Force the render roots to the authoritative snapshot positions; _process normally does this.
	l.node_for("mob_1001").global_position = Vector3(4, 0, 0)
	l.node_for("mob_1002").global_position = Vector3(9, 0, 0)
	l.node_for("mob_1003").global_position = Vector3(2, 0, 0)
	var entities: Dictionary = l.get("_entities")
	assert_eq(
		TargetSelection.next_hostile_target(entities, -1, Vector3.ZERO),
		1001,
		"TAB starts at the nearest living mob"
	)
	assert_eq(
		TargetSelection.next_hostile_target(entities, 1001, Vector3.ZERO),
		1002,
		"TAB advances to the next mob"
	)
	assert_eq(
		TargetSelection.next_hostile_target(entities, 1002, Vector3.ZERO),
		1001,
		"TAB wraps deterministically"
	)


func test_has_target_and_target_node() -> void:  # T-057 / T-343
	var l = _layer()
	l.ingest(
		{"players": [], "mobs": [{"mob_id": 1001, "x": 5, "y": 6, "z": 0}]},
		99,
		Time.get_ticks_msec()
	)
	assert_true(l.has_target(1001), "known mob is a valid target")
	assert_false(l.has_target(999), "unknown id is not")
	await get_tree().process_frame  # _process samples the interpolation buffer
	assert_not_null(l.target_node(1001), "known target has a node")
	assert_null(l.target_node(999), "unknown target → null")


# ---- T-060: 3D floating damage numbers ----


func _layer_with_mob():
	var l = _layer()
	l.ingest({"players": [], "mobs": [{"mob_id": 1001, "x": 10, "y": 10, "z": 0}]}, 99, 1000)
	return l


func test_spawn_damage_number_creates_styled_label() -> void:
	var layer = _layer_with_mob()
	layer.spawn_damage_number(1001, 14, "hit")
	layer.spawn_damage_number(1001, 40, "crit")
	layer.spawn_damage_number(1001, 9, "heal")
	assert_eq(layer.damage_number_count(), 3, "one Label3D per event")
	var labels: Array = []
	for child in layer.get_children():
		if child is Label3D:
			labels.append(child)
	assert_eq(labels[0].text, "-14")
	assert_eq(labels[1].text, "-40!")
	assert_eq(labels[2].text, "+9")
	assert_true(labels[1].font_size > labels[0].font_size, "crit renders bigger")


func test_spawn_damage_number_unknown_target_is_noop() -> void:
	var layer = _layer_with_mob()
	layer.spawn_damage_number(99999, 5, "hit")
	assert_eq(layer.damage_number_count(), 0, "no anchor, no label")


# T-255: pooling — an AoE-volume burst must not allocate one Label3D per hit.
func test_damage_number_pool_does_not_grow_past_pool_size() -> void:
	var layer = _layer_with_mob()
	var pool_size := layer.damage_number_pool_size()  # 0 until first use
	var hit_count := 40  # > DAMAGE_NUMBER_POOL_SIZE
	for i in range(hit_count):
		layer.spawn_damage_number(1001, i + 1, "hit")
	pool_size = layer.damage_number_pool_size()
	assert_true(pool_size > 0, "pool built on first use")
	assert_true(pool_size < hit_count, "pool is far smaller than the hit volume it absorbed")
	var label3d_children := 0
	for child in layer.get_children():
		if child is Label3D:
			label3d_children += 1
	assert_eq(label3d_children, pool_size, "no per-hit node growth — same fixed set of nodes")


func test_damage_number_pool_reuses_the_same_node_instances() -> void:
	var layer = _layer_with_mob()
	layer.spawn_damage_number(1001, 1, "hit")
	var first_label
	for child in layer.get_children():
		if child is Label3D:
			first_label = child
			break
	var pool_size := layer.damage_number_pool_size()
	# Wrap all the way around the ring back to the same slot.
	for i in range(pool_size):
		layer.spawn_damage_number(1001, i + 1, "hit")
	var reused := false
	for child in layer.get_children():
		if child is Label3D and child == first_label and child.visible:
			reused = true
	assert_true(reused, "the ring wraps back to the same node instance instead of allocating")


func test_spawn_damage_number_crit_is_gold_and_bigger() -> void:
	var layer = _layer_with_mob()
	layer.spawn_damage_number(1001, 40, "crit")
	var crit_label: Label3D = null
	for child in layer.get_children():
		if child is Label3D and (child as Label3D).visible:
			crit_label = child
	assert_not_null(crit_label)
	assert_eq(crit_label.modulate, Color(1.0, 0.82, 0.15, 1.0), "crit renders gold")
	assert_true(crit_label.font_size >= 96, "crit is ~1.6x the base size")


# T-402 item-3 polish (hud-judge): the out_of_range error float must pop to full opacity fast then
# hold, not fade linearly from frame 0. The envelope zeroes alpha at spawn and eases it UP — so at
# spawn (before any process tick) the out_of_range float reads alpha 0 (ramp-in pending), while an
# ordinary hit keeps full alpha immediately. Text + color unchanged.
func test_out_of_range_float_uses_pop_then_hold_fade_envelope() -> void:
	var layer = _layer_with_mob()
	layer.spawn_damage_number_at(Vector3.ZERO, 0, "out_of_range")
	var oor: Label3D = null
	for child in layer.get_children():
		if child is Label3D and (child as Label3D).visible:
			oor = child
	assert_not_null(oor)
	assert_eq(oor.text, "out of range", "error read text unchanged")
	assert_eq(oor.modulate.r, 1.0, "red-orange error color unchanged (r)")
	assert_eq(
		oor.modulate.a, 0.0, "alpha zeroed at spawn — ease-in ramps it up fast (pop, not linear)"
	)


func test_hit_float_keeps_full_alpha_at_spawn() -> void:
	# Guard: the pop-in envelope is out_of_range-only — ordinary damage numbers stay full-alpha
	# from frame 0 (their linear fade is unchanged).
	var layer = _layer_with_mob()
	layer.spawn_damage_number(1001, 12, "hit")
	var hit: Label3D = null
	for child in layer.get_children():
		if child is Label3D and (child as Label3D).visible:
			hit = child
	assert_not_null(hit)
	assert_eq(hit.modulate.a, 1.0, "hit numbers are full-alpha immediately (linear fade path)")


# ---- TD-004 F2: no red 0/1 bar on an entity without real resources ----


func test_missing_resources_hides_the_health_bar() -> void:
	var l = _layer()
	l.ingest({"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0, "hp": 0, "max_hp": 0}]}, 99, 1000)
	assert_not_null(l.hp_bar_for("player_1"))
	assert_false(
		l.hp_bar_for("player_1").visible,
		"max_hp 0 hides the bar (never a red 0/1 on a living player)"
	)
	# Real resources arriving later restore the bar.
	l.ingest(
		{"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0, "hp": 80, "max_hp": 100}]}, 99, 2000
	)
	assert_true(l.hp_bar_for("player_1").visible)
	assert_eq(l.hp_bar_for("player_1").get_node("hp_text").text, "80/100")


# ---- T-178: WoW nameplate visibility rule (off unless damaged or targeted, culled past 25 m) ----


func _ingest_one_player(l, hp: int, max_hp: int) -> void:
	l.ingest(
		{
			"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0, "hp": hp, "max_hp": max_hp}],
			"mobs": []
		},
		99,
		Time.get_ticks_msec()
	)


func test_full_health_untargeted_label_is_hidden() -> void:
	var l = _layer()
	_ingest_one_player(l, 100, 100)
	assert_false(
		l.hp_bar_for("player_1").visible, "full-health + untargeted plate is off (WoW default)"
	)


func test_damaged_label_is_shown() -> void:
	var l = _layer()
	_ingest_one_player(l, 60, 100)
	assert_true(l.hp_bar_for("player_1").visible, "a damaged entity shows its plate")
	assert_eq(l.hp_bar_for("player_1").get_node("hp_text").text, "60/100", "styling/text preserved")


func test_full_health_targeted_label_is_shown() -> void:
	var l = _layer()
	_ingest_one_player(l, 100, 100)
	l.set_target(1)  # peer_id 1 == target_id of player_1
	assert_true(l.hp_bar_for("player_1").visible, "the selected target shows even at full health")


func test_deselecting_hides_the_full_health_label() -> void:
	var l = _layer()
	_ingest_one_player(l, 100, 100)
	l.set_target(1)
	assert_true(l.hp_bar_for("player_1").visible, "targeted full-health plate is on")
	l.set_target(-1)  # deselect
	assert_false(l.hp_bar_for("player_1").visible, "deselecting hides the full-health plate again")


func test_distance_cull_hides_far_damaged_entity() -> void:
	var l = _layer()
	var cam := Camera3D.new()
	add_child_autofree(cam)
	cam.current = true  # get_viewport().get_camera_3d() now returns this
	cam.global_position = Vector3.ZERO
	# Spawn a damaged player far away; one _process frame lands its node at the real position.
	l.ingest(
		{
			"players": [{"peer_id": 1, "x": 100, "y": 0, "z": 0, "hp": 60, "max_hp": 100}],
			"mobs": []
		},
		99,
		Time.get_ticks_msec()
	)
	await get_tree().process_frame
	# Re-ingest so the visibility rule re-runs with the node now 100 m from the camera.
	l.ingest(
		{
			"players": [{"peer_id": 1, "x": 100, "y": 0, "z": 0, "hp": 60, "max_hp": 100}],
			"mobs": []
		},
		99,
		Time.get_ticks_msec()
	)
	assert_false(
		l.hp_bar_for("player_1").visible, "damaged but >25 m away is culled despite being damaged"
	)


# ---- T-125: stationary combat facing (square up to what you act on; movement always wins) ----
# These drive _process(0.1) directly instead of awaiting real frames: at delta 0.1 the facing lerp
# factor minf(10*delta, 1) == 1, so one tick snaps rotation exactly onto the goal — fully
# deterministic (no dependence on the harness's real frame delta) and single-snapshot sampling is
# position-exact regardless of wall-clock render time.


func test_face_target_turns_a_stationary_actor_toward_its_target() -> void:
	var l = _layer()
	# Actor at the origin (never moves → planar 0); target out at +x. T-727: a body yaw that points
	# the visual's forward (-Z) at +x is atan2(-1, -0) = -PI/2 (this asserted +PI/2 before the fix,
	# i.e. it locked in the back-to-the-target inversion T-727 found on the movement path).
	l.ingest(
		{
			"players": [],
			"mobs": [{"mob_id": 1, "x": 0, "y": 0, "z": 0}, {"mob_id": 2, "x": 10, "y": 0, "z": 0}]
		},
		99,
		Time.get_ticks_msec()
	)
	l._process(0.1)  # settle the nodes onto their positions
	l.face_target(1, 2)
	l._process(0.1)  # stationary → the combat goal snaps the actor around (lerp factor 1)
	assert_almost_eq(
		l.node_for("mob_1").rotation.y,
		-PI / 2.0,
		0.001,
		"a standing actor turns to face its target (combat goal yaw = -PI/2)"
	)


func test_face_target_is_ignored_while_the_actor_is_moving() -> void:
	var l = _layer()
	# Settle the target first so face_target reads a real position (target at +z → goal yaw PI).
	l.ingest(
		{"players": [], "mobs": [{"mob_id": 2, "x": 0, "y": 10, "z": 0}]}, 99, Time.get_ticks_msec()
	)
	l._process(0.1)
	# Spawn the actor fresh out at +x: its next tick is a big origin→(10,0,0) jump, i.e. moving.
	l.ingest(
		{
			"players": [],
			"mobs": [{"mob_id": 2, "x": 0, "y": 10, "z": 0}, {"mob_id": 1, "x": 10, "y": 0, "z": 0}]
		},
		99,
		Time.get_ticks_msec()
	)
	l.face_target(1, 2)  # combat goal yaw PI; movement facing (travel yaw -PI/2) must win
	l._process(0.1)
	assert_almost_eq(
		l.node_for("mob_1").rotation.y,
		-PI / 2.0,
		0.001,
		"a moving actor faces travel (yaw -PI/2), ignoring the combat goal (yaw PI)"
	)


func test_face_target_with_unknown_ids_is_a_noop() -> void:
	var l = _layer()
	l.ingest(
		{"players": [], "mobs": [{"mob_id": 1, "x": 0, "y": 0, "z": 0}]}, 99, Time.get_ticks_msec()
	)
	l._process(0.1)
	var before: float = l.node_for("mob_1").rotation.y
	l.face_target(1, 999)  # known actor, unknown target
	l.face_target(999, 1)  # unknown actor, known target
	l.face_target(999, 888)  # both unknown
	l._process(0.1)
	assert_eq(
		l.node_for("mob_1").rotation.y, before, "unknown-id face_target neither rotates nor crashes"
	)


# ---- T-123: trigger_action wires AnimStateMachine into the real baked-clip AnimationPlayer.
# "player_1" (no char_class) falls back to the "player" GLB kind, which loads the real
# char_hero_warrior.glb (T-118 baked clips) — so these assertions read the ACTUAL AnimationPlayer,
# not just the pure module (that's test_anim_state_machine.gd's job). ----


func test_trigger_action_attack_plays_the_baked_swing_clip() -> void:
	var l = _layer()
	l.ingest({"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0}], "mobs": []}, 99, 1000)
	l.trigger_action(1, "attack")
	var ap := (l.node_for("player_1") as Node3D).find_child("AnimationPlayer", true, false)
	assert_not_null(ap, "the baked hero GLB carries an AnimationPlayer")
	assert_true(
		(ap as AnimationPlayer).current_animation in EntityVisuals.STATE_CLIPS["attack"],
		"attack resolved to a baked swing clip"
	)


func test_trigger_action_death_outranks_a_later_hit() -> void:
	var l = _layer()
	l.ingest({"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0}], "mobs": []}, 99, 1000)
	l.trigger_action(1, "death")
	var ap := (l.node_for("player_1") as Node3D).find_child("AnimationPlayer", true, false)
	assert_true((ap as AnimationPlayer).current_animation in EntityVisuals.STATE_CLIPS["death"])
	l.trigger_action(1, "hit")  # T-123 priority matrix: hit(2) cannot outrank death(3)
	assert_true(
		(ap as AnimationPlayer).current_animation in EntityVisuals.STATE_CLIPS["death"],
		"death still sticks after a later hit event"
	)


func test_trigger_action_respawn_clears_death_back_to_idle() -> void:
	var l = _layer()
	l.ingest({"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0}], "mobs": []}, 99, 1000)
	l.trigger_action(1, "death")
	l.trigger_action(1, "respawn")
	var ap := (l.node_for("player_1") as Node3D).find_child("AnimationPlayer", true, false)
	assert_true(
		(ap as AnimationPlayer).current_animation in EntityVisuals.STATE_CLIPS["idle"],
		"respawn released the corpse pose back to idle"
	)


func test_trigger_action_unknown_actor_is_a_safe_noop() -> void:
	var l = _layer()
	l.trigger_action(9999, "attack")  # no such entity — must not error or crash
	assert_eq(l.entity_count(), 0, "no entity was spawned as a side effect")


# ---- T-307: procedural combat motion for clipless creatures. mob_wolf carries only idle/walk, so
# attack/hit/death resolve to NO clip and get a CombatMotion lunge/recoil/topple stand-in instead
# of freezing in idle. The hero, which HAS the baked clips, must NOT get a procedural stand-in. ----


func _layer_with_wolf():
	var l = _layer()
	var wolf := {"mob_id": 1001, "kind": "mob_wolf", "x": 0, "y": 0, "z": 0}
	l.ingest({"players": [], "mobs": [wolf]}, 99, 1000)
	return l


func test_attack_on_a_clipless_creature_starts_a_procedural_lunge() -> void:
	var l = _layer_with_wolf()
	l.trigger_action(1001, "attack")
	var proc := l._proc_for("mob_1001")
	assert_eq(proc.get("event", ""), "attack", "the clipless wolf gets a procedural attack motion")
	# Force the motion to its peak and drive one frame: the silhouette lunges forward (-Z).
	proc["start"] = Time.get_ticks_msec() / 1000.0 - l.CombatMotion.LUNGE_DURATION * 0.30
	l._process(0.05)
	assert_lt(
		l._visual_for("mob_1001").position.z, -0.2, "the wolf body surges forward on the swing"
	)


func test_hero_attack_uses_the_baked_clip_not_a_procedural_stand_in() -> void:
	var l = _layer()
	l.ingest({"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0}], "mobs": []}, 99, 1000)
	l.trigger_action(1, "attack")
	assert_true(
		l._proc_for("player_1").is_empty(),
		"a hero resolves Sword_Attack — no procedural motion (that path is clipless-only)"
	)


func test_death_topples_a_clipless_creature_and_respawn_restores_it() -> void:
	var l = _layer_with_wolf()
	l.trigger_action(1001, "death")
	var proc := l._proc_for("mob_1001")
	assert_eq(proc.get("event", ""), "death", "a killed clipless wolf gets a procedural topple")
	# Past the collapse window: the corpse holds a pitched-over prone pose (does not stand).
	proc["start"] = Time.get_ticks_msec() / 1000.0 - l.CombatMotion.COLLAPSE_DURATION - 1.0
	l._process(0.05)
	assert_almost_eq(
		l._visual_for("mob_1001").rotation.x,
		l.CombatMotion.COLLAPSE_PITCH,
		0.01,
		"the corpse holds its toppled pose (no blink-out, no standing idle)"
	)
	assert_false(l._proc_for("mob_1001").is_empty(), "death motion is held, not released")
	# Respawn clears the topple and stands the silhouette back upright at rest.
	l.trigger_action(1001, "respawn")
	assert_true(l._proc_for("mob_1001").is_empty(), "respawn drops the corpse pose")
	assert_almost_eq(l._visual_for("mob_1001").rotation.x, 0.0, 0.001, "back upright")
	assert_almost_eq(l._visual_for("mob_1001").position.z, 0.0, 0.001, "back at rest position")


func test_cast_broadcast_drives_the_cast_pose_for_a_remote_entity() -> void:
	var l = _layer()
	l.ingest(
		{
			"players":
			[{"peer_id": 1, "x": 0, "y": 0, "z": 0, "cast": {"total_s": 1.0, "remaining_s": 1.0}}],
			"mobs": []
		},
		99,
		1000
	)
	l._process(0.05)
	var ap := (l.node_for("player_1") as Node3D).find_child("AnimationPlayer", true, false)
	assert_true(
		(ap as AnimationPlayer).current_animation in EntityVisuals.STATE_CLIPS["cast"],
		"a live cast broadcast (T-266 cast bar truth) drives the cast pose"
	)


# ---- T-254: the health bar is a real fill quad (width tracks the hp fraction) ----


func test_health_bar_fill_tracks_fraction() -> void:
	var l = _layer()
	_ingest_one_player(l, 25, 100)  # quarter health
	var fill := l.hp_bar_for("player_1").get_node("hp_fill") as MeshInstance3D
	var quad := fill.mesh as QuadMesh
	assert_almost_eq(quad.size.x, l.HP_BAR_W * 0.25, 0.001, "fill width is 25% of the backdrop")
	# left-anchored: the left edge stays at -W/2 as it shrinks
	assert_almost_eq(
		quad.center_offset.x, -l.HP_BAR_W * 0.75 / 2.0, 0.001, "fill left-anchors (WoW read)"
	)
	# T-286: color is by RELATIONSHIP, not hp — a friendly player stays green even at 25% hp
	# (depletion is shown by the shrinking width above, the WoW read).
	var col: Color = (fill.material_override as StandardMaterial3D).albedo_color
	assert_true(col.g > col.r, "a friendly plate is green regardless of health")


# ---- T-227: nameplate toggle hides all plates (and new ones spawned while hidden) ----


func test_nameplate_toggle_hides_and_restores() -> void:
	var l = _layer()
	_ingest_one_player(l, 60, 100)  # damaged -> plate would be visible
	assert_true(l.hp_bar_for("player_1").visible, "damaged plate on by default")
	l.set_labels_visible(false)
	assert_false(l.hp_bar_for("player_1").visible, "toggle hides the plate")
	# a NEW damaged entity spawned while hidden must stay hidden (keep player_1 present —
	# ingest despawns anyone absent from the broadcast).
	l.ingest(
		{
			"players":
			[
				{"peer_id": 1, "x": 0, "y": 0, "z": 0, "hp": 60, "max_hp": 100},
				{"peer_id": 2, "x": 1, "y": 1, "z": 0, "hp": 30, "max_hp": 100}
			]
		},
		99,
		Time.get_ticks_msec()
	)
	assert_false(l.hp_bar_for("player_2").visible, "new plate respects the hidden state")
	l.set_labels_visible(true)
	assert_true(l.hp_bar_for("player_1").visible, "toggle restores the damaged plate")


# ---- T-266: nameplate cast bars (HOSTILE only, WoW visibility) ----


func test_hostile_mob_cast_shows_bar() -> void:
	var l = _layer()
	(
		l
		. ingest(
			{
				"players": [],
				"mobs":
				[
					{
						"mob_id": 1001,
						"x": 5,
						"y": 6,
						"z": 0,
						"cast": {"ability_id": 3, "remaining_s": 1.0, "total_s": 2.0},
					}
				],
			},
			99,
			Time.get_ticks_msec()
		)
	)
	await get_tree().process_frame  # _process drives the cast bar
	var bar := l.cast_bar_for("mob_1001")
	assert_true(bar.visible, "a casting mob (HOSTILE) shows a nameplate cast bar")
	var frac := (bar.get_node("cast_fill").mesh as QuadMesh).size.x / 1.0  # CAST_BAR_W
	assert_almost_eq(frac, 0.5, 0.02, "fill = (total-remaining)/total")


func test_idle_mob_has_no_cast_bar() -> void:
	var l = _layer()
	l.ingest({"players": [], "mobs": [{"mob_id": 1001, "x": 5, "y": 6, "z": 0}]}, 99, 1000)
	await get_tree().process_frame
	assert_false(l.cast_bar_for("mob_1001").visible, "a mob not casting shows no cast bar")


func test_friendly_player_cast_is_hidden() -> void:
	# WoW rule (M8 correction): friendly/party nameplate cast bars are OFF. A remote player
	# with no PvP flag is FRIENDLY, so their cast must NOT render on the nameplate.
	var l = _layer()
	(
		l
		. ingest(
			{
				"players":
				[
					{
						"peer_id": 7,
						"x": 1,
						"y": 1,
						"z": 0,
						"cast": {"ability_id": 3, "remaining_s": 1.0, "total_s": 2.0},
					}
				],
				"mobs": [],
			},
			99,
			Time.get_ticks_msec()
		)
	)
	await get_tree().process_frame
	assert_false(l.cast_bar_for("player_7").visible, "friendly player cast is hidden (WoW)")


# ---- T-286: nameplate colors by relationship + target highlight ----


func test_hostile_mob_plate_is_red_and_neutral_is_yellow() -> void:
	var l = _layer()
	var mob := {"mob_id": 1001, "x": 5, "y": 6, "z": 0, "hp": 50, "max_hp": 100}
	l.ingest({"players": [], "mobs": [mob]}, 99, 1000)
	var mat := (
		(l.hp_bar_for("mob_1001").get_node("hp_fill").material_override) as StandardMaterial3D
	)
	assert_true(mat.albedo_color.r > mat.albedo_color.g, "a hostile mob plate is red")
	mob["hostile"] = false
	l.ingest({"players": [], "mobs": [mob]}, 99, 1100)
	assert_eq(mat.albedo_color, Relationship.NEUTRAL_PLATE, "a neutral mob plate is yellow")


func test_friendly_plate_green_then_class_color() -> void:
	var l = _layer()
	(
		l
		. ingest(
			{
				"players":
				[
					{
						"peer_id": 7,
						"username": "Ally",
						"x": 1,
						"y": 1,
						"z": 0,
						"hp": 80,
						"max_hp": 100,
						"char_class": "warrior"
					}
				],
				"mobs": [],
			},
			99,
			1000
		)
	)
	var mat := (
		(l.hp_bar_for("player_7").get_node("hp_fill").material_override) as StandardMaterial3D
	)
	assert_true(mat.albedo_color.g > mat.albedo_color.r, "a friendly plate is green by default")
	var name_label := l.hp_bar_for("player_7").get_node("name_text") as Label3D
	assert_eq(name_label.text, "Ally", "the relationship-colored player name is present")
	assert_eq(name_label.modulate, Relationship.FRIENDLY_PLATE, "friendly player name is green")
	l.set_class_color_plates(true)
	assert_eq(
		mat.albedo_color,
		EntityVisuals.CLASS_COLORS["warrior"],
		"class-color toggle recolors friendly"
	)


func test_target_highlight_enlarges_the_plate() -> void:
	var l = _layer()
	(
		l
		. ingest(
			{
				"players": [],
				"mobs":
				[
					{"mob_id": 1, "x": 1, "y": 1, "z": 0, "hp": 50, "max_hp": 100},
					{"mob_id": 2, "x": 2, "y": 2, "z": 0, "hp": 50, "max_hp": 100},
				],
			},
			99,
			1000
		)
	)
	l.set_target(1)
	assert_almost_eq(l.hp_bar_for("mob_1").scale.x, 1.48, 0.01, "targeted plate is strongest")
	assert_almost_eq(l.hp_bar_for("mob_2").scale.x, 1.18, 0.01, "damaged plate is promoted")
	l.set_target(2)
	assert_almost_eq(l.hp_bar_for("mob_1").scale.x, 1.18, 0.01, "deselected damage stays legible")


# ---- T-294: elite nameplate treatment (gold, star-framed name; normal mobs plain grey) ----


func test_elite_mob_name_is_gold_and_star_framed() -> void:
	var l = _layer()
	(
		l
		. ingest(
			{
				"players": [],
				"mobs":
				[
					{
						"mob_id": 1901,
						"kind": "mob_wolf",
						"name": "Greymaw the Alpha",
						"elite": true,
						"x": 5,
						"y": 6,
						"z": 0,
						"hp": 400,
						"max_hp": 400,
					}
				],
			},
			99,
			1000
		)
	)
	var label := l.hp_bar_for("mob_1901").get_node("name_text") as Label3D
	assert_not_null(label, "the elite has a name label")
	assert_eq(label.text, "✦ Greymaw the Alpha ✦", "elite name is star-framed")
	assert_eq(label.modulate, Color(1.0, 0.84, 0.0), "elite name renders gold")


func test_normal_hostile_mob_name_is_red() -> void:
	var l = _layer()
	(
		l
		. ingest(
			{
				"players": [],
				"mobs":
				[
					{
						"mob_id": 1101,
						"kind": "mob_wolf",
						"name": "Gray Wolf",
						"elite": false,
						"x": 5,
						"y": 6,
						"z": 0,
						"hp": 80,
						"max_hp": 80,
					}
				],
			},
			99,
			1000
		)
	)
	var label := l.hp_bar_for("mob_1101").get_node("name_text") as Label3D
	assert_eq(label.text, "Gray Wolf", "normal mob name is unframed")
	assert_ne(label.modulate, Color(1.0, 0.84, 0.0), "normal mob name is not gold")
	assert_eq(
		label.modulate,
		Relationship.HOSTILE_PLATE,
		"an ordinary hostile mob name uses the hostile red relationship color"
	)


# ---- T-193: nameplates depth-test against world geometry (walls occlude them) ----


func test_health_nameplate_depth_tests() -> void:
	var l = _layer()
	var bar := l._make_hp_bar()
	var hp_text := bar.get_node("hp_text") as Label3D
	assert_false(hp_text.no_depth_test, "the health numeric label depth-tests (walls occlude it)")
	var fill := bar.get_node("hp_fill") as MeshInstance3D
	var mat := fill.material_override as StandardMaterial3D
	assert_false(mat.no_depth_test, "the health bar fill depth-tests too")


func test_cast_nameplate_depth_tests_but_damage_numbers_do_not() -> void:
	var l = _layer()
	var cast := l._make_cast_bar()
	var cfill := (
		(cast.get_node("cast_fill") as MeshInstance3D).material_override as StandardMaterial3D
	)
	assert_false(cfill.no_depth_test, "the nameplate cast bar depth-tests (same defect class)")
	# transient floating damage numbers stay always-on-top by design (ticket: leave unchanged)
	var mob = _layer_with_mob()
	mob.spawn_damage_number(1001, 12, "hit")
	for child in mob.get_children():
		if child is Label3D and (child as Label3D).visible:
			assert_true((child as Label3D).no_depth_test, "damage numbers stay on top (transient)")
			break


# ---- T-463: hostile plates carry level + show in range at full health ------------------------


func test_mob_nameplate_carries_the_broadcast_level() -> void:
	var l = _layer()
	l.ingest(
		{
			"players": [],
			"mobs":
			[
				{
					"mob_id": 1001,
					"x": 0,
					"y": 0,
					"z": 0,
					"hp": 50,
					"max_hp": 50,
					"name": "Wolf",
					"level": 3
				}
			]
		},
		99,
		1000
	)
	var name_label: Label3D = l.hp_bar_for("mob_1001").get_node("name_text")
	assert_eq(name_label.text, "Wolf  Lv 3", "server-truth level rides the plate")


func test_elite_nameplate_keeps_stars_and_adds_level() -> void:
	var l = _layer()
	l.ingest(
		{
			"players": [],
			"mobs":
			[
				{
					"mob_id": 1002,
					"x": 0,
					"y": 0,
					"z": 0,
					"hp": 200,
					"max_hp": 200,
					"name": "Hollow King",
					"level": 12,
					"elite": true
				}
			]
		},
		99,
		1000
	)
	var name_label: Label3D = l.hp_bar_for("mob_1002").get_node("name_text")
	assert_eq(name_label.text, "✦ Hollow King ✦  Lv 12", "elite stars + level coexist")


func test_missing_level_shows_bare_name() -> void:
	var l = _layer()
	l.ingest(
		{
			"players": [],
			"mobs":
			[{"mob_id": 1003, "x": 0, "y": 0, "z": 0, "hp": 50, "max_hp": 50, "name": "Rat"}]
		},
		99,
		1000
	)
	var name_label: Label3D = l.hp_bar_for("mob_1003").get_node("name_text")
	assert_eq(name_label.text, "Rat", "no level in the broadcast -> no Lv tag fabricated")


func test_full_health_mob_plate_is_visible_in_range() -> void:
	# T-463: hostile units advertise strength at a glance — the plate no longer waits for damage.
	var l = _layer()
	l.ingest(
		{
			"players": [],
			"mobs":
			[
				{
					"mob_id": 1004,
					"x": 0,
					"y": 0,
					"z": 0,
					"hp": 50,
					"max_hp": 50,
					"name": "Wolf",
					"level": 3
				}
			]
		},
		99,
		1000
	)
	assert_true(
		l.hp_bar_for("mob_1004").visible, "hostile plate shows at full health (in nameplate range)"
	)


func test_full_health_player_plate_still_hidden() -> void:
	# Guard: the always-on rule is hostile-only — friendly players keep the T-178 quiet default.
	var l = _layer()
	l.ingest(
		{"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0, "hp": 100, "max_hp": 100}], "mobs": []},
		99,
		1000
	)
	assert_false(
		l.hp_bar_for("player_1").visible, "full-health untargeted PLAYER plate stays off (T-178)"
	)


func test_hidden_labels_toggle_still_wins_for_hostile_plates() -> void:
	var l = _layer()
	l.set_labels_visible(false)
	l.ingest(
		{
			"players": [],
			"mobs":
			[{"mob_id": 1005, "x": 0, "y": 0, "z": 0, "hp": 50, "max_hp": 50, "name": "Wolf"}]
		},
		99,
		1000
	)
	assert_false(l.hp_bar_for("mob_1005").visible, "T-227 toggle hides hostile plates too")


# ---- T-465: floating combat text — crit pop-in envelope ---------------------------------------


func test_crit_float_spawns_oversized_then_settles() -> void:
	var layer = _layer_with_mob()
	layer.spawn_damage_number(1001, 40, "crit")
	var crit: Label3D = null
	for child in layer.get_children():
		if child is Label3D and (child as Label3D).visible:
			crit = child
	assert_not_null(crit)
	assert_gt(crit.scale.x, 1.0, "a crit pops in oversized (scale punch on top of font + gold)")


func test_ordinary_hit_float_spawns_at_rest_scale() -> void:
	var layer = _layer_with_mob()
	layer.spawn_damage_number(1001, 12, "hit")
	var hit: Label3D = null
	for child in layer.get_children():
		if child is Label3D and (child as Label3D).visible:
			hit = child
	assert_not_null(hit)
	assert_eq(hit.scale, Vector3.ONE, "no pop for a plain hit — crits stay special")
