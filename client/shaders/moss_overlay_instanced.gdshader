// T-693: the T-290 moss/weathering overlay, ported to MultiMesh instancing. Identical bias story
// to moss_overlay.gdshader (north/NE moss, damp-base height falloff, water-stain streaks) with ONE
// difference: `ground_y` — the only per-PROP parameter — comes from the MultiMesh per-instance
// INSTANCE_CUSTOM data (x = the placement's world base Y) instead of a per-prop uniform, so ONE
// shared ShaderMaterial serves every instance of a batched mesh without breaking the single-draw
// batch (per-instance material overrides would re-split it — the exact thing T-693 removes).
// Class-level grading (moss_amount/roof_weight/climb_h) stays uniform: a MultiMesh pool is
// per-mesh, so the class is constant across its instances.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;

// Per-CLASS (set once per batched mesh's shared material); intensity graded by age/wealth.
uniform float moss_amount : hint_range(0.0, 1.0) = 0.5;
uniform float roof_weight : hint_range(0.0, 1.0) = 1.0;  // 0 on trees so the canopy stays clean
uniform float climb_h = 1.4;     // metres moss climbs from the base before it fades out

// Shared palette (world-conventions / T-290 visual spec).
uniform vec3 moss_color : source_color = vec3(0.19, 0.29, 0.13);
uniform vec3 lichen_color : source_color = vec3(0.52, 0.56, 0.47);
uniform vec3 damp_color : source_color = vec3(0.11, 0.12, 0.11);

varying vec3 w_pos;
varying vec3 w_nrm;
varying float ground_y;  // per-instance: INSTANCE_CUSTOM.x = the prop's world base Y

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	w_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	ground_y = INSTANCE_CUSTOM.x;
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
