// Native PSD color base on OpenPony's original pupil card. The source's
// ellipse/UV padding is preserved; only its paint color becomes Dash's iris.
// No blink mask: the Bento face geometry closes over these eye cards.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_burley, specular_schlick_ggx;

uniform sampler2D color_layer : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 iris_color : source_color = vec4(0.77, 0.17, 0.48, 1.0);
uniform vec2 gaze_uv = vec2(0.0);
uniform float iris_scale : hint_range(0.5, 2.0) = 1.25;

void fragment() {
	vec2 eye_uv = (UV - vec2(0.5) - gaze_uv) / iris_scale + vec2(0.5);
	ALBEDO = iris_color.rgb;
	ALPHA = texture(color_layer, eye_uv).a;
	if (ALPHA < 0.01) { discard; }
	ROUGHNESS = 0.28;
	SPECULAR = 0.35;
}
