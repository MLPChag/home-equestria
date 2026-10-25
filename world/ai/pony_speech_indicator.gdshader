shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled, depth_draw_never;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;

float circle(vec2 p, vec2 center, float radius) {
	return length(p - center) - radius;
}
void vertex() {
	// A tiny rock, not a spinning sign; orientation still faces the viewer.
	float angle = sin(TIME * 2.1) * 0.025;
	VERTEX.xy = mat2(vec2(cos(angle), sin(angle)), vec2(-sin(angle), cos(angle))) * VERTEX.xy;
}
void fragment() {
	vec2 p = (UV - vec2(0.5)) * vec2(1.6, 1.0);
	vec2 q = abs(p - vec2(0.0, -0.04)) - vec2(0.43, 0.10);
	float shape = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - 0.18;
	shape = min(shape, circle(p, vec2(-0.39, 0.26), 0.085));
	shape = min(shape, circle(p, vec2(-0.49, 0.36), 0.04));
	float aa = max(fwidth(shape), 0.001);
	float alpha = 1.0 - smoothstep(-aa, aa, shape);
	vec3 panel = vec3(0.92, 0.94, 0.97);
	vec3 ink = vec3(0.30, 0.35, 0.42);
	float dots = 0.0;
	for (int i = 0; i < 3; i++) {
		float wave = 0.5 + 0.5 * sin(TIME * 4.6 - float(i) * 1.25);
		vec2 center = vec2((float(i) - 1.0) * 0.22, -0.035 - wave * 0.035);
		float d = circle(p, center, 0.047 + wave * 0.009);
		dots = max(dots, (1.0 - smoothstep(-aa, aa, d)) * (0.45 + 0.55 * wave));
	}
	ALBEDO = mix(panel, ink, dots);
	ALPHA = alpha * opacity;
}
