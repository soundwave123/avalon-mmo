class_name NpcWorldLayer
extends Node3D

# T-056: renders NPCs in the 3D world from npc_indicators — a clickable body + a Label3D "!"/"?"
# billboard above it (reusing NpcMarker.marker_style for the WoW gold logic). Click a body →
# npc_clicked(npc_id); main.gd turns that into a `talk` intent (the server validates proximity).
# Server (x, y) ground -> Godot (x, terrain height, y) — T-445 rolled the walked meadow, so a
# static NPC's render height derives from the shared TerrainField (its wire stays 2D, the same
# derive-don't-send rule the server applies to players). Spawn on sight, despawn on payload exit.
#
# Gotchas: Label3D billboard mode faces the camera; no_depth_test keeps the marker above terrain;
# size scales with distance but is clamped (see _process) so it stays proportionate. Click picking
# ALSO needs the viewport's physics_object_picking enabled (main.gd does that) — off by default.

signal npc_clicked(npc_id: String)

const NpcMarker = preload("res://scripts/ui/npc_marker.gd")  # reuse the pure !/? style mapping
const NameplateLod = preload("res://scripts/ui/nameplate_lod.gd")  # T-463 pure fade/stagger math
const AppearanceResolver = preload("res://scripts/world/appearance_resolver.gd")  # T-302 pure look
const SnapshotBuffer = preload("res://scripts/world/snapshot_buffer.gd")  # T-311: mover interp
const RENDER_DELAY_MS := 100  # T-311: render movers ~2-3 broadcasts behind, for smooth motion
const WALK_SPEED_THRESHOLD := 0.5  # T-311: planar m/s that reads as walking (mirrors remote layer)
# Marker sizing: scale with perspective (proportionate to the NPC) but clamp so it neither balloons
# close nor vanishes far away (the Roblox DistanceLowerLimit/UpperLimit + WoW model). Tunable.
const BASE_PIXEL_SIZE := 0.015  # Label3D world size at natural range
const NEAR_CLAMP := 8.0  # closer than this → stop growing (cap apparent size)
const FAR_CLAMP := 40.0  # farther than this → stop shrinking (floor so it stays readable)
const TABARD_MESH := "res://assets/models/prop_hk_guard_tabard.glb"  # T-302b guard livery overlay
const TABARD_BONE := "spine_02"  # chest bone the tabard rides (weapon_socket precedent)
const NAME_PIXEL_SIZE := 0.008  # T-463: name-label world size (clamped per-frame like the marker)
const NAME_BASE_HEIGHT := 2.0  # T-463: name-label rest height; crowd stagger lifts from here
# T-589: marker occlusion ray budget — one intersect_ray per marker-bearing NPC per tick, not per
# frame (the training-yard crowd would otherwise spam the physics server every frame).
const OCCLUSION_INTERVAL_MS := 200
# T-697 fix 7: the full label-LOD pass (distances, alpha, pixel_size, the O(n^2) name stagger +
# its Array allocs) runs at ~10 Hz — nameplate fade/scale stepping at 100 ms is imperceptible.
# Only the per-frame position lerp / facing / walk-clip work above it stays per-frame.
const LABEL_LOD_INTERVAL_MS := 100
# T-446: idle-life act names (server npc_idle pulses) -> existing rig clips via STATE_CLIPS.
# hammer reads as the smith's downswing (attack one-shot), pray kneels, gesture points. A pulse
# holds the last pose until the server clears it, then the ""->act edge retriggers the one-shot.
const ACT_STATES := {"hammer": "attack", "pray": "kneel", "gesture": "point"}
const FACING_LERP_RATE := 6.0  # rad-ish/s toward the broadcast idle facing (calm, not snappy)

const VoicePlayer = preload("res://scripts/audio/voice_player.gd")  # T-674: voiced-dialogue player

var _npcs: Dictionary = {}  # npc_id -> {body: StaticBody3D, label: Label3D}
var _labels_hidden: bool = false  # T-227: pilot/settings nameplate toggle
var _label_lod_next_ms: int = 0  # T-697 fix 7: next label-LOD pass (0 = run on the first frame)
# T-445: shared ground truth — NPC wire positions are planar; render height derives client-side.
# Untyped preload/instance (a TerrainField annotation breaks the cold headless parse, T-309).
var _terrain = preload("res://scripts/world/terrain_field.gd").new()


