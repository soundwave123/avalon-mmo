// T-140: wind-sway for foliage (grass tufts, later tree cards). Unshaded painterly
// look preserved; the top of each blade sways while the base stays planted. Per-
// instance phase (from MODEL_MATRIX world position) so a MultiMesh field ripples
// instead of swaying in unison — the signature WoW grass motion.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec3 albedo : source_color = vec3(0.24, 0.40, 0.13);
uniform float wind_strength = 0.10;
uniform float wind_speed = 1.4;
uniform float sway_height = 0.42; // local Y of the blade tip; weights the sway

void vertex() {
	float w = clamp(VERTEX.y / sway_height, 0.0, 1.0); // 0 base -> 1 tip
	float phase = (MODEL_MATRIX[3].x + MODEL_MATRIX[3].z) * 0.6;
	VERTEX.x += sin(TIME * wind_speed + phase) * wind_strength * w;
	VERTEX.z += cos(TIME * wind_speed * 0.7 + phase) * wind_strength * w * 0.5;
}

void fragment() {
	ALBEDO = albedo;
}
