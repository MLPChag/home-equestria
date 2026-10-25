shader_type spatial;

// Far pony (hybrid_far_mesh.gd, dev 2026-09-25): every cel-shaded surface of a pony merged into
// one, so a far pony costs one draw plus one outline instead of one per colour region.
// The atlas holds each source surface's lit colour (its `color` times its texture, linear
// product stored as sRGB). Vertex COLOR carries the show-style two-tone of the source
// material: rgb = shadow_color / color (halved to fit 0..1), a = how far the unlit band takes
// it (shadow_color.a). Lighting is eldskald's cel base (addons/cel-shader, MIT) unchanged.

#include "res://addons/cel-shader/includes/base-cel-shader.gdshaderinc"

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform bool alpha_test = false;
uniform vec4 specular: source_color = vec4(0.3, 0.3, 0.3, 0.5);
uniform vec4 fresnel: source_color = vec4(0.2, 0.2, 0.2, 0.3);

varying vec4 two_tone;
varying vec3 fill;

void vertex() {
	two_tone = COLOR;
}

void fragment() {
	vec4 texel = texture(atlas, UV);
	if (alpha_test && texel.a < 0.5) {
		discard;
	}
	fill = texel.rgb;
	ALBEDO = mix(fill, fill * two_tone.rgb * 2.0, two_tone.a);
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}

void light() {
	vec3 lit_fill = mix(ALBEDO, fill, two_tone.a);
	DIFFUSE_LIGHT += diffuse_light(lit_fill, LIGHT_COLOR, LIGHT, NORMAL, ATTENUATION);
	SPECULAR_LIGHT += specular_light(LIGHT_COLOR, specular.rgb, specular.a, NORMAL, VIEW, LIGHT, ATTENUATION);
	SPECULAR_LIGHT += fresnel_light(LIGHT_COLOR, fresnel.rgb, fresnel.a, NORMAL, VIEW, LIGHT, ATTENUATION);
}
