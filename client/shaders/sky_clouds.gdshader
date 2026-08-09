shader_type sky;
render_mode use_half_res_pass;

// T-084: beautiful day sky — atmospheric gradient + horizon glow + sun disc + animated
// procedural clouds. Adapted from the CC0 "Stylized Sky Shader with Clouds" (godotshaders.com).
// Cloud noise textures are generated seamlessly in GDScript (world_view.gd). LIGHT0_DIRECTION
// is fed automatically by the scene's DirectionalLight3D, so the sun/horizon track the sun and
// this stays ready for the day/night cycle (T-137).

uniform vec3 day_top_color : source_color = vec3(0.19, 0.44, 0.82);
uniform vec3 day_bottom_color : source_color = vec3(0.52, 0.72, 0.93);
uniform vec3 horizon_color : source_color = vec3(0.83, 0.88, 0.94);
uniform float horizon_falloff : hint_range(0.0, 1.0) = 0.13;

uniform vec3 sun_col : source_color = vec3(1.0, 0.96, 0.84);
uniform float sun_size : hint_range(0.01, 1.0) = 0.18;
uniform float sun_blur : hint_range(0.001, 1.0) = 0.06;
uniform float sun_glow : hint_range(0.0, 2.0) = 0.5;

uniform sampler2D clouds_texture : filter_linear_mipmap, repeat_enable;
uniform sampler2D clouds_distort_texture : filter_linear_mipmap, repeat_enable;
uniform sampler2D clouds_noise_texture : filter_linear_mipmap, repeat_enable;
uniform vec3 clouds_main_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 clouds_edge_color : source_color = vec3(0.78, 0.83, 0.92);
uniform float clouds_speed : hint_range(0.0, 0.2) = 0.015;
uniform float clouds_scale : hint_range(0.05, 2.0) = 0.3;
uniform float clouds_cutoff : hint_range(0.0, 1.0) = 0.22;
uniform float clouds_fuzziness : hint_range(0.0, 1.0) = 0.28;

void sky() {
	// Project the dome onto a plane above the camera for cloud UVs. The +0.35 bias compresses
	// the horizon stretch so clouds stay legible in the low sky band a 3rd-person camera sees.
	vec2 sky_uv = EYEDIR.xz / (EYEDIR.y + 0.35);
	float up = clamp(EYEDIR.y, 0.0, 1.0);

	// Atmosphere: vertical gradient with a warm glowing horizon band. T-170 round 8c: the warm band
	// was too TALL — at eye level (low EYEDIR.y) it swamped the cerulean and the sky read pink/milky.
	// pow(horizon, 5) keeps the warm gold a THIN band at the horizon line and lets deep blue read
	// just above it (WoW's "cerulean overhead -> warm gold at the horizon").
	vec3 gradient = mix(day_bottom_color, day_top_color, up);
	float horizon = clamp(1.0 - abs(EYEDIR.y + horizon_falloff), 0.0, 1.0);
	vec3 sky_col = mix(gradient, horizon_color, pow(horizon, 5.0));

	// Sun disc + soft glow, tracking the scene's sun.
	float sun_distance = distance(EYEDIR, LIGHT0_DIRECTION);
	float sun_power = 1.0 - clamp(sun_distance / sun_size, 0.0, 1.0);
	float sun_disc = clamp(sun_power / sun_blur, 0.0, 1.0);
	float glow = pow(max(dot(EYEDIR, LIGHT0_DIRECTION), 0.0), 8.0) * sun_glow;
	vec3 sun = sun_col * (sun_disc + glow);

	// Animated clouds: three seamless noise layers chained through each other's distortion.
	float mv = TIME * clouds_speed;
	float base = texture(clouds_texture, (sky_uv + mv) * clouds_scale).r;
	float n1 = texture(clouds_distort_texture, (sky_uv + base + mv * 0.75) * clouds_scale).r;
	float n2 = texture(clouds_noise_texture, (sky_uv + n1 + mv * 0.25) * clouds_scale).r;
	// Fade clouds in just above the horizon (not linearly to zenith) so they fill the low sky
	// band a third-person camera actually looks at, while staying off the horizon line itself.
	float cloud_mask = smoothstep(0.0, 0.14, EYEDIR.y);
	float cloud_n = clamp(n1 * n2, 0.0, 1.0) * cloud_mask;
	float cloud_v = clamp(smoothstep(clouds_cutoff, clouds_cutoff + clouds_fuzziness, cloud_n), 0.0, 1.0);
	// Shade cloud bellies toward the edge color; light the sun-facing side.
	vec3 cloud_col = mix(clouds_edge_color, clouds_main_color, cloud_v);
	cloud_col += sun_col * glow * 0.4;

	vec3 final = sky_col + sun * (1.0 - cloud_v);
	final = mix(final, cloud_col, cloud_v);
	COLOR = final;
}
