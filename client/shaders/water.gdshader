shader_type spatial;
render_mode cull_disabled, depth_draw_always;

// T-088/T-133: Crystal Lake water — summed-sine waves displace the surface; animated noise
// ripples perturb the normal for shimmer; low roughness reflects the sky (sky reflection).
// T-300/T-304: retuned away from pool-cyan toward natural muddy green-slate; grazing-angle
// sky sheen restored (the distance cue that reads "water", not "dark lawn").
// T-342: river_mode reuses the same surface as a flowing channel ribbon (transverse bank fade).
// T-441: REAL depth. The material now reads the scene depth buffer and reconstructs how much
// water the view ray crosses before hitting the bed/bank/foundation underneath:
//   - depth TINT: Beer-Lambert murk — shallow margins stay clear (the wet mud bed shows
//     through), deep water darkens toward deep_color and goes near-opaque. This replaces the
//     old UV-radius guess at "shallowness", so the pond and river read as one substance whose
//     colour comes from actual depth, killing the flat milky-sheet read.
//   - depth-FADE banks: alpha ramps in over edge_fade metres of vertical depth, so wherever
//     the plane meets terrain or a foundation the waterline is a soft wet margin, never a
//     razor line of blue across dry grass.
//   - sheen_strength: world_view drives the fresnel sky sheen with the day/night arc so the
//     surface doesn't glow milky-bright at night.
//   - flow_speed (river_mode): the ripple field drifts along-channel — faint flow.

uniform vec3 deep_color : source_color = vec3(0.05, 0.13, 0.13);
uniform vec3 shallow_color : source_color = vec3(0.27, 0.33, 0.21);
uniform vec3 sky_color : source_color = vec3(0.66, 0.76, 0.88); // grazing-angle sheen tint
uniform float sheen_strength : hint_range(0.0, 1.0) = 1.0; // day/night sheen driver (T-441)
uniform float roughness_val : hint_range(0.0, 1.0) = 0.04;
// T-441 retune: 2.2 washed the WHOLE surface toward sky_color from any low camera (the milky
// read); 3.0 confines the painted sheen to truly grazing angles — the depth tint carries the
// body colour, the real sky reflection (low roughness) still gives the distance cue.
uniform float fresnel_power : hint_range(0.5, 6.0) = 3.0;
uniform float wave_speed : hint_range(0.0, 3.0) = 0.7;
uniform float wave_height : hint_range(0.0, 0.6) = 0.11;
uniform float wave_freq : hint_range(0.1, 4.0) = 1.3;
uniform float ripple_strength : hint_range(0.0, 1.0) = 0.35;
uniform sampler2D ripple_noise : filter_linear_mipmap, repeat_enable;
// T-179 shore carve: a STATIC (non-scrolling) low-frequency field perturbs the waterline RADIUS so
// the lake reads as a blobby pond, not the square silhouette of its plane. The waterline is kept
// below the plane edge (base + wobble <= ~0.9 of the half-plane) so no mesh corner/edge survives;
// everything past the waterline is discarded.
uniform sampler2D shore_noise : filter_linear_mipmap, repeat_enable;
uniform float waterline_base : hint_range(0.4, 1.0) = 0.82; // mean rim, in half-plane units
uniform float waterline_wobble : hint_range(0.0, 0.3) = 0.10; // rim excursion (+/- of base)
uniform float shore_softness : hint_range(0.005, 0.3) = 0.10; // alpha falloff width at the rim
// T-342: river_mode swaps the lake's RADIAL waterline carve for a TRANSVERSE one — the bank fade
// runs off the ribbon's across-channel coordinate (UV.y in [0,1], centre 0.5) so the same surface
// reads as a flowing channel with two banks, not a disc. UV.x (along-channel) never discards.
uniform bool river_mode = false;
uniform float flow_speed : hint_range(0.0, 2.0) = 0.0; // river ripple drift (uv units/s)
// T-441 depth read: Beer-Lambert murk per metre of (vertical) water depth, and the vertical
// depth over which the bank alpha ramps from 0 to full — the soft shoreline.
uniform float absorption : hint_range(0.1, 8.0) = 2.6;
uniform float edge_fade : hint_range(0.02, 1.0) = 0.22;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;


// The bank/shore coordinate: 0 mid-water, 1 at the discard edge. Radial for a lake disc,
// transverse (across the ribbon) for a river.
float _bankline_rad(vec2 uv) {
	if (river_mode) {
		return abs(uv.y - 0.5) * 2.0;
	}
	return length(uv - vec2(0.5)) * 2.0;
}


float _wave(vec2 p, float t) {
	float w = sin(p.x * wave_freq + t) * 0.5;
	w += sin(p.y * wave_freq * 1.3 + t * 1.1) * 0.3;
	w += sin((p.x + p.y) * wave_freq * 0.7 + t * 0.8) * 0.2;
	return w;
}


