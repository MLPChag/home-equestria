shader_type spatial;
render_mode unshaded, fog_disabled, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled;

// Alpha-composite onto the finished scene: no screen copy, blur or VR view distortion.
// Sample depth directly here; passing this sampler to a function breaks XR multiview.
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
uniform float immersion = 0.0;
uniform float surface_y = 0.0;
uniform float daylight = 1.0;
uniform vec3 water_color : source_color = vec3(0.12, 0.46, 0.49);

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	float depth = texture(depth_texture, SCREEN_UV).r;
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
	#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	#endif
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vec3 position_view = view.xyz / max(view.w, 0.000001);
	float distance_to_scene = length(position_view);
	vec3 ray_world = mat3(INV_VIEW_MATRIX) * normalize(position_view);
	float below_surface = max(0.0, surface_y - INV_VIEW_MATRIX[3].y);
	// Looking up through the surface should reveal daylight, not fog all the way to the sky.
	float water_distance = min(distance_to_scene, 60.0);
	if (ray_world.y > 0.001) {
		water_distance = min(water_distance, below_surface / ray_world.y);
	}
	float haze = 1.0 - exp(-water_distance * 0.19);
	float deep_shade = exp(-below_surface * 0.055);
	ALBEDO = water_color * mix(0.035, 0.8, daylight) * deep_shade;
	ALPHA = immersion * clamp(0.075 + haze * 0.91, 0.0, 0.975);
}
