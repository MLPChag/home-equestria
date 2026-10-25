shader_type spatial;
// Blue cel outline around whatever a hand can use right now (dev 2026-09-30: "the vrchat blue
// box wireframe should be replaced with a blue glow cel shade outline on an interactible
// item"). Drawn as a material_overlay: the mesh's back faces pushed out along their world
// normals, so the rim shows only around the silhouette, like the pony ink hulls
// (toon_hull.gdshader) but in glowing blue and measured in world metres, so a 10x-scaled house
// door gets the same line as a hand-sized apple.
render_mode world_vertex_coords, cull_front, unshaded, depth_draw_opaque, shadows_disabled, fog_disabled;

uniform vec4 ink : source_color = vec4(0.36, 0.72, 1.0, 1.0);
// Line width in metres at 1 m from the eye; grows with distance to keep a steady screen width.
uniform float thickness : hint_range(0.0, 0.03) = 0.007;
uniform float distance_scale : hint_range(0.0, 1.0) = 0.6;
// 0..1 fade in/out, per outlined object (set_instance_shader_parameter("outline_amount")); the
// pulse keeps it alive without flashing.
instance uniform float outline_amount : hint_range(0.0, 1.0) = 1.0;
uniform float pulse_speed = 3.2;

void vertex() {
	float dist = length(CAMERA_POSITION_WORLD - VERTEX);
	float push = thickness * mix(1.0, dist, distance_scale) * outline_amount;
	VERTEX += normalize(NORMAL) * push;
}

void fragment() {
	float pulse = 0.82 + 0.18 * sin(TIME * pulse_speed);
	ALBEDO = ink.rgb * (0.85 + 0.35 * pulse);
	ALPHA = outline_amount;
}
