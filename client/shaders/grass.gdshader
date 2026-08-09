shader_type spatial;
render_mode cull_disabled, diffuse_toon, specular_disabled;

// T-090/T-140: lush wind-animated blade grass for MultiMesh. Adapted from the CC0
// "Stylized Multimesh Grass Shader" (godotshaders.com). Blades carry UVs with UV.y=1 at the
// base and UV.y=0 at the tip; wind bends the tip, a base->tip color gradient + baked AO give
// soft depth. NORMAL is forced up so dense blades light softly instead of reading as dark
// spikes (the T-140 v1 finding). Wind is sampled in WORLD space so the whole field moves as
// one gust rather than each blade dancing independently.

uniform vec3 top_color : source_color = vec3(0.48, 0.66, 0.24);
uniform vec3 bottom_color : source_color = vec3(0.12, 0.25, 0.08);
uniform float ao_factor : hint_range(0.0, 1.0) = 0.4;
uniform float roughness_val : hint_range(0.0, 1.0) = 0.92;

uniform vec3 wind_direction = vec3(1.0, 0.0, 0.55);
uniform float wind_strength : hint_range(0.0, 1.0) = 0.11;  // gentle sway, not a frantic sea
uniform sampler2D wind_noise : filter_linear_mipmap, repeat_enable;
uniform float wind_noise_size : hint_range(0.0, 0.2) = 0.02;
uniform float wind_noise_speed : hint_range(0.0, 1.0) = 0.045;

void vertex() {
	vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 flow = normalize(-wind_direction.xz) * (TIME + UV.y / 2.5) * wind_noise_speed;
	vec3 wind_tex = texture(wind_noise, world_position.xz * wind_noise_size + flow).rgb;
	vec3 wind_vector = (vec4(wind_tex * normalize(wind_direction) * wind_strength, 0.0) * MODEL_MATRIX).xyz;
	// Bend most at the tip (UV.y -> 0), anchored at the base (UV.y -> 1).
	VERTEX += wind_vector * (1.0 - UV.y);
	NORMAL = vec3(0.0, 1.0, 0.0);
}

void fragment() {
	vec3 color = mix(bottom_color, top_color, 1.0 - UV.y);
	float ao = pow(UV.y, 4.0);
	ALBEDO = mix(color, bottom_color * (1.0 - ao_factor), ao);
	ROUGHNESS = roughness_val;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