# T-674: host the VoicePlayer here (voices come from NPCs in the world). It self-connects to the
# quest-offer panel's line_shown signal and parents each spoken line's AudioStreamPlayer3D onto the
# matching NPC body (body_for). main.gd sits at its 1000-line cap, so the layer that owns the NPC
# bodies mounts the player rather than threading another wiring line through main.
func _ready() -> void:
	var voice := VoicePlayer.new()
	voice.name = "VoicePlayer"
	add_child(voice)


func update(npcs: Array) -> void:
	var seen: Dictionary = {}
	for npc: Dictionary in npcs:
		var npc_id := str(npc.get("npc_id", ""))
		if npc_id == "":
			continue
		seen[npc_id] = true
		var e := _ensure(npc_id, _appearance_of(npc), str(npc.get("name", "")))
		# T-311: the interpolator owns a mover's position once it's on the positions stream; the
		# npc_indicators post only seeds a still-static NPC (else it fights the smooth interpolation).
		if e.get("buffer") == null:
			var gx := float(npc.get("x", 0.0))
			var gz := float(npc.get("y", 0.0))
			(e["body"] as Node3D).position = Vector3(gx, _terrain.height(gx, gz), gz)
		var style := NpcMarker.marker_style(str(npc.get("indicator", "")), npc_id)
		var label: Label3D = e["label"]
		label.text = style["symbol"]
		label.modulate = style["color"]
		e["marker_visible"] = bool(style["visible"])  # T-227: remember so the toggle can restore it
		e["marker_scale"] = float(style.get("scale", 1.0))  # T-668: primary giver renders larger
		label.visible = style["visible"] and not _labels_hidden
		(e["name_label"] as Label3D).visible = not _labels_hidden
	for npc_id: String in _npcs.keys():
		if not seen.has(npc_id):
			_npcs[npc_id]["body"].queue_free()
			_npcs.erase(npc_id)


# T-227: hide/show all NPC nameplates + !/? markers at once (glamour shots / settings).
func set_labels_visible(visible: bool) -> void:
	_labels_hidden = not visible
	for npc_id: String in _npcs:
		var e: Dictionary = _npcs[npc_id]
		(e["label"] as Label3D).visible = bool(e.get("marker_visible", false)) and visible
		(e["name_label"] as Label3D).visible = visible


# T-058: targeted update — upsert only the listed NPCs; unlisted billboards untouched.
func apply_partial(npcs: Array) -> void:
	for npc: Dictionary in npcs:
		var npc_id := str(npc.get("npc_id", ""))
		if npc_id == "":
			continue
		var e := _ensure(npc_id, _appearance_of(npc), str(npc.get("name", "")))
		if e.get("buffer") == null:  # T-311: don't overwrite a mover's interpolated position
			var gx := float(npc.get("x", 0.0))
			var gz := float(npc.get("y", 0.0))
			(e["body"] as Node3D).position = Vector3(gx, _terrain.height(gx, gz), gz)
		var style := NpcMarker.marker_style(str(npc.get("indicator", "")), npc_id)
		var label: Label3D = e["label"]
		label.text = style["symbol"]
		label.modulate = style["color"]
		e["marker_visible"] = bool(style["visible"])
		e["marker_scale"] = float(style.get("scale", 1.0))  # T-668: primary giver renders larger
		label.visible = style["visible"] and not _labels_hidden
		(e["name_label"] as Label3D).visible = not _labels_hidden


# T-311: feed the positions broadcast's `npcs` array — live positions of the moving NPCs. Each is
# pushed to a per-NPC SnapshotBuffer (created lazily) so _process interpolates + animates the walk,
# mirroring how RemoteEntitiesLayer drives remote players/mobs. NPCs not yet spawned from an
# npc_indicators reply are ignored (their body appears once indicators land).
func ingest_positions(npcs: Array, now_ms: int) -> void:
	for npc: Dictionary in npcs:
		var npc_id := str(npc.get("npc_id", ""))
		if npc_id == "" or not _npcs.has(npc_id):
			continue
		var e: Dictionary = _npcs[npc_id]
		if e.get("buffer") == null:
			e["buffer"] = SnapshotBuffer.new()
		# server (x, y ground) -> Godot (x, terrain height, y) — T-445: height derives from the
		# shared TerrainField (the NPC wire is planar; flat pads keep this a no-op in town).
		var px := float(npc.get("x", 0.0))
		var pz := float(npc.get("y", 0.0))
		(e["buffer"] as SnapshotBuffer).push(Vector3(px, _terrain.height(px, pz), pz), now_ms)
		# T-446: idle-life extras — server facing (atan2(dx, dy) ground space == body yaw here)
		# and the current act pulse ("" between pulses so a one-shot can retrigger).
		if npc.has("f"):
			e["srv_facing"] = float(npc.get("f", 0.0))
		e["act"] = str(npc.get("act", ""))


