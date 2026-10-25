shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_prepass_alpha;

uniform sampler2D fog_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 fog_color : source_color = vec4(1.0);
uniform vec2 noise_speed = vec2(-0.01, 0.005);
uniform float opacity = 1.0;
uniform float depth_fade_opacity = 0.3364;
uniform float depth_fade_distance_cm = 4373.5;
uniform float distance_start_cm = 50000.0;
uniform float noise_scale = 1.0;
uniform float brightness = 18.0;
uniform float sphere_fade_attenuation_cm = 5000.0;
uniform float review_time = -1.0;
uniform bool effects_enabled = true;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear, repeat_disable;
varying float source_distance_m;
varying float fragment_view_z_m;

void vertex() {
	source_distance_m = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
	fragment_view_z_m = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}

void fragment() {
	float t = review_time < 0.0 ? TIME : review_time;
	vec2 uv = UV * noise_scale;
	vec2 drift = effects_enabled ? noise_speed * t : vec2(0.0);
	float shape = texture(fog_texture, UV).g;
	float noise = texture(noise_texture, uv + drift).r;
	float depth_fade = 1.0;
	if (depth_fade_distance_cm > 0.0) {
		float scene_depth = texture(DEPTH_TEXTURE, SCREEN_UV).r;
		#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		vec3 ndc = vec3(SCREEN_UV, scene_depth) * 2.0 - 1.0;
		#else
		vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, scene_depth);
		#endif
		vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		scene_view /= scene_view.w;
		float scene_depth_m = -scene_view.z;
		float frag_depth_m = fragment_view_z_m;
		depth_fade = clamp(max(scene_depth_m - frag_depth_m, 0.0) / max(depth_fade_distance_cm * 0.01, 0.001), 0.0, 1.0);
		depth_fade *= depth_fade_opacity;
	}
	// UE SphereMask(pixel depth, 0, radius=start, attenuation=5000),
	// followed by OneMinus: zero near the camera and one after the fade band.
	float fade_radius_m = distance_start_cm * 0.01;
	// Radius is wired, so AttenuationRadius default is unused. Hardness=10%.
	float sphere_mask = clamp((1.0 - fragment_view_z_m / max(fade_radius_m, 0.001)) / 0.9, 0.0, 1.0);
	float distance_fade = 1.0 - sphere_mask;
	ALBEDO = fog_color.rgb * brightness;
	ALPHA = shape * noise * opacity * depth_fade * distance_fade;
}
