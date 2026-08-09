extends RefCounted
# T-303: fair-weather cumulus deck — soft FBM-noise cloud cards laid as near-horizontal planes
# high over the meadow; viewed from below a horizontal alpha-cutout plane reads as a cloud. Three
# noise-seeded variants avoid a "stamped" repeat across 22 cards; positions/sizes randomize once
# at boot, then drift in WorldView._process. Cheap: unshaded, unlit, no shadows.
#
# Carved verbatim from world_view.gd's _build_clouds for T-734 headroom (that file rides the
# 1000-line cap) — the NIGHT_SKY.build(self) idiom: build(wv) populates wv._clouds and
# wv._cloud_materials (WorldView keeps driving drift + day tint) and parents the layer under wv.

const CLOUD_COUNT := 22  # fair-weather cumulus deck over the meadow/Highkeep approach
const CLOUD_TEXTURE := preload("res://scripts/world/cloud_texture.gd")


static func build(wv: Node3D) -> void:
	var variants: Array[Texture2D] = [
		CLOUD_TEXTURE.make(311, 0.018),
		CLOUD_TEXTURE.make(747, 0.024),
		CLOUD_TEXTURE.make(1290, 0.015),
	]
	wv._cloud_materials.clear()
	for tex in variants:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_texture = tex
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.disable_receive_shadows = true
		wv._cloud_materials.append(mat)

	var container := Node3D.new()
	container.name = "CloudLayer"
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260709
	wv._clouds.clear()
	for i in range(CLOUD_COUNT):
		var quad := QuadMesh.new()
		var w := rng.randf_range(70.0, 150.0)
		quad.size = Vector2(w, w * rng.randf_range(0.6, 0.9))
		quad.material = wv._cloud_materials[i % wv._cloud_materials.size()]
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.mesh = quad
		# lie flat, normal down toward the player; a random yaw keeps the noise shapes varied.
		mesh_inst.rotation_degrees = Vector3(90.0, 0.0, rng.randf_range(0.0, 360.0))
		mesh_inst.position = Vector3(
			rng.randf_range(-360.0, 360.0),
			rng.randf_range(115.0, 165.0),
			rng.randf_range(-380.0, 140.0)
		)
		mesh_inst.set_meta("drift_speed", rng.randf_range(0.5, 1.4))
		container.add_child(mesh_inst)
		wv._clouds.append(mesh_inst)
	wv.add_child(container)
