// Native OpenPony upper/front nose-tip ridge, measured from the exported mesh.
// Rest-space coordinates survive skinning; no floating line/decal geometry.
uniform bool native_snout_detail = false;
varying vec4 snout_rest;

float snout_segment(vec3 p, vec3 a, vec3 b) {
	vec3 ab = b - a;
	return length(p - a - ab * clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0));
}

vec3 snout_tint() {
	if (!native_snout_detail) return vec3(1.0);
	vec3 p = vec3(abs(snout_rest.x), snout_rest.yz);
	float d = snout_segment(p, vec3(0.0, .85981, -.45212), vec3(.00787, .85936, -.45119));
	d = min(d, snout_segment(p, vec3(.00787, .85936, -.45119), vec3(.01495, .85811, -.44885)));
	d = min(d, snout_segment(p, vec3(.01495, .85811, -.44885), vec3(.02096, .85608, -.44584)));
	d = min(d, snout_segment(p, vec3(.02096, .85608, -.44584), vec3(.02567, .85306, -.44259)));
	d = min(d, snout_segment(p, vec3(.02567, .85306, -.44259), vec3(.02955, .85165, -.43727)));
	float aa = max(fwidth(d), .00008);
	float line = 1.0 - smoothstep(.0007, .0007 + aa, d);
	line *= 1.0 - smoothstep(.022, .030, p.x);
	vec3 bridge = mix(vec3(1.0), vec3(.75, .85, .92), snout_rest.w);
	return mix(bridge, vec3(.51, .62, .74), line);
}