# Per-frame: keep each marker proportionate but clamped (no balloon up close, no vanish far away).
func _process(delta: float) -> void:
	# T-311: interpolate + animate the moving NPCs (mirrors RemoteEntitiesLayer._process).
	var render_t := Time.get_ticks_msec() - RENDER_DELAY_MS
	for npc_id: String in _npcs:
		var e: Dictionary = _npcs[npc_id]
		var buffer = e.get("buffer")
		if buffer == null or (buffer as SnapshotBuffer).size() == 0:
			continue
		var body: Node3D = e["body"]
		var pos: Vector3 = (buffer as SnapshotBuffer).sample(render_t)
		var planar := pos - body.global_position
		planar.y = 0.0
		body.global_position = pos
		var moving := delta > 0.0 and planar.length() / delta > WALK_SPEED_THRESHOLD
		if moving:
			# Face travel (Report #15 moonwalk fix): the hero rigs face +Z IN-FILE, and the body's
			# yaw = atan2(x,z) points body-local +Z along the travel direction — so the model must
			# NOT carry a 180° flip (see _make_mesh) or it walks backwards.
			var target_yaw := atan2(planar.x, planar.z)
			body.rotation.y = lerp_angle(body.rotation.y, target_yaw, minf(10.0 * delta, 1.0))
		elif e.has("srv_facing"):
			# T-446: stationary NPCs ease toward the server's idle facing drift (never frozen).
			var yaw := float(e["srv_facing"])
			body.rotation.y = lerp_angle(body.rotation.y, yaw, minf(FACING_LERP_RATE * delta, 1.0))
		var state := "walk" if moving else act_state(str(e.get("act", "")))
		if e.get("anim_state", "") != state:
			e["anim_state"] = state
			EntityVisuals.play_state(e["model"], state)

	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var now_ms := Time.get_ticks_msec()
	# T-697 fix 7: everything below is the throttled ~10 Hz label-LOD pass (see the const note).
	if now_ms < _label_lod_next_ms:
		return
	_label_lod_next_ms = now_ms + LABEL_LOD_INTERVAL_MS
	for npc_id: String in _npcs:
		var e: Dictionary = _npcs[npc_id]
		var label: Label3D = e["label"]
		var anchor := label.global_position
		var d := cam.global_position.distance_to(anchor)
		# T-589: long-range fade tier (markers are the navigation beacon, spottable well past the
		# name/health horizon) + occlusion dim (markers only — see _marker_occluded).
		var has_marker: bool = bool(e.get("marker_visible", false))
		var occluded := false
		if has_marker and d <= NameplateLod.MARKER_FADE_END:
			occluded = _marker_occluded(cam, anchor, e, now_ms)
		var alpha := NameplateLod.occluded_alpha(
			NameplateLod.alpha_for_distance(
				d, NameplateLod.MARKER_FADE_START, NameplateLod.MARKER_FADE_END
			),
			occluded
		)
		label.modulate.a = alpha
		label.visible = has_marker and alpha > 0.0 and not _labels_hidden
		var scale := NameplateLod.scale_for_distance(
			d,
			NameplateLod.SCALE_FULL_DISTANCE,
			NameplateLod.MARKER_FADE_END,
			NameplateLod.SCALE_FLOOR
		)
		# T-668: the primary/tutorial giver carries a size bump (NpcMarker.PRIMARY_MARKER_SCALE) plus
		# a gentle breathing pulse so it reads as unmistakably distinct, not just a slightly warmer
		# gold. Standard markers keep marker_scale == 1.0 and never pulse.
		var marker_scale := float(e.get("marker_scale", 1.0))
		var pulse := NpcMarker.pulse_scale(now_ms / 1000.0) if marker_scale > 1.0 else 1.0
		label.pixel_size = (
			BASE_PIXEL_SIZE
			* marker_pixel_scale(d, NEAR_CLAMP, FAR_CLAMP)
			* scale
			* marker_scale
			* pulse
		)
	_apply_name_lod(cam.global_position)