// T-441: vertical water depth under this fragment — reconstruct the opaque scene position from
// the depth buffer (Forward+/Mobile: Vulkan NDC, z in [0,1], reverse-z handled by the inverse
// projection), take the view-ray distance THROUGH the water, and project it onto world-down so
// a grazing ray over a shallow margin still reports the true (small) depth of the bed it hits.
float _water_depth(vec2 screen_uv, mat4 inv_proj, mat4 inv_view, vec3 view_vertex) {
	float raw = texture(depth_texture, screen_uv).x;
	vec3 ndc = vec3(screen_uv * 2.0 - 1.0, raw);
	vec4 vpos = inv_proj * vec4(ndc, 1.0);
	float scene_dist = -vpos.z / vpos.w;
	float thick = max(scene_dist + view_vertex.z, 0.0); // ray length water-surface -> bed
	vec3 wdir = (inv_view * vec4(normalize(view_vertex), 0.0)).xyz;
	return thick * max(abs(wdir.y), 0.02);
}


void vertex() {
	float t = TIME * wave_speed;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Calm the surface toward the shore so waves never poke through the thin waterline alpha.
	float rad = _bankline_rad(UV);
	float calm = 1.0 - smoothstep(0.55, waterline_base + waterline_wobble, rad);
	VERTEX.y += _wave(wp.xz, t) * wave_height * calm;
}


void fragment() {
	// --- T-179/T-342 shore carve: fade alpha to 0 past a noise-perturbed waterline (radial for a
	//     lake disc, transverse across the channel for a river) ---
	float rad = _bankline_rad(UV); // 0 at centre, 1.0 at the discard edge
	// static low-freq wobble field; for a river, wobble the two banks along the channel length.
	vec2 nuv = river_mode ? vec2(UV.x * 0.15, UV.y) : UV + vec2(0.37, 0.11);
	float ncar = texture(shore_noise, nuv).r;
	float wobble = clamp((ncar - 0.5) * 2.6, -1.0, 1.0);
	float waterline = waterline_base + waterline_wobble * wobble; // <= ~0.9 -> never hits the edge
	float water_mask = 1.0 - smoothstep(waterline - shore_softness, waterline, rad);
	if (water_mask < 0.01) {
		discard; // kill the square: no mesh corner/edge survives, and no stray depth is written
	}

	// --- T-441: real depth drives colour and opacity ---
	float depth_v = _water_depth(SCREEN_UV, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX, VERTEX);
	float murk = 1.0 - exp(-depth_v * absorption); // Beer-Lambert: deeper = murkier/darker
	float edge = smoothstep(0.0, edge_fade, depth_v); // soft wet margin, no razor bank line

	float t = TIME * 0.04;
	vec2 uv = UV * 8.0;
	if (river_mode) {
		uv.x -= TIME * flow_speed; // faint downstream drift of the shimmer field
	}
	// Two scrolling noise samples -> a shimmering ripple normal (tangent space).
	vec3 n1 = texture(ripple_noise, uv + vec2(t, t * 0.7)).rgb;
	vec3 n2 = texture(ripple_noise, uv * 1.7 - vec2(t * 0.8, t)).rgb;
	vec2 perturb = (vec2(n1.r + n2.r, n1.g + n2.g) - 1.0) * ripple_strength;
	NORMAL_MAP = normalize(vec3(perturb, 1.0));
	NORMAL_MAP_DEPTH = 1.0;

	// Down-angle body colour: clear olive shallows where the bed is near, dark slate murk where
	// the water is deep (T-300/T-304 palette, now driven by TRUE depth, not a UV-radius guess).
	vec3 body = mix(shallow_color, deep_color, murk);
	// Grazing-angle sky sheen: at shallow view angles the surface mirrors the sky — the distance
	// cue for "water" vs "lawn". Scaled by sheen_strength so night water doesn't glow milky.
	float fres = pow(1.0 - clamp(dot(normalize(VIEW), NORMAL), 0.0, 1.0), fresnel_power);
	float sheen = fres * mix(0.2, 0.8, sheen_strength); // capped: never a full white-out
	ALBEDO = mix(body, sky_color, sheen);
	METALLIC = 0.0;
	ROUGHNESS = mix(roughness_val, roughness_val * 0.25, fres); // glossier at grazing angles
	SPECULAR = mix(0.6, 1.0, fres); // sun glint rides the standard light pass
	// Opacity: shallow margins stay clear (the bed reads through), deep water goes near-opaque;
	// the sheen only modestly lifts alpha (the old +0.3 boost was the milky-sheet culprit).
	float a_body = mix(0.30, 0.94, murk);
	ALPHA = clamp(a_body + sheen * 0.15, 0.0, 1.0) * water_mask * edge;
}
