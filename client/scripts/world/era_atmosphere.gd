class_name EraAtmosphere
extends RefCounted

# T-408: the PER-REGION atmosphere layer. Immersion Run 7 headline: crossing the rift into Ashmoor
# (the 1920s-occult district at x~=-420) did not SELL the era shift — the district shared Era-1's
# bright cerulean sky, green meadow and medieval mountain backdrop, so it read as "the far side of
# the same field" rather than a century forward into another world.
#
# This is the PURE math half (unit-tested here; no engine state). WorldView owns the environment
# and drives this each _process tick: it advances a blend 0..1 toward the target era (flipped by the
# SAME EraSkin/in_ashmoor_district resolution the VFX + held-focus re-skin already ride — no second
# era detector) and applies the lerped preset ON TOP of the T-289 sun-arc + T-085 weather base.
#
# ZERO-REGRESSION CONTRACT: ERA0 is byte-for-byte the current world_view constants. At blend 0 every
# lerp is the identity (lerpf(x,y,0)==x, Color.lerp(_,0)==self) and the fog floor equals the base
# minimum, so era-0 steady state is indistinguishable from before this ticket. The unit tests assert
# it. ERA1 (Ashmoor) is the 1920s coal-smog read: denser warm-grey fog with a lower ceiling that
# swallows the distant medieval mountains + green-meadow bleed (that IS the "hide the horizon" trick
# the ticket asks for — fog does it, no terrain re-skin), a desaturated sepia grade via the
# adjustment LUT smog param, a muted overcast sky dome, and a dimmer gaslight-warm sun/ambient.

# --- ERA 0: the home world. Every value is the EXACT current world_view.gd constant. ---
const ERA0 := {
	"fog_density_floor": 0.0026,  # world_view env.fog_density base (T-303)
	"fog_light_color": Color(0.75, 0.80, 0.86),  # world_view env.fog_light_color
	"fog_aerial_perspective": 0.75,  # world_view env.fog_aerial_perspective
	"ambient_energy_scale": 1.0,  # multiplier on the day/night ambient (no change)
	"sun_energy_scale": 1.0,  # multiplier on the sun-arc energy (no change)
	"sky_energy": 2.6,  # world_view sky_mat.energy_multiplier
	"saturation": 1.03,  # world_view env.adjustment_saturation
	"smog": 0.0,  # LUT sepia/desaturation amount (0 == base zone grade)
}

# --- ERA 1: Ashmoor. Enclosed, grey, oppressive; the air tells you before a building is read. ---
const ERA1 := {
	# 0.011 → 0.0075 (owner tuning 2026-07-14: "lighten one notch") — buildings now read at
	# ~40-50m instead of ghosting at 25m; the sepia grade + aerial perspective still swallow the
	# distant medieval backdrop, so the era read survives with comfortable street navigation.
	"fog_density_floor": 0.0075,
	"fog_light_color": Color(0.42, 0.40, 0.36),  # warm-grey smog, not the meadow's cool blue haze
	"fog_aerial_perspective": 0.92,  # distance mutes harder into the low grey ceiling
	"ambient_energy_scale": 0.68,  # dimmer, gaslight-warm interior-lit feel
	"sun_energy_scale": 0.62,  # the sun disc muffled behind smog
	"sky_energy": 1.35,  # muted overcast dome, not the cerulean day sky
	"saturation": 0.60,  # desaturated toward sepia/grey
	"smog": 1.0,
}


static func preset(era_id: int) -> Dictionary:
	return (ERA1 if era_id >= 1 else ERA0).duplicate()


# Per-key interpolation. At t==0 returns `a` byte-for-byte (identity lerp), so ERA0 stays a
# zero-regression passthrough; at t==1 returns `b`. Floats lerp; Colors slerp component-wise.
static func lerp_preset(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := {}
	for k in a:
		var av: Variant = a[k]
		if av is Color:
			out[k] = (av as Color).lerp(b[k], t)
		else:
			out[k] = lerpf(float(av), float(b[k]), t)
	return out


# Monotone step of the blend toward `target` at `rate` (blend units / second). Never overshoots, so
# a stream of advance() calls is a monotone sequence — the SMOOTH, no-pop crossing the ticket wants.
static func advance(current: float, target: float, rate: float, delta: float) -> float:
	if current < target:
		return minf(target, current + rate * delta)
	return maxf(target, current - rate * delta)


# T-138/dial-to-11: the zone color-grade LUT — Blizzard-style saturated COOL shadows + warm
# highlights, generated in code. Moved out of world_view.gd (T-408, at the 1000-line lint cap).
# T-408: `smog` (0..1) folds in the Ashmoor sepia-desaturation on top; smog==0 is byte-for-byte the
# original grade (both new lerps are the identity at t==0), so era 0 stays a zero-regression grade.
static func make_zone_lut(smog := 0.0) -> ImageTexture3D:
	var images := make_zone_lut_images(smog)
	var n := images.size()
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RGB8, n, n, n, false, images)
	return tex


# The raw LUT slices — pure (no GPU), so a headless test can byte-compare them (ImageTexture3D
# get_data() returns nothing under the dummy renderer). make_zone_lut wraps it into the 3D texture.
static func make_zone_lut_images(smog := 0.0) -> Array[Image]:
	var n := 17
	var images: Array[Image] = []
	for bi in range(n):
		var img := Image.create(n, n, false, Image.FORMAT_RGB8)
		for gi in range(n):
			for ri in range(n):
				var c := Vector3(ri, gi, bi) / float(n - 1)
				var lum := c.dot(Vector3(0.2126, 0.7152, 0.0722))
				var shadow := 1.0 - smoothstep(0.18, 0.55, lum)
				var highlight := smoothstep(0.55, 0.95, lum)
				# shadows: cool + saturated, never grey
				c = c.lerp(Vector3(0.20, 0.26, 0.45) * (0.4 + lum), shadow * 0.22)
				c += Vector3(0.05, 0.02, -0.03) * shadow
				# highlights: warm golden lift
				c += Vector3(0.06, 0.045, 0.01) * highlight
				# gentle S-curve contrast
				c = c.lerp(Vector3(0.5, 0.5, 0.5), -0.06)
				# T-408: desaturate toward luma, then tint the grey warm-sepia (coal-smog haze)
				c = c.lerp(Vector3(lum, lum, lum), smog * 0.6)
				c = c.lerp(Vector3(lum * 1.10, lum * 0.98, lum * 0.78), smog * 0.5)
				img.set_pixel(
					ri, gi, Color(clampf(c.x, 0, 1), clampf(c.y, 0, 1), clampf(c.z, 0, 1))
				)
		images.append(img)
	return images
