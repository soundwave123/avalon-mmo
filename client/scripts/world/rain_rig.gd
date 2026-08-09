extends RefCounted

# T-614: the T-085 weather rain emitter, extracted from world_view.gd (at the 1000-line cap).
# ROOT CAUSE the extraction fixes: the emitter was parented to WorldView's PREVIEW camera_arm,
# but local_player.gd builds its own camera rig and takes over (camera.current = true) the
# moment the player spawns — the preview arm never leaves the origin, so "camera-following"
# rain only ever fell in a ~56m box around (0,0,0) that no player stands in (soak-12 saw the
# overcast dimming apply while zero drops rendered at the village vista, 40m away). The
# emitter is now WORLD-parented and follow()ed over the ACTIVE viewport camera every frame,
# so the emission box and the node-local visibility AABB always cover the live view.

const CAMERA_HEIGHT := 22.0  # emit from this far above the followed camera (drops fall past it)
const AMOUNT := 3000
const LIFETIME := 1.1
const FALL_GRAVITY := 6.0  # extra downward pull on top of the initial streak velocity
const VELOCITY_MIN := 16.0
const VELOCITY_MAX := 20.0
const BOX_EXTENTS := Vector3(28.0, 0.5, 28.0)  # emission sheet, centred on the node
# Node-local visibility AABB: must enclose the emission sheet AND the full fall distance
# (VELOCITY_MAX * LIFETIME + FALL_GRAVITY/2 * LIFETIME^2 ~= 25.6m below the emitter).
const VIS_AABB := AABB(Vector3(-30, -30, -30), Vector3(60, 60, 60))


# Build the emitter (not emitting; world_view's set_rain()/T-187 suppression gate it).
static func build() -> GPUParticles3D:
	var rain := GPUParticles3D.new()
	rain.name = "Rain"
	rain.amount = AMOUNT
	rain.lifetime = LIFETIME
	rain.visibility_aabb = VIS_AABB
	rain.local_coords = false
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = BOX_EXTENTS
	proc.direction = Vector3(0.1, -1.0, 0.05)
	proc.spread = 3.0
	proc.initial_velocity_min = VELOCITY_MIN
	proc.initial_velocity_max = VELOCITY_MAX
	proc.gravity = Vector3(0.0, -FALL_GRAVITY, 0.0)
	rain.process_material = proc
	var streak := QuadMesh.new()
	streak.size = Vector2(0.02, 0.5)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.7, 0.78, 0.9, 0.5)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	streak.material = mat
	rain.draw_pass_1 = streak
	rain.emitting = false  # clear by default
	rain.position = Vector3(0.0, CAMERA_HEIGHT, 0.0)  # sane pre-spawn spot; follow() takes over
	return rain


# Park the emitter over whichever camera is LIVE right now (the WorldView preview rig until
# the player spawns, local_player's rig after takeover). Called from world_view._process.
static func follow(rain: GPUParticles3D, cam: Camera3D) -> void:
	if rain == null or cam == null:
		return
	rain.global_position = cam.global_position + Vector3(0.0, CAMERA_HEIGHT, 0.0)
