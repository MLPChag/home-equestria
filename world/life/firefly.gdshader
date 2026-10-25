shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// Fireflies (world/life/fireflies.gd). Each MultiMesh instance is one firefly: its transform
// origin is its home point in the swarm, INSTANCE_CUSTOM = (seed a, seed b, blink phase,
// blink period in seconds). The vertex shader wanders it around home and turns the quad to
// the camera; the blink is a soft rise and fall that sometimes skips a beat.
instance uniform float fade = 0.0;
uniform vec3 glow_color : source_color = vec3(0.78, 1.0, 0.32);
uniform float size = 0.16;
uniform float brightness = 3.0;
uniform float wander = 1.3;
varying float glow;

float hash11(float x) {
	return fract(sin(x * 127.1) * 43758.5453);
}

void vertex() {
	vec4 s = INSTANCE_CUSTOM;
	float t = TIME;
	vec3 home = MODEL_MATRIX[3].xyz;
	vec3 w = vec3(
		sin(t * (0.21 + 0.17 * s.x) + s.y * 6.283) + 0.5 * sin(t * (0.53 + 0.3 * s.y) + s.x * 11.0),
		0.6 * sin(t * (0.17 + 0.13 * s.y) + s.x * 5.0),
		cos(t * (0.19 + 0.15 * s.y) + s.x * 6.283) + 0.5 * cos(t * (0.47 + 0.25 * s.x) + s.y * 9.0));
	vec3 centre = home + w * wander;
	float cycle = t / s.w + s.z;
	float phase = fract(cycle);
	float bump = sin(3.14159 * clamp(phase / 0.35, 0.0, 1.0));
	// About one blink in four is skipped, so the flashing never looks clocked.
	float lit = step(0.25, hash11(floor(cycle) + s.x * 91.7));
	glow = bump * bump * lit * fade;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 world = centre + (right * VERTEX.x + up * VERTEX.y) * size;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}

void fragment() {
	float d = length(UV - 0.5) * 2.0;
	float core = 1.0 - smoothstep(0.0, 0.3, d);
	float halo = (1.0 - smoothstep(0.1, 1.0, d)) * 0.35;
	ALBEDO = glow_color * (core + halo) * glow * brightness;
}
