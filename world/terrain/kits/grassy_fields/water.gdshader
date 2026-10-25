shader_type spatial;
render_mode blend_mix, depth_draw_never;

uniform sampler2D water_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D water_noise : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 absorption_color : source_color = vec4(1.0, 0.01, 0.0, 1.0);
uniform float murkiness = 0.02;
uniform float water_opacity = 0.0;
uniform float roughness = 0.1;
uniform float metalness = 0.01;
uniform float specular = 0.2;
uniform float wave_strength = 0.5;
uniform float wave_scale_cm = 900.0;
uniform float ripple_size = 3.0;
uniform float ripple_speed = -20.0;
uniform float ripple_strength = -100.0;
uniform float breakup_speed = -1.0;
uniform float waves_speed = 0.5;
uniform float refraction_index = 1.0188;
uniform float white_water_rim_size_cm = 8.0;
uniform float white_water_ripple_distance_cm = 90.0;
uniform bool use_distance_field_refraction = true;
uniform bool move_ripples_over_time = true;
uniform bool show_white_water = true;
uniform float review_time = -1.0;
uniform bool effects_enabled = true;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear, repeat_disable;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear, repeat_disable;
uniform float nearest_surface_distance_m = -1.0;
varying vec3 world_position;
varying float fragment_view_z_m;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	fragment_view_z_m = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}

// Source BlendAngleCorrectedNormals, converted to OpenGL tangent convention.
vec3 combine_normals(vec3 a, vec3 b) {
	vec3 t = a + vec3(0.0, 0.0, 1.0);
	vec3 u = b * vec3(-1.0, -1.0, 1.0);
	return normalize(t * dot(t, u) / max(t.z, 0.00001) - u);
}
void fragment() {
	float t = effects_enabled ? (review_time < 0.0 ? TIME : review_time) : 0.0;
	vec2 world_uv = world_position.xz / max(wave_scale_cm * 0.01, 0.001);
	vec3 na = texture(water_normal, world_uv + vec2(-0.08, 0.04) * waves_speed * t).rgb * 2.0 - 1.0;
	vec3 nb = texture(water_normal, world_uv + vec2(0.08, 0.10) * waves_speed * t).rgb * 2.0 - 1.0;
	na.y = -na.y;
	nb.y = -nb.y;
	vec3 n = normalize(mix(vec3(0.0, 0.0, 1.0), combine_normals(na, nb), wave_strength));
	float raw_depth = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, raw_depth) * 2.0 - 1.0;
	#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
	#endif
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	scene_view.xyz /= scene_view.w;
	float thickness_m = max(-scene_view.z - fragment_view_z_m, 0.0);
	vec3 scene_world = (INV_VIEW_MATRIX * vec4(scene_view.xyz, 1.0)).xyz;
	// UE DistanceToNearestSurface requires a world distance field. The isolated
	// review falls back to the surface visible behind water in this viewport.
	float distance_cm = (nearest_surface_distance_m >= 0.0 ? nearest_surface_distance_m
		: length(scene_world - world_position)) * 100.0;
	float shore = clamp(1.0 - distance_cm / max(white_water_ripple_distance_cm, 0.001), 0.0, 1.0);
	float rim = clamp(1.0 - distance_cm / max(white_water_rim_size_cm, 0.001), 0.0, 1.0);
	float phase = shore + (move_ripples_over_time ? t / (abs(ripple_speed) < 0.0001 ? 0.0001 : ripple_speed) : 0.0);
	float wave = shore * sin(phase * ripple_size * 6.28318530718);
	float noise_value = texture(water_noise, UV * 5.0 + vec2(0.03, 0.01) * breakup_speed * t).r;
	float source_opacity = water_opacity;
	if (use_distance_field_refraction && show_white_water) {
		source_opacity = clamp((clamp(wave - 0.3, 0.0, 1.0) + rim - noise_value) / 0.2, 0.0, 1.0);
	}
	float ior = refraction_index;
	if (use_distance_field_refraction) {
		ior += wave / (abs(ripple_strength) < 0.0001 ? 0.0001 : ripple_strength);
	}
	vec2 screen_offset = n.xy * (ior - 1.0);
	vec3 behind = texture(SCREEN_TEXTURE, clamp(SCREEN_UV + screen_offset, vec2(0.001), vec2(0.999))).rgb;
	// Source scattering=0, absorption=AbsorptionColor*Murkiness in UE cm.
	// This is a screen-space single-layer composite, not Unreal's water renderer.
	vec3 transmission = exp(-max(absorption_color.rgb, vec3(0.0)) * max(murkiness, 0.0) * thickness_m * 100.0);
	ALBEDO = vec3(clamp(source_opacity, 0.0, 1.0));
	EMISSION = behind * transmission * (1.0 - clamp(source_opacity, 0.0, 1.0));
	NORMAL_MAP = n * 0.5 + 0.5;
	ROUGHNESS = roughness;
	METALLIC = metalness;
	SPECULAR = specular;
	// Screen/depth readers run after opaque objects in Godot. Alpha=1 composites
	// the scene sample once; depth_draw_never avoids a depth prepass hiding it.
	ALPHA = 1.0;
}
