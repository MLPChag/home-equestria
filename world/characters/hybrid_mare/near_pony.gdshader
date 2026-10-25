shader_type spatial;

// Near pony (hybrid_near_mesh.gd, 2026-09-25): several cel-shaded rig surfaces of one skeleton
// merged into one, at full detail. Each source surface keeps its own material values through a
// palette entry (CUSTOM1.x = entry index): the uniforms of addons/cel-shader/cel-shader-base
// .gdshader moved into arrays, the fragment and light code unchanged, so the look is the rig's.
// Entries share one base texture (or none: the default white, as the rig surfaces sample it).
// Colours arrive linear (the rig's source_color uniforms are converted the same way on upload).
// Lighting is eldskald's cel base (addons/cel-shader, MIT) unchanged.

#include "res://addons/cel-shader/includes/base-cel-shader.gdshaderinc"

const int ENTRIES = 32;
uniform vec4 pal_color[ENTRIES];
uniform vec4 pal_specular[ENTRIES];
uniform vec4 pal_fresnel[ENTRIES];
uniform vec4 pal_shadow[ENTRIES];
uniform sampler2D base_texture: source_color;
uniform sampler2D specular_texture: hint_default_white;
uniform sampler2D fresnel_texture: hint_default_white;

varying vec3 SPECULAR_COLOR;
varying float SPECULAR_STRENGTH;
varying vec3 FRESNEL_COLOR;
varying float FRESNEL_STRENGTH;

varying vec2 base_uv;
varying flat int pal;

// Slap wobble, as on the rig coat (pony_flank_touch.gd drives it).
#include "res://world/characters/hybrid_mare/flank_jiggle.gdshaderinc"

// 1 for the palette entries that are her coat (pony_flank_touch.gd): folded wings, the dock and
// other merged parts near the flank stay still.
uniform float jiggle_entry[ENTRIES];

void vertex() {
	pal = int(CUSTOM1.x + 0.5);
	VERTEX += flank_jiggle(VERTEX) * jiggle_entry[pal];
	base_uv = UV;
}

void fragment() {
	vec4 color = pal_color[pal];
	vec4 specular = pal_specular[pal];
	vec4 fresnel = pal_fresnel[pal];
	vec4 shadow_color = pal_shadow[pal];
	SPECULAR_COLOR = specular.rgb * texture(specular_texture, base_uv).rgb;
	SPECULAR_STRENGTH = specular.a * texture(specular_texture, base_uv).a;
	FRESNEL_COLOR = fresnel.rgb * texture(fresnel_texture, base_uv).rgb;
	FRESNEL_STRENGTH = fresnel.a * texture(fresnel_texture, base_uv).a;

	vec3 fill = color.rgb * texture(base_texture, base_uv).rgb;
	vec3 shade = shadow_color.rgb * texture(base_texture, base_uv).rgb;
	ALBEDO = mix(fill, shade, shadow_color.a);
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}

void light() {
	vec4 color = pal_color[pal];
	vec4 shadow_color = pal_shadow[pal];
	vec3 lit_fill = mix(ALBEDO, color.rgb * texture(base_texture, base_uv).rgb, shadow_color.a);
	DIFFUSE_LIGHT += diffuse_light(
			lit_fill,
			LIGHT_COLOR,
			LIGHT,
			NORMAL,
			ATTENUATION
	);
	SPECULAR_LIGHT += specular_light(
			LIGHT_COLOR,
			SPECULAR_COLOR,
			SPECULAR_STRENGTH,
			NORMAL,
			VIEW,
			LIGHT,
			ATTENUATION
	);
	SPECULAR_LIGHT += fresnel_light(
			LIGHT_COLOR,
			FRESNEL_COLOR,
			FRESNEL_STRENGTH,
			NORMAL,
			VIEW,
			LIGHT,
			ATTENUATION
	);
}
