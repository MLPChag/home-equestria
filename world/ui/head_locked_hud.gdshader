shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled;

uniform sampler2D hud_texture : source_color, filter_linear, repeat_disable;
uniform vec3 head_center = vec3(0.0, 0.0, -1.5);

void vertex() {
	// EYE_OFFSET is in view space. Retain binocular parallax about the center
	// head pose while deliberately bypassing MODELVIEW_MATRIX and its late pose.
	POSITION = PROJECTION_MATRIX * vec4(VERTEX + head_center - EYE_OFFSET, 1.0);
}

void fragment() {
	vec4 hud = texture(hud_texture, UV);
	ALBEDO = hud.rgb;
	ALPHA = hud.a;
}
