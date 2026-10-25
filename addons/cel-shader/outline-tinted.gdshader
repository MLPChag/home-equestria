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
// Anon's skin parts meet at open seams (world/customization/anon_garments.gd); a hull there
// shows as a black ring. Their vertex alpha falls to 0 at a seam, and only materials that set
// this flag read it, so every other mesh keeps its full line.
uniform bool width_from_vertex_alpha = false;
uniform bool native_eye_socket_mask = false;
#include "res://world/characters/openpony/eye_socket_outline.gdshaderinc"
// HOME-EQUESTRIA: the coat's slap wobble, so the hull moves with the coat.
#include "res://world/characters/hybrid_mare/flank_jiggle.gdshaderinc"

void vertex() {
	VERTEX += flank_jiggle(VERTEX);
	if (!native_eye_socket_mask || !inside_native_eye_socket(UV)) {
		VERTEX += normalize(NORMAL) * outline_width * (width_from_vertex_alpha ? COLOR.a : 1.0);
	}
}

void fragment() {
	if (native_eye_socket_mask && inside_native_eye_socket(UV)) { discard; }
	ALBEDO = outline_color.rgb * brightness;
}
