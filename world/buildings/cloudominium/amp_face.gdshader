shader_type spatial;
// Cloudominium practice amp (dev 2026-09-28): grey tolex box whose local +Z and -Z faces carry
// a light control strip and a dark grille. Written for BoxMesh: fract(UV * (3, 2)) is the
// position inside any face of its 3 x 2 UV atlas, whatever the box's size.
uniform vec4 body_color : source_color = vec4(0.44, 0.45, 0.48, 1.0);
uniform vec4 panel_color : source_color = vec4(0.68, 0.69, 0.72, 1.0);
uniform vec4 grille_color : source_color = vec4(0.12, 0.12, 0.14, 1.0);
uniform vec4 knob_color : source_color = vec4(0.08, 0.08, 0.09, 1.0);
varying vec3 local_normal;

void vertex() {
	local_normal = NORMAL;
}

float rectangle(vec2 p, vec2 low, vec2 high, vec2 aa) {
	vec2 inside = smoothstep(low - aa, low + aa, p) * (vec2(1.0) - smoothstep(high - aa, high + aa, p));
	return inside.x * inside.y;
}

void fragment() {
	vec3 colour = body_color.rgb;
	if (abs(normalize(local_normal).z) > 0.7) {
		vec2 face = fract(UV * vec2(3.0, 2.0));
		vec2 aa = max(fwidth(face), vec2(0.001));
		colour = mix(colour, panel_color.rgb, rectangle(face, vec2(0.07, 0.07), vec2(0.93, 0.24), aa));
		colour = mix(colour, grille_color.rgb, rectangle(face, vec2(0.07, 0.3), vec2(0.93, 0.93), aa));
		for (int i = 0; i < 4; i++) {
			vec2 knob = vec2(0.52 + 0.11 * float(i), 0.155);
			float d = length((face - knob) * vec2(1.0, 0.6));
			colour = mix(colour, knob_color.rgb, 1.0 - smoothstep(0.03 - aa.x, 0.03 + aa.x, d));
		}
	}
	ALBEDO = colour;
	ROUGHNESS = 0.8;
	SPECULAR = 0.25;
}
