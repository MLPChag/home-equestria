shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled;

uniform float age = 0.0;
uniform float strength = 1.0;

void vertex() {
	float r = length(UV * 2.0 - 1.0);
	float radius = 0.12 + age * 0.60;
	float crest = exp(-pow((r - radius) * 22.0, 2.0));
	VERTEX.y += crest * 0.22 * strength * exp(-age * 4.0);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float radius = 0.12 + age * 0.60;
	float ring = exp(-pow((r - radius) * 32.0, 2.0));
	float inner = exp(-pow((r - radius * 0.7) * 38.0, 2.0)) * 0.4;
	float broken_foam = 0.65 + 0.35 * sin(p.x * 65.0 + sin(p.y * 40.0));
	float fade = (1.0 - smoothstep(0.4, 1.35, age)) * smoothstep(0.0, 0.05, age);
	ALBEDO = vec3(0.55, 0.8, 0.82);
	ROUGHNESS = 0.65;
	ALPHA = clamp((ring + inner) * broken_foam * fade * strength, 0.0, 0.8);
}