# T-589: marker-only occlusion — dim (not hide) a quest !/? when static world geometry sits between
# the camera and its anchor (WoW's nameplateOccludedAlphaMult read; names/health bars keep the T-193
# hard depth-test occlusion and are untouched here). Rate-limited to one ray per NPC per
# OCCLUSION_INTERVAL_MS (the caller only enters this for markers already inside MARKER_FADE_END) —
# between ticks the cached result carries over so the label doesn't flicker every frame.
func _marker_occluded(cam: Camera3D, anchor: Vector3, e: Dictionary, now_ms: int) -> bool:
	var next_ms := int(e.get("occl_next_ms", 0))
	if now_ms < next_ms:
		return bool(e.get("occluded", false))
	e["occl_next_ms"] = now_ms + OCCLUSION_INTERVAL_MS
	# Headless/no-camera contexts never reach this (the _process caller bails when there's no
	# camera); this guard is the belt-and-suspenders no-op for a not-yet-ready world/space state.
	if not is_inside_tree():
		e["occluded"] = false
		return false
	var world := get_world_3d()
	var space := world.direct_space_state if world != null else null
	if space == null:
		e["occluded"] = false
		return false
	var query := PhysicsRayQueryParameters3D.create(cam.global_position, anchor)
	var body: Variant = e.get("body")
	if body is CollisionObject3D:
		query.exclude = [(body as CollisionObject3D).get_rid()]  # never self-occlude
	var occluded := not space.intersect_ray(query).is_empty()
	e["occluded"] = occluded
	return occluded


# T-463: distance fade + size clamp + bunched-crowd stagger for the NPC name labels, driven by the
# pure NameplateLod math (headless tests call this directly with a fake camera position). Plates
# fade out across the 16-28 m band instead of popping; NPCs bunched within ~1.7 m stack their names
# in a readable column (dict insertion order keeps the stagger deterministic — no frame flicker).
# O(n²) over on-screen NPCs is fine at village crowd sizes (dozens).
func _apply_name_lod(cam_pos: Vector3) -> void:
	var anchors: Array = []
	for npc_id: String in _npcs:
		anchors.append((_npcs[npc_id]["body"] as Node3D).global_position)
	var lifts := NameplateLod.stagger_offsets(anchors)
	var i := 0
	for npc_id: String in _npcs:
		var label: Label3D = _npcs[npc_id]["name_label"]
		var d := cam_pos.distance_to(anchors[i])
		var alpha := NameplateLod.alpha_for_distance(d)
		label.modulate.a = alpha
		label.visible = alpha > 0.0 and not _labels_hidden
		label.position.y = NAME_BASE_HEIGHT + float(lifts[i])
		# T-589: scale-shrink toward the (unchanged) 16-28 m name fade edge, on top of the existing
		# perspective clamp.
		var scale := NameplateLod.scale_for_distance(d)
		label.pixel_size = NAME_PIXEL_SIZE * marker_pixel_scale(d, NEAR_CLAMP, FAR_CLAMP) * scale
		i += 1


# T-446: resolve a server idle-act pulse to an animation state ("" / unknown act -> idle). The
# resolved states are one-shots (attack/kneel/point) that hold their last pose until the pulse
# clears, so the smith hammers, clergy kneel and vendors gesture on the existing clip set.
static func act_state(act: String) -> String:
	return str(ACT_STATES.get(act, "idle"))


# Clamp factor for the marker's world size: 1.0 between near/far (natural perspective); shrinks the
# world size closer than near (apparent caps) and grows it past far (apparent floors).
static func marker_pixel_scale(distance: float, near: float, far: float) -> float:
	if distance < near:
		return distance / near
	if distance > far:
		return distance / far
	return 1.0


# T-302: the server may send an `appearance` block per NPC; default to {} (deterministic fallback).
func _appearance_of(npc: Dictionary) -> Dictionary:
	var a: Variant = npc.get("appearance", {})
	return a if a is Dictionary else {}


