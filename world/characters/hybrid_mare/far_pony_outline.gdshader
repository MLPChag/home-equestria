shader_type spatial;
render_mode cull_front;

// Outline hull for the merged far pony (far_pony.gdshader): cel-outline-lit.gdshader with the
// line colour, two-tone and width per vertex, so every source surface keeps its own line.
// CUSTOM0: rgb = line colour (linear), a = hull width / 1 cm (0 = that surface had no line).
// CUSTOM1: rgb = line shadow_color / color (halved), a = two-tone amount.

#include "res://addons/cel-shader/includes/base-cel-shader.gdshaderinc"

uniform bool face_viewer = true;
uniform vec4 specular: source_color = vec4(0.3, 0.3, 0.3, 0.5);
uniform vec4 fresnel: source_color = vec4(0.2, 0.2, 0.2, 0.3);

varying vec3 line_color;
varying vec4 two_tone;
varying float width;

void vertex() {
	width = CUSTOM0.a * 0.01;
	VERTEX += normalize(NORMAL) * width;
	line_color = CUSTOM0.rgb;
	two_tone = CUSTOM1;
}

void fragment() {
	if (width <= 0.0) {
		discard;
	}
	// Lit with the facing normal, as cel-outline-lit.gdshader explains.
	if (face_viewer) {
		NORMAL = -NORMAL;
	}
	ALBEDO = mix(line_color, line_color * two_tone.rgb * 2.0, two_tone.a);
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}

void light() {
	vec3 lit_fill = mix(ALBEDO, line_color, two_tone.a);
	DIFFUSE_LIGHT += diffuse_light(lit_fill, LIGHT_COLOR, LIGHT, NORMAL, ATTENUATION);
	SPECULAR_LIGHT += specular_light(LIGHT_COLOR, specular.rgb, specular.a, NORMAL, VIEW, LIGHT, ATTENUATION);
	SPECULAR_LIGHT += fresnel_light(LIGHT_COLOR, fresnel.rgb, fresnel.a, NORMAL, VIEW, LIGHT, ATTENUATION);
}
