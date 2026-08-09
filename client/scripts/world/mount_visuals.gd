class_name MountVisuals
extends RefCounted

# T-573: the mount-visual registry + loader — the client half of the mount rendering seam. The
# server already broadcasts a real mount identifier end-to-end (mount_service.gd::visual_for() →
# "mount_state" replies + the positions broadcast's `mounted`/`mount_visual` fields); this module
# resolves that id to a rideable model the moment the GLB lands in assets/models. No asset exists
# yet (the gryphon is generated in a separate lane) — make_mount() returns null for a missing GLB
# so mounting stays visually silent (no error spam, no placeholder box) until the file drops in.
#
# Asset iteration needs NO code edits: an unregistered id resolves to
# res://assets/models/<id>.glb with default fit, and the registry below only adds per-mount
# overrides (scale/facing/clip/seat). The `seat` entry is the RIDER attach transform — the local
# offset the rider's body visual is lifted by so it sits on the mount's back — kept here so
# re-fitting a new mesh is a data edit, not a code change.
#
# T-728 — THE SADDLE SEAT. `seat` used to be a bare Vector3 lift applied in the PLAYER's space,
# which put the rider standing on the mount's back (the reported bug) and, because it never rode
# the mount's `scale`, left the scale-1.0 cosmetic skins floating a metre over their own mesh. The
# seat is now a per-mount dictionary resolved against the mount's own rig:
#   anchor_bone : a bone on the mount rig whose REST origin anchors the seat. The mount GLBs carry
#                 no saddle marker — mount_common_gryphon is 15 generic auto-rig joints, no
#                 `saddle`/`seat`/`socket` empty anywhere — so the barrel bone the quadruped
#                 lineage calls "chest" is the closest honest attachment point the rig exposes.
#                 Unresolvable (no skeleton, renamed bone) falls back to the model origin.
#   offset      : metres from that anchor to the saddle surface, in the MODEL's own space — so it
#                 rides the mount's `scale` and ONE seat value fits every skin of the same mesh.
#   yaw_deg     : the rider's facing correction once seated.
# T-728: the gryphon's saddle, measured off its own mesh — the "chest" bone rests at model y
# 0.575, and the top of the barrel directly above it (vertex scan, |x| < 0.12, within 6cm of the
# bone's z) sits at y 0.724, so the saddle surface is +0.149 up from the anchor. z stays 0: the
# fore/aft nudge is a visual-QA tune no headless mesh scan can settle. All three shipped ids are
# the SAME mesh, so they share this one seat — and, now, the same fit scale.
const GRYPHON_SEAT := {"anchor_bone": "chest", "offset": Vector3(0.0, 0.149, 0.0), "yaw_deg": 0.0}

const MOUNTS := {
	# The baseline mount every character is seeded with (travel_ops.gd BASELINE_MOUNT).
	"mount_common_gryphon":
	{
		"path": "res://assets/models/mount_common_gryphon.glb",
		# TRELLIS output is ~0.93m normalized; 1.9 puts the back at rideable height (pilot fit pass tunes)
		"scale": 1.9,
		"yaw_deg": 0.0,
		"anim": "idle",
		"seat": GRYPHON_SEAT,
	},
	# Cosmetic skins (mount_service.gd's skin-swap tests): base gryphon mesh + a material
	# multiply (the proven T-349 tint idiom) so one GLB serves every launch skin.
	# T-728: a re-skin is a paint job, not a smaller animal — these carried the default scale 1.0
	# against the base mount's 1.9, which shrank a bought skin to half the beast it re-skins.
	"skin_storm_gryphon":
	{
		"path": "res://assets/models/mount_common_gryphon.glb",
		"scale": 1.9,
		"yaw_deg": 0.0,
		"anim": "idle",
		"seat": GRYPHON_SEAT,
		"tints": {"body": Color(0.55, 0.62, 0.80), "trim": Color(0.35, 0.42, 0.65)},
	},
	"skin_royal_gryphon":
	{
		"path": "res://assets/models/mount_common_gryphon.glb",
		"scale": 1.9,
		"yaw_deg": 0.0,
		"anim": "idle",
		"seat": GRYPHON_SEAT,
		"tints": {"body": Color(0.85, 0.72, 0.35), "trim": Color(0.60, 0.45, 0.15)},
	},
}

# T-728: a drop-in mount with no registry row still gets an honest seat — the same barrel-bone
# anchor, no offset (the mount's own rig places the rider at its centre of mass rather than at the
# world origin under its feet). A rig without that bone degrades to the pre-T-728 model origin.
const DEFAULT_SEAT := {"anchor_bone": "chest", "offset": Vector3.ZERO, "yaw_deg": 0.0}

# T-728: how far the rider's hips sit above its OWN root in the seated ride clips (Driving_Loop
# 0.540m, Sitting_Idle_Loop 0.542m — measured off the T-118 source rig, where the standing idle
# holds the same joint at 0.877m). The seat above points at the saddle SURFACE, so the rider's root
# has to sink by this much for its hips — not its feet — to land on it. Skipping this term is
# exactly what made the rider stand on the gryphon's back. Re-measure if the ride clip is re-baked.
const RIDER_HIP_HEIGHT := 0.54


# Resolve a mount_visual id to its spec: the registered entry, or the drop-in default
# (res://assets/models/<id>.glb, identity fit) for an id the registry hasn't met yet.
static func spec_for(visual_id: String) -> Dictionary:
	if MOUNTS.has(visual_id):
		return MOUNTS[visual_id]
	return {"path": "res://assets/models/%s.glb" % visual_id}


