// eldskald's godot4-cel-shader outline (addons/cel-shader/outline.gdshader,
// MIT) with the two global uniforms turned into per-material uniforms, so a
// character can carry a coloured line (Rainbow Dash: coat #6BABDA, mane and
// tail #1B98D1 per kefkafloyd's colour guide) next to Anon's black one.
// The line is a hull grown by `outline_width` METRES along the normal, so it
// stays the same size in the world: the original's screen-pixel width made
// far characters read as mostly outline (dev, 2026-09-06, headset round 5).
shader_type spatial;

render_mode cull_front, unshaded, depth_draw_never;

uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float outline_width = 0.008;
// The hull is unshaded, so a coloured line stayed daylight-bright at night
// (dev, 2026-09-07). Script drives this from the time of day.
uniform float brightness = 1.0;

uniform vec3 hand_center = vec3(0.0);
varying vec3 world_position;
void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX += normalize(NORMAL) * outline_width;
}

void fragment() {
	if (distance(world_position, hand_center) > 0.14) discard;
	ALBEDO = outline_color.rgb * brightness;
}