func _ensure(npc_id: String, appearance: Dictionary = {}, npc_name: String = "") -> Dictionary:
	if not _npcs.has(npc_id):
		var body := StaticBody3D.new()
		body.name = "Npc_%s" % npc_id
		# T-656: off the default physics layer (1) — see remote_entities_layer.gd's `_ensure` for
		# the full rationale (SpringArm3D camera probe only tests layer 1; standing point-blank
		# next to a quest-giver/vendor shouldn't clip the camera into them either).
		body.collision_layer = 2
		var model := _make_mesh(npc_id, appearance)  # T-311: visual ref drives walk/idle + facing
		body.add_child(model)
		body.add_child(_make_collision())
		var label := _make_label()
		body.add_child(label)
		# T-076: a WoW-style nameplate so NPCs are identifiable at a glance.
		var name_label := _make_name_label(npc_name if npc_name != "" else npc_id)
		body.add_child(name_label)
		body.input_event.connect(func(_c, event, _p, _n, _s): _on_body_input(npc_id, event))
		add_child(body)
		# T-311: buffer is created lazily on the first positions broadcast (movers only); anim_state
		# tracks the last-applied clip so play_state only fires on an actual idle<->walk change.
		_npcs[npc_id] = {
			"body": body,
			"label": label,
			"name_label": name_label,
			"model": model,
			"buffer": null,
			"anim_state": "idle",
		}
	return _npcs[npc_id]


func _make_mesh(npc_id: String, appearance: Dictionary = {}) -> Node3D:
	# T-166 (owner mandate): NPCs are heroic-proportion Universal Base Characters. T-302: the pure
	# AppearanceResolver picks which rig + a per-material tint palette + a scale from the NPC's
	# role/seed, so guards, clergy, merchants, peasants and children read as individuals rather
	# than one bearded clone. Capsule stays as the fallback if the GLB is missing.
	var look := AppearanceResolver.resolve(npc_id, appearance)
	var path := str(look["mesh"])
	if ResourceLoader.exists(path):
		var packed := load(path) as PackedScene
		if packed != null:
			var model := packed.instantiate() as Node3D
			if model != null:
				# Report #15 (moonwalk): NO 180° flip. The hero rigs face +Z in-file and _process
				# aligns body +Z with the walk direction / broadcast facing — the old flip pointed
				# the visual exactly opposite its movement (NPCs read as walking backwards).
				model.rotation.y = 0.0  # in-file 1.84m, real scale, +Z-facing
				model.scale = Vector3.ONE * float(look["scale"])  # T-302: height variation / child scale
				_apply_tints(model, look["tints"], str(look.get("hair_tex", "")))  # T-302: tint + hair swap
				if str(look.get("role", "")) == "guard":
					_attach_tabard(model)  # T-302b: house-livery tabard over the guard torso
				EntityVisuals.play_state(model, "idle")
				return model
	var mesh := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.4
	cap.height = 1.8
	mesh.mesh = cap
	mesh.position = Vector3(0.0, 0.9, 0.0)
	var mat := StandardMaterial3D.new()
	# Fallback capsule wears the resolved body tint so even the greybox varies by role.
	var tints: Dictionary = look["tints"]
	mat.albedo_color = tints.get("body", Color(0.35, 0.75, 0.45))
	mesh.material_override = mat
	return mesh


# T-302: apply the resolved per-slot tint palette onto the instanced rig. Each modular clothing/
# hair piece is its own MeshInstance3D+material; we duplicate the material, multiply its albedo by
# the slot tint, and set it as a surface override so the shared source material is never mutated and
# skeletal animation is untouched.
func _apply_tints(root: Node, tints: Dictionary, hair_tex: String = "") -> void:
	if tints.is_empty():
		return
	var hair_swap: Texture2D = null
	if hair_tex != "" and ResourceLoader.exists(hair_tex):
		hair_swap = load(hair_tex) as Texture2D
	for mi: MeshInstance3D in _mesh_instances(root):
		var mesh := mi.mesh
		if mesh == null:
			continue
		for s in range(mesh.get_surface_count()):
			var mat := mi.get_active_material(s)
			if mat == null:
				continue
			var slot := AppearanceResolver.material_slot(str(mat.resource_name))
			if not tints.has(slot):
				continue
			var dup := mat.duplicate() as BaseMaterial3D
			if dup == null:
				continue
			dup.albedo_color = dup.albedo_color * (tints[slot] as Color)
			# T-302b: real hair-colour variety — swap the near-black hair atlas for a recoloured
			# one (grey/blonde/auburn) so a light head is reachable (a multiply alone can't brighten).
			if slot == "hair" and hair_swap != null:
				dup.albedo_texture = hair_swap
			mi.set_surface_override_material(s, dup)


