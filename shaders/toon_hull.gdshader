shader_type spatial;
// Inverted-hull outline for one character: a second pass that draws the
// mesh's back faces pushed out along their normals in solid ink. Runs after
// GPU skinning, so it follows the animated body. Per-object, unlike the
// screen-space post_outline pass that covers the whole scene.
render_mode cull_front, unshaded, depth_draw_opaque, shadows_disabled;

uniform vec4 ink : source_color = vec4(0.0, 0.0, 0.0, 1.0);
// Line thickness in metres at 1 m; scaled with distance so the line keeps a
// roughly constant screen width instead of vanishing far away.
uniform float thickness : hint_range(0.0, 0.05) = 0.006;
uniform float distance_scale : hint_range(0.0, 1.0) = 0.5;

void vertex() {
	vec4 world = MODEL_MATRIX * vec4(VERTEX, 1.0);
	float dist = length((VIEW_MATRIX * world).xyz);
	float push = thickness * mix(1.0, dist, distance_scale);
	VERTEX += NORMAL * push;
}

void fragment() {
	ALBEDO = ink.rgb;
}