# T-728: the normalized seat spec for a mount id. A registry row may still carry the T-573 shape
# (a bare Vector3 lift); it reads as a bone-less model-space offset, so an unmigrated row keeps
# working instead of silently seating the rider at the origin.
static func seat_spec(visual_id: String) -> Dictionary:
	return normalize_seat(spec_for(visual_id).get("seat", DEFAULT_SEAT))


# The registry-shape normalizer behind seat_spec, kept separate so the legacy shape is testable.
static func normalize_seat(raw) -> Dictionary:
	if raw is Vector3:
		return {"anchor_bone": "", "offset": raw, "yaw_deg": 0.0}
	var d: Dictionary = raw
	return {
		"anchor_bone": str(d.get("anchor_bone", "")),
		"offset": d.get("offset", Vector3.ZERO),
		"yaw_deg": float(d.get("yaw_deg", 0.0)),
	}


# T-728: the rider's local transform relative to the mount attach node, for a mount id. `anchor` is
# the seat bone's rest origin in MODEL space (ZERO when the rig exposes none) — make_mount resolves
# it off the real skeleton and stamps the answer on the MountVisual, so this stays a pure function
# of the registry and is unit-testable per mount without loading a rig.
static func seat_transform(visual_id: String, anchor: Vector3 = Vector3.ZERO) -> Transform3D:
	var spec := spec_for(visual_id)
	var seat := seat_spec(visual_id)
	var fit := float(spec.get("scale", 1.0))
	var model_point: Vector3 = anchor + (seat["offset"] as Vector3)
	# The saddle lives in the MOUNT's space: its fit scale and its facing correction both move it.
	var mount_yaw := Basis(Vector3.UP, deg_to_rad(float(spec.get("yaw_deg", 0.0))))
	var pos := mount_yaw * (model_point * fit)
	pos.y -= RIDER_HIP_HEIGHT  # rider-space drop — never scaled by the mount's fit
	return Transform3D(Basis(Vector3.UP, deg_to_rad(float(seat["yaw_deg"]))), pos)


# T-728: the rest-pose origin of a bone on a mount rig, in the MODEL's own untransformed space —
# seat_transform applies the fit scale itself, so this must not include it. ZERO when the model has
# no skeleton or no such bone (the graceful degrade: the rider seats at the model origin).
static func bone_rest_origin(model: Node, bone: String) -> Vector3:
	if model == null or bone == "":
		return Vector3.ZERO
	var skel := _find_skeleton(model)
	if skel == null:
		return Vector3.ZERO
	var idx := skel.find_bone(bone)
	if idx < 0:
		return Vector3.ZERO
	var origin := skel.get_bone_global_rest(idx).origin
	# Walk the skeleton's own placement back up to the model root: identity on every GLB we ship
	# today, but a re-export that nests the rig under an offset node must not shift the saddle.
	var n: Node = skel
	while n != null and n != model:
		if n is Node3D:
			origin = (n as Node3D).transform * origin
		n = n.get_parent()
	return origin


static func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var found := _find_skeleton(c)
		if found != null:
			return found
	return null


# T-728: the seat make_mount stamped on a live MountVisual node (identity for anything else, so a
# caller that never got a mount still reseats its rider at the origin).
static func rider_seat(mount: Node) -> Transform3D:
	if mount == null or not mount.has_meta("seat_transform"):
		return Transform3D.IDENTITY
	var t: Transform3D = mount.get_meta("seat_transform")
	return t


# Build the "MountVisual" node for a mount_visual id, mirroring EntityVisuals._try_glb_model's
# load discipline (exists-check → PackedScene → instance, scale + facing + looping idle clip).
# Returns null on ANY miss — empty id, GLB not landed yet, bad load — so callers show nothing
# and print nothing: the graceful T-573 contract that keeps the wire live before the asset is.
static func make_mount(visual_id: String) -> Node3D:
	if visual_id == "":
		return null
	var spec := spec_for(visual_id)
	var path := str(spec.get("path", ""))
	if not ResourceLoader.exists(path):
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var model := packed.instantiate() as Node3D
	if model == null:
		return null
	var s := float(spec.get("scale", 1.0))
	model.scale = Vector3(s, s, s)
	model.rotation.y = deg_to_rad(float(spec.get("yaw_deg", 0.0)))
	if spec.has("tints"):
		EntityVisuals.apply_appearance(model, spec.get("tints"))
	_loop_clip(model, str(spec.get("anim", "")))
	var root := Node3D.new()
	root.name = "MountVisual"
	root.set_meta("mount_visual_id", visual_id)
	# T-728: resolve the saddle off the real rig ONCE, here, where the model is still in scope, and
	# stamp it — every rider attach (local player and remote riders alike) then reads the same seat
	# without re-walking a skeleton per broadcast.
	var anchor := bone_rest_origin(model, str(seat_spec(visual_id)["anchor_bone"]))
	root.set_meta("seat_transform", seat_transform(visual_id, anchor))
	root.add_child(model)
	return root


# Loop-play the mount's rest clip so it's alive while parked (mirrors EntityVisuals'
# _play_looping: prefer the registered clip, else idle, else the rig's first clip; no-op rigless).
static func _loop_clip(model: Node, preferred: String) -> void:
	var ap := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap == null:
		return
	var clip := ""
	for candidate in [preferred, "idle", "Idle"]:
		if candidate != "" and ap.has_animation(candidate):
			clip = candidate
			break
	if clip == "":
		var list := ap.get_animation_list()
		if list.size() == 0:
			return
		clip = list[0]
	var anim := ap.get_animation(clip)
	if anim != null:
		anim.loop_mode = Animation.LOOP_LINEAR
	ap.play(clip)
