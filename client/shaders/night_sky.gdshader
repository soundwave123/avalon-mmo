shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

// T-404: the night sky dome — a procedural STARFIELD + a MOON DISC composited OVER the physical
// sky (PhysicalSkyMaterial owns the day gradient/scattering; T-185). This is a camera-anchored
// transparent sphere: one draw call, texture-free. star_alpha/moon_alpha are driven each frame by
// night_sky.gd off the T-289 sun elevation, so at DAY both are 0 and world_view hides the whole
// dome — daytime rendering stays byte-identical (the T-408 zero-regression discipline). The dome is
// translated to the camera but NEVER rotated, so the stars sit fixed in the world as the view pans.

uniform float star_alpha : hint_range(0.0, 1.0) = 0.0;  // global star opacity (night fade)
uniform float star_density : hint_range(0.0, 0.2) = 0.035;  // fraction of grid cells that hold a star
uniform float moon_alpha : hint_range(0.0, 1.0) = 0.0;  // global moon opacity (night + above-horizon)
uniform vec3 moon_dir = vec3(0.0, 1.0, 0.0);  // world-space direction TO the moon (unit)
uniform float moon_size : hint_range(0.005, 0.4) = 0.05;  // angular disc radius in EYEDIR units
uniform float moon_halo : hint_range(1.0, 300.0) = 60.0;  // halo falloff exponent (higher = tighter)
uniform vec3 star_tint : source_color = vec3(0.82, 0.88, 1.0);  // cool white stars
uniform vec3 moon_tint : source_color = vec3(0.90, 0.93, 1.0);  // pale cool moon

varying vec3 v_dir;

void vertex() {
	// Dome is centred on the camera and translation-only (world_view sets its origin, never its
	// basis), so the outward local vertex direction equals the world view direction for that pixel.
	v_dir = normalize(VERTEX);
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec3 dir = normalize(v_dir);
	// Stars only in the upper hemisphere, fading out toward the horizon so they never punch through
	// hills/mountains at the skyline (an overhead-only field also dodges the projection stretch).
	float upper = smoothstep(0.02, 0.25, dir.y);

	// Cheap procedural stars: project the dome to a plane, quantise onto a coarse grid, hash each
	// cell; a sparse subset lights a soft point of varied brightness. No texture -> one draw call.
	vec2 guv = dir.xz / (dir.y + 0.6);
	float cells = 130.0;
	vec2 cell = floor(guv * cells);
	float h = hash21(cell);
	float star = 0.0;
	if (h > 1.0 - star_density) {
		vec2 f = fract(guv * cells) - 0.5;
		float d = length(f);
		float bright = hash21(cell + 3.7);
		star = smoothstep(0.30, 0.0, d) * (0.35 + 0.65 * bright);
	}
	star *= upper;

	// Moon: a crisp disc with a soft halo, tracking the anti-solar arc.
	float md = distance(dir, normalize(moon_dir));
	float disc = smoothstep(moon_size, moon_size * 0.6, md);
	float halo = pow(clamp(1.0 - md, 0.0, 1.0), moon_halo);
	float moon = clamp(disc + halo * 0.55, 0.0, 1.0);

	vec3 col = star_tint * (star * star_alpha) + moon_tint * (moon * moon_alpha);
	float a = clamp(star * star_alpha + moon * moon_alpha, 0.0, 1.0);
	ALBEDO = col;
	ALPHA = a;
}
