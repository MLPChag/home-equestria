shader_type spatial;
// The "MLP Magic Auras" disc (Steam Workshop 690684980, pma_renderer.lua DrawAura): a fan that
// always faces the camera, its rim rippling, coloured by the aura gradient (UV.x 0 at the rim,
// 1 at the centre), drawn over everything like the original's cam.IgnoreZ.
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D gradient : source_color, filter_linear, repeat_disable;
uniform vec4 aura_color : source_color = vec4(1.0, 0.0, 0.588, 1.0);
uniform float alpha = 0.0;
// pma_renderer.lua: WAVE_SPEED, WAVE_FREQUENCY, WAVE_AMPLITUDE.
uniform float wave_speed = 10.0;
uniform float wave_frequency = 10.0;
uniform float wave_amplitude = 0.07;

void vertex() {
	// Facing the camera at the node's scale (Godot's billboard with kept scale).
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	// Only rim vertices ripple: sin(t * speed + cos(angle) * frequency) * amplitude, sideways.
	float rim = 1.0 - UV.x;
	VERTEX.x += rim * sin(TIME * wave_speed + cos(UV2.x) * wave_frequency) * wave_amplitude;
}

void fragment() {
	vec4 g = texture(gradient, vec2(clamp(UV.x, 0.0, 1.0), 0.5));
	ALBEDO = aura_color.rgb * g.rgb;
	ALPHA = g.a * alpha;
}
