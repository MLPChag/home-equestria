shader_type spatial;
render_mode cull_front;

// Outline hull of a merged near pony surface (near_pony.gdshader, hybrid_near_mesh.gd):
// addons/cel-shader/cel-outline-lit.gdshader with every uniform moved into a palette entry
// (CUSTOM1.x), so each merged source surface keeps its own line colour, shade and width.
// Lighting is eldskald's cel base (addons/cel-shader, MIT) unchanged.

#include "res://addons/cel-shader/includes/base-cel-shader.gdshaderinc"

const int ENTRIES = 32;
uniform vec4 pal_color[ENTRIES];
uniform vec4 pal_specular[ENTRIES];
uniform vec4 pal_fresnel[ENTRIES];
uniform vec4 pal_shadow[ENTRIES];
uniform float pal_width[ENTRIES];
uniform float pal_face_viewer[ENTRIES];
uniform float pal_eye_socket_mask[ENTRIES];
#include "res://world/characters/openpony/eye_socket_outline.gdshaderinc"
uniform sampler2D base_texture: source_color;
uniform sampler2D specular_texture: hint_default_white;
uniform sampler2D fresnel_texture: hint_default_white;

varying vec3 SPECULAR_COLOR;
varying float SPECULAR_STRENGTH;
varying vec3 FRESNEL_COLOR;
varying float FRESNEL_STRENGTH;

varying vec2 base_uv;
varying flat int pal;

// Slap wobble, so the hull moves with the coat.
#include "res://world/characters/hybrid_mare/flank_jiggle.gdshaderinc"

// 1 for the palette entries that are her coat (pony_flank_touch.gd): folded wings, the dock and
// other merged parts near the flank stay still.
uniform float jiggle_entry[ENTRIES];

void vertex() {
	pal = int(CUSTOM1.x + 0.5);
	VERTEX += flank_jiggle(VERTEX) * jiggle_entry[pal];
	if (pal_eye_socket_mask[pal] < 0.5 || !inside_native_eye_socket(UV)) {
		VERTEX += normalize(NORMAL) * pal_width[pal];
	}
	base_uv = UV;
}

void fragment() {
	if (pal_eye_socket_mask[pal] > 0.5 && inside_native_eye_socket(UV)) { discard; }
	vec4 color = pal_color[pal];
	vec4 specular = pal_specular[pal];
	vec4 fresnel = pal_fresnel[pal];
	vec4 shadow_color = pal_shadow[pal];
	// Lit with the facing normal, as cel-outline-lit.gdshader explains.
	if (pal_face_viewer[pal] > 0.5) {
		NORMAL = -NORMAL;
	}
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
