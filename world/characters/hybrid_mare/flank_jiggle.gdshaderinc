// Slap wobble (dev 2026-10-20: "add jiggle physics for ass slap"). A damped spring on the coat
// around the hit point: pushed in first, then three or four bounces settling within about a
// second, rippling outward from the hit. pony_flank_touch.gd drives these per pony material
// (coat and its outline hull get the same values so the line stays on the coat). With
// jiggle_amount at 0 every other material using these shaders pays one uniform branch.
uniform float jiggle_amount = 0.0;        // metres of the first push; 0 = off
uniform float jiggle_time = 0.0;          // seconds since the slap
uniform vec3 jiggle_center = vec3(0.0);   // hit point, mesh-local (skinned)
uniform vec3 jiggle_normal = vec3(0.0, 0.0, 1.0);  // outward coat normal, mesh-local
uniform float jiggle_radius = 0.12;       // metres

vec3 flank_jiggle(vec3 vertex) {
	if (jiggle_amount <= 0.0) {
		return vec3(0.0);
	}
	float d = distance(vertex, jiggle_center);
	if (d > jiggle_radius * 1.6) {
		return vec3(0.0);
	}
	float r = d / jiggle_radius;
	float falloff = exp(-2.5 * r * r);
	float t = max(jiggle_time - d * 0.6, 0.0);   // the ripple reaches the edge ~0.1 s later
	float wave = -exp(-4.2 * t) * sin(28.0 * t);  // ~4.5 Hz, inward first
	// The cheek also bounces up and down, a little behind the push: seen from behind or the
	// side (where the player stands) the mark and line art visibly jiggle; an in-out push alone
	// only shows on the silhouette, since the flat cel shading does not change.
	float bob = exp(-3.6 * t) * sin(24.0 * max(t - 0.035, 0.0));  // starts from rest 35 ms later
	vec3 offset = normalize(jiggle_normal) * wave * 0.8 + vec3(0.0, 1.0, 0.0) * bob;
	return offset * (jiggle_amount * falloff);
}
