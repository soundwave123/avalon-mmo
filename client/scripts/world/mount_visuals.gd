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

const MOUNTS := {
	# The baseline mount every character is seeded with (travel_ops.gd BASELINE_MOUNT).
	"mount_common_gryphon":
	{
		"path": "res://assets/models/mount_common_gryphon.glb",
		# TRELLIS output is ~0.93m normalized; 1.9 puts the back at rideable height (pilot fit pass tunes)
		"scale": 1.9,
		"yaw_deg": 0.0,
		"anim": "idle",
		"seat": Vector3(0.0, 1.15, 0.0),
	},
	# Cosmetic skins (mount_service.gd's skin-swap tests): base gryphon mesh + a material
	# multiply (the proven T-349 tint idiom) so one GLB serves every launch skin.
	"skin_storm_gryphon":
	{
		"path": "res://assets/models/mount_common_gryphon.glb",
		"scale": 1.0,
		"yaw_deg": 0.0,
		"anim": "idle",
		"seat": Vector3(0.0, 1.15, 0.0),
		"tints": {"body": Color(0.55, 0.62, 0.80), "trim": Color(0.35, 0.42, 0.65)},
	},
	"skin_royal_gryphon":
	{
		"path": "res://assets/models/mount_common_gryphon.glb",
		"scale": 1.0,
		"yaw_deg": 0.0,
		"anim": "idle",
		"seat": Vector3(0.0, 1.15, 0.0),
		"tints": {"body": Color(0.85, 0.72, 0.35), "trim": Color(0.60, 0.45, 0.15)},
	},
}


# Resolve a mount_visual id to its spec: the registered entry, or the drop-in default
# (res://assets/models/<id>.glb, identity fit) for an id the registry hasn't met yet.
static func spec_for(visual_id: String) -> Dictionary:
	if MOUNTS.has(visual_id):
		return MOUNTS[visual_id]
	return {"path": "res://assets/models/%s.glb" % visual_id}


# The rider attach transform for a mount id (Vector3.ZERO when unregistered/unknown).
static func seat_offset(visual_id: String) -> Vector3:
	return spec_for(visual_id).get("seat", Vector3.ZERO)


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
