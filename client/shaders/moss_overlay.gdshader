// T-290: sun-keyed weathering overlay — moss/lichen on the shaded (north/NE) & damp faces,
// downward water-staining on vertical faces, keyed to the T-289 sun convention (-Z = north,
// docs/design/world-conventions.md). Applied as a per-prop GeometryInstance3D.material_overlay
// in world_props_layer.gd — a cheap, honest second pass that reads WORLD-SPACE normal + height,
// never a uniform tint. It does NOT modify any GLB, so it co-exists with the T-296 house regen.
//
// Bias story (physics-consistent):
//   * north/NE vertical faces  -> moss climbs from the damp base upward (height falloff)
//   * up-facing NORTH roof/kerb -> moss on the shaded slope, not the sun-baked south slope
//   * vertical faces           -> faint downward damp streaks (water-staining under sills/eaves)
//   * broken up by world-space value noise so it reads as patches, never green paint
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;

// Per-prop (set from GDScript); intensity is graded by age/wealth at placement.
uniform float moss_amount : hint_range(0.0, 1.0) = 0.5;
uniform float roof_weight : hint_range(0.0, 1.0) = 1.0;  // 0 on trees so the canopy stays clean
uniform float ground_y = 0.0;    // world-Y the prop sits at — moss falloff origin
uniform float climb_h = 1.4;     // metres moss climbs from the base before it fades out

// Shared palette (world-conventions / T-290 visual spec).
uniform vec3 moss_color : source_color = vec3(0.19, 0.29, 0.13);
uniform vec3 lichen_color : source_color = vec3(0.52, 0.56, 0.47);
uniform vec3 damp_color : source_color = vec3(0.11, 0.12, 0.11);

varying vec3 w_pos;
varying vec3 w_nrm;

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	w_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i + vec3(0, 0, 0)), hash(i + vec3(1, 0, 0)), f.x),
				   mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
			   mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
				   mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	return 0.6 * vnoise(p) + 0.3 * vnoise(p * 2.3) + 0.1 * vnoise(p * 5.1);
}

void fragment() {
	vec3 n = normalize(w_nrm);
	// North/NE bias: -Z is north (+X east); a gentle NE lean, hard cut-off past due-south.
	vec3 shaded_dir = normalize(vec3(0.35, 0.0, -1.0));
	float north = smoothstep(0.05, 0.7, dot(n, shaded_dir));
	// Height falloff — moss is a damp-base phenomenon; strongest at the ground, gone up high.
	float h = clamp(1.0 - (w_pos.y - ground_y) / climb_h, 0.0, 1.0);
	float wall_moss = north * mix(0.15, 1.0, h);
	// North-leaning up-faces (roof slopes, kerbs, wall tops) — no height falloff (roofs are high).
	float roof_moss = roof_weight * clamp(n.y, 0.0, 1.0) * smoothstep(-0.15, 0.45, -n.z);
	float face = max(wall_moss, roof_moss);
	// Patchiness — carve the coverage into blotches so it never reads as a flat wash.
	float patch = fbm(w_pos * 1.6 + 11.0);
	float cover = face * moss_amount * smoothstep(0.34, 0.72, patch);
	// Moss vs pale lichen crust, by a finer noise band.
	vec3 col = mix(moss_color, lichen_color, smoothstep(0.5, 0.9, fbm(w_pos * 5.5)));
	// Downward water-stain streaks on vertical faces: vertically-stretched noise, fades with height.
	float vertical = clamp(1.0 - abs(n.y) * 2.0, 0.0, 1.0);
	float streak = smoothstep(0.55, 1.0, fbm(vec3(w_pos.x * 7.0, w_pos.y * 0.5, w_pos.z * 7.0)));
	float damp = vertical * streak * h * 0.45 * moss_amount;

	ALBEDO = mix(col, damp_color, clamp(damp / max(cover + damp, 0.001), 0.0, 1.0));
	ALPHA = clamp(cover + damp, 0.0, 0.82);
	ROUGHNESS = 1.0;
}