# T-302b: attach the house-livery tabard (front + back panel mesh, UV-mapped to
# prop_hk_guard_tabard_col.png) over a guard's torso. The tabard GLB is authored in the rig's
# skeleton space (in place on the chest), so a BoneAttachment3D on the chest bone (spine_02 —
# weapon_socket.gd precedent) carries it: the attachment's global = skeleton * bone_pose, so the
# child's local transform must be the bone's rest inverse (bone_rest * bone_rest⁻¹ = identity at
# rest → the mesh lands exactly where authored) and then it follows the chest as the body animates.
func _attach_tabard(model: Node) -> void:
	if not ResourceLoader.exists(TABARD_MESH):
		return
	var skel := _find_skeleton(model)
	if skel == null:
		return
	var idx := skel.find_bone(TABARD_BONE)
	if idx < 0:
		return
	var packed := load(TABARD_MESH) as PackedScene
	if packed == null:
		return
	var tabard := packed.instantiate() as Node3D
	if tabard == null:
		return
	var att := BoneAttachment3D.new()
	att.name = "GuardTabard"
	att.bone_name = TABARD_BONE
	skel.add_child(att)
	att.add_child(tabard)
	tabard.transform = skel.get_bone_global_rest(idx).affine_inverse()


func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
	for child in root.get_children():
		var s := _find_skeleton(child)
		if s != null:
			return s
	return null


func _mesh_instances(root: Node) -> Array:
	var out: Array = []
	if root is MeshInstance3D:
		out.append(root)
	for child in root.get_children():
		out.append_array(_mesh_instances(child))
	return out


# T-076: small always-readable nameplate under the !/? marker. T-463: the chat-log legibility rule
# — a hard black outline (set explicitly, never default-dependent) so the name survives bright
# grass/sky, not just dark foliage.
# T-667: colour routes through Relationship (T-665's mob/player picker) instead of a hardcoded
# white that bypassed the friend/foe read entirely for every static NPC (Cleric Ansa, Drillmaster
# Hale, villagers, guards).
func _make_name_label(npc_name: String) -> Label3D:
	var label := Label3D.new()
	label.text = npc_name
	label.position = Vector3(0.0, NAME_BASE_HEIGHT, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false  # T-193: depth-test so walls occlude the NPC name nameplate
	label.pixel_size = NAME_PIXEL_SIZE
	label.font_size = 40
	label.outline_size = 10
	label.outline_modulate = Color(0.0, 0.0, 0.0, 0.95)
	label.modulate = _name_label_color()
	return label


# T-667: mirrors remote_entities_layer.gd's _plate_color — same Relationship.of/plate_color picker
# T-665 wired for mobs and players. A static NPC is never a mob and carries no peer/party/pvp
# facts of its own, so Relationship.of degrades to FRIENDLY (green) rather than the old flat
# white; a future per-NPC disposition (e.g. a hostile/neutral guard) would flow through this same
# call with no further plumbing, exactly like a mob's "hostile" flag does today.
func _name_label_color() -> Color:
	return Relationship.plate_color(Relationship.of({}, {}))


func _make_collision() -> CollisionShape3D:
	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4
	shape.height = 1.8
	col.shape = shape
	col.position = Vector3(0.0, 0.9, 0.0)
	return col


func _make_label() -> Label3D:
	var label := Label3D.new()
	label.position = Vector3(0.0, 2.3, 0.0)  # above the head
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED  # always face the camera
	label.no_depth_test = true  # draw over terrain so the marker is never hidden
	label.fixed_size = false  # scale with perspective (clamped per-frame); proportionate to the NPC
	label.pixel_size = BASE_PIXEL_SIZE
	label.font_size = 64
	label.outline_size = 12
	return label


func _on_body_input(npc_id: String, event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		npc_clicked.emit(npc_id)


func npc_count() -> int:
	return _npcs.size()


func label_text(npc_id: String) -> String:
	return _npcs[npc_id]["label"].text if _npcs.has(npc_id) else ""


func name_label_for(npc_id: String) -> Label3D:  # T-463 headless-test accessor (fade/stagger)
	return _npcs[npc_id]["name_label"] if _npcs.has(npc_id) else null


func body_position(npc_id: String) -> Vector3:
	return (_npcs[npc_id]["body"] as Node3D).global_position if _npcs.has(npc_id) else Vector3.ZERO


func body_for(npc_id: String) -> Node3D:  # T-656: headless-test accessor (collision_layer check)
	return _npcs[npc_id]["body"] if _npcs.has(npc_id) else null


# World position of the NPC's billboard (for the Perception gate — is the marker on screen).
func marker_position(npc_id: String) -> Vector3:
	if not _npcs.has(npc_id):
		return Vector3.ZERO
	return (_npcs[npc_id]["label"] as Node3D).global_position
