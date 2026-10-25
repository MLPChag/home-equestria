shader_type spatial;
// Blue door-handle glow shown while a hand can grip the handle (hinged_door.gd).
// Camera-facing, drawn over the leaf so it reads from either side of the door.
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled;
instance uniform vec4 glow_color : source_color = vec4(0.35, 0.65, 1.0, 1.0);
instance uniform float glow_level = 0.0;

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX[3].z += 0.03;
}

void fragment() {
	float radius = length(UV * 2.0 - 1.0);
	float halo = pow(max(0.0, 1.0 - radius), 2.5);
	float core = 1.0 - smoothstep(0.0, 0.22, radius);
	ALBEDO = glow_color.rgb * (0.7 + core);
	ALPHA = (halo * 0.6 + core * 0.5) * glow_level;
}
