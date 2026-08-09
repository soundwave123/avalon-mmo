extends RefCounted

# T-303/T-417 cloud-card texture baker — extracted from world_view.gd to stay under the
# 1000-line gdlint cap (the river_view.gd/water_view.gd precedent; T-697's world_view additions
# tipped it over). One soft cumulus-puff variant per call: FBM simplex noise thresholded through
# a Gradient so only the noise "peaks" read as cloud (soft edges, not a cartoon puff). T-417:
# the alpha is ALSO multiplied by a radial vignette so it reaches zero before the quad edge —
# the old seamless NoiseTexture2D left the card's straight quad borders visible ("torn white
# paper") against the T-404 night sky. Baked as a plain ImageTexture (a per-pixel multiply the
# color-ramp path cannot do); cheap at boot.

# T-417: radial rim falloff so a card's alpha hits zero before the quad edge (r == 1.0 mid-edge).
const RIM_INNER := 0.52
const RIM_OUTER := 0.95


static func make(seed_val: int, freq: float) -> ImageTexture:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 5
	noise.fractal_gain = 0.55
	noise.frequency = freq
	noise.seed = seed_val
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.55, 0.68, 1.0])
	grad.colors = PackedColorArray(
		[
			Color(1.0, 1.0, 1.0, 0.0),
			Color(1.0, 1.0, 1.0, 0.0),
			Color(0.98, 0.98, 1.0, 0.55),
			Color(0.94, 0.95, 0.98, 0.92),
		]
	)
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half := float(size) * 0.5
	for y in range(size):
		for x in range(size):
			# radial distance from card centre (1.0 at mid-edge); vignette drops to 0 before the rim.
			var dx := (float(x) + 0.5 - half) / half
			var dy := (float(y) + 0.5 - half) / half
			var v := clampf(noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5, 0.0, 1.0)
			var col := grad.sample(v)
			col.a *= 1.0 - smoothstep(RIM_INNER, RIM_OUTER, sqrt(dx * dx + dy * dy))
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)
