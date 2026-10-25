// Final expressions avatar: source atlas detail retained, UV2 protects skin and facial symbols.
shader_type spatial;

#define USE_ALPHA 0
#define USE_ALPHA_CUTOFF 0
#define USE_EMISSION 0
#define USE_REFLECTIONS 0
#define USE_NORMAL_MAP 0
#define USE_OCCLUSION 0
#define USE_HEIGHT_MAP 0
#define USE_ANISOTROPY 0
#define USE_BACKLIGHT 0
#define USE_REFRACTION 0

#if USE_ALPHA
render_mode depth_draw_always;
#endif

#include "res://addons/cel-shader/includes/base-cel-shader.gdshaderinc"

#if USE_EMISSION
#include "res://addons/cel-shader/includes/emission.gdshaderinc"
#endif

#if USE_REFLECTIONS
#include "res://addons/cel-shader/includes/reflections.gdshaderinc"
#endif

#if USE_NORMAL_MAP
#include "res://addons/cel-shader/includes/normal-map.gdshaderinc"
#endif

#if USE_OCCLUSION
#include "res://addons/cel-shader/includes/occlusion.gdshaderinc"
#endif

#if USE_HEIGHT_MAP
#include "res://addons/cel-shader/includes/height-map.gdshaderinc"
#endif

#if USE_ANISOTROPY
#include "res://addons/cel-shader/includes/anisotropy.gdshaderinc"
#endif

#if USE_BACKLIGHT
#include "res://addons/cel-shader/includes/backlight.gdshaderinc"
#endif

#if USE_REFRACTION
#include "res://addons/cel-shader/includes/refraction.gdshaderinc"
#elif !USE_REFRACTION && USE_ALPHA
#include "res://addons/cel-shader/includes/transparency.gdshaderinc"
#endif

group_uniforms BaseProperties;
#if USE_ALPHA_CUTOFF
uniform float alpha_cutoff: hint_range(0.0, 1.0) = 0.5;
#endif
uniform vec4 color: source_color = vec4(0.7, 0.12, 0.86, 1.0);
uniform sampler2D base_texture: source_color;
uniform vec4 specular: source_color = vec4(0.3, 0.3, 0.3, 0.5);
uniform sampler2D specular_texture: hint_default_white;
uniform vec4 fresnel: source_color = vec4(0.2, 0.2, 0.2, 0.3);
// HOME-EQUESTRIA: show-style two-tone. With alpha > 0 the unlit band takes this
// colour (scaled by the base texture, still under ambient light so night and
// AO darken it) while the lit band keeps `color`. Alpha 0 = eldskald's original.
uniform vec4 shadow_color: source_color = vec4(0.0, 0.0, 0.0, 0.0);
uniform sampler2D fresnel_texture: hint_default_white;
group_uniforms;

varying vec3 SPECULAR_COLOR;
varying float SPECULAR_STRENGTH;
varying vec3 FRESNEL_COLOR;
varying float FRESNEL_STRENGTH;

varying vec2 base_uv;

group_uniforms Tiling;
uniform vec2 uv_scale = vec2(1,1);
uniform vec2 uv_offset = vec2(0,0);
group_uniforms;

uniform sampler2D clothing_mask : filter_linear, repeat_disable;
uniform sampler2D shoe_mask : filter_linear, repeat_disable;
uniform vec4 shoe_tint : source_color = vec4(0.0);
uniform vec4 suit_tint : source_color = vec4(0.0);
uniform sampler2D suit_pattern : filter_linear_mipmap, repeat_enable;
uniform float suit_scale = 24.0;
uniform bool suit_pattern_on = false;
uniform vec4 tie_tint : source_color = vec4(0.0);
uniform sampler2D tie_pattern : filter_linear_mipmap, repeat_enable;
uniform float tie_scale = 24.0;
uniform bool tie_pattern_on = false;
uniform vec4 pants_tint : source_color = vec4(0.0);
uniform sampler2D pants_pattern : filter_linear_mipmap, repeat_enable;
uniform float pants_scale = 24.0;
uniform bool pants_pattern_on = false;
uniform vec4 shirt_tint : source_color = vec4(0.0);
uniform sampler2D shirt_pattern : filter_linear_mipmap, repeat_enable;
uniform float shirt_scale = 24.0;
uniform bool shirt_pattern_on = false;

void vertex() {
	UV = UV * uv_scale.xy + uv_offset.xy;
	#if !USE_HEIGHT_MAP
		base_uv = UV;
	#endif
}

void fragment() {
#if USE_HEIGHT_MAP
	base_uv = height_map_fragment(UV, VERTEX, TANGENT, BINORMAL, NORMAL);
#endif

#if USE_ALPHA
	float alpha = color.a * texture(base_texture, base_uv).a;
	ALBEDO *= alpha;
#elif USE_ALPHA_CUTOFF
	ALPHA = color.a * texture(base_texture, base_uv).a;
	ALPHA_SCISSOR_THRESHOLD = color.a * texture(base_texture, base_uv).a;
#endif

#if USE_REFRACTION && USE_ALPHA
	EMISSION += refraction_fragment(alpha, NORMAL, SCREEN_UV, FRAGCOORD.z);
#elif !USE_REFRACTION && USE_ALPHA
	EMISSION += transparency_fragment(alpha, SCREEN_UV);
#endif

	SPECULAR_COLOR = specular.rgb * texture(specular_texture, base_uv).rgb;
	SPECULAR_STRENGTH = specular.a * texture(specular_texture, base_uv).a;
	FRESNEL_COLOR = fresnel.rgb * texture(fresnel_texture, base_uv).rgb;
	FRESNEL_STRENGTH = fresnel.a * texture(fresnel_texture, base_uv).a;

#if USE_EMISSION
	EMISSION += emission_fragment(base_uv);
#endif

#if USE_REFLECTIONS
	Surface surf = reflections_fragment(UV);
	METALLIC = surf.metallic;
	ROUGHNESS = surf.roughness;
#endif

#if USE_NORMAL_MAP
	NormalData normal = normal_map_fragment(base_uv, NORMAL, TANGENT, BINORMAL);
	NORMAL = normal.vector;
	NORMAL_MAP = normal.map;
	NORMAL_MAP_DEPTH = normal.depth;
#endif

#if USE_OCCLUSION
	OcclusionData occlusion = occlusion_fragment(base_uv);
	AO = occlusion.ao;
	AO_LIGHT_AFFECT = occlusion.ao_light_affect;
#endif

#if USE_ANISOTROPY
	AnisotropyData aniso = anisotropy_fragment(UV);
	ANISOTROPY_DIR = aniso.direction;
	ANISOTROPY_RATIO = aniso.ratio;
#endif

#if USE_BACKLIGHT
	BACKLIGHT = backlight_fragment(base_uv);
#endif

	vec3 fill = color.rgb * texture(base_texture, base_uv).rgb;
	vec3 shade = shadow_color.rgb * texture(base_texture, base_uv).rgb;
	ALBEDO = mix(fill, shade, shadow_color.a);
	vec4 garment = UV2.x < 0.25 ? texture(clothing_mask, base_uv) : vec4(0.0);

	if (garment.r > 0.01) {
        float detail = clamp(dot(texture(base_texture,base_uv).rgb,vec3(0.2126,0.7152,0.0722)) / 0.0251868572, 0.05, 2.5);
        vec3 fabric = mix(ALBEDO, suit_tint.rgb * detail, suit_tint.a);
        if (suit_pattern_on) fabric *= 1.0 + (texture(suit_pattern, base_uv * suit_scale).r - 0.5) * 0.42;
        ALBEDO = mix(ALBEDO, fabric, garment.r);
    }

	if (garment.g > 0.01) {
        float detail = clamp(dot(texture(base_texture,base_uv).rgb,vec3(0.2126,0.7152,0.0722)) / 0.109612691, 0.05, 2.5);
        vec3 fabric = mix(ALBEDO, tie_tint.rgb * detail, tie_tint.a);
        if (tie_pattern_on) fabric *= 1.0 + (texture(tie_pattern, base_uv * tie_scale).r - 0.5) * 0.42;
        ALBEDO = mix(ALBEDO, fabric, garment.g);
    }

	if (garment.b > 0.01) {
        float detail = clamp(dot(texture(base_texture,base_uv).rgb,vec3(0.2126,0.7152,0.0722)) / 0.0189486595, 0.05, 2.5);
        vec3 fabric = mix(ALBEDO, pants_tint.rgb * detail, pants_tint.a);
        if (pants_pattern_on) fabric *= 1.0 + (texture(pants_pattern, base_uv * pants_scale).r - 0.5) * 0.42;
        ALBEDO = mix(ALBEDO, fabric, garment.b);
    }

	if (garment.a > 0.01) {
        float detail = clamp(dot(texture(base_texture,base_uv).rgb,vec3(0.2126,0.7152,0.0722)) / 0.652450093, 0.05, 2.5);
        vec3 fabric = mix(ALBEDO, shirt_tint.rgb * detail, shirt_tint.a);
        if (shirt_pattern_on) fabric *= 1.0 + (texture(shirt_pattern, base_uv * shirt_scale).r - 0.5) * 0.42;
        ALBEDO = mix(ALBEDO, fabric, garment.a);
    }

	float shoe = UV2.x < 0.25 ? texture(shoe_mask, base_uv).r : 0.0;
	if (shoe > 0.01 && shoe_tint.a > 0.0) {
		float detail = clamp(dot(texture(base_texture,base_uv).rgb,vec3(0.2126,0.7152,0.0722)) / 0.0159962922, 0.0, 4.0);
		ALBEDO = mix(ALBEDO, shoe_tint.rgb * detail, shoe * shoe_tint.a);
	}

	// HOME-EQUESTRIA: no environment specular. The shader does its own banded
	// specular in light(); Godot's default SPECULAR 0.5 on top added a flat sky
	// sheen that kept cel surfaces glowing at night.
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}

void light() {
#if USE_BACKLIGHT
	DIFFUSE_LIGHT += backlight_diffuse(
			ALBEDO,
			LIGHT_COLOR,
			LIGHT,
			NORMAL,
			ATTENUATION,
			BACKLIGHT
	);
#else
	vec3 lit_fill = mix(ALBEDO, color.rgb * texture(base_texture, base_uv).rgb, shadow_color.a);
	DIFFUSE_LIGHT += diffuse_light(
			lit_fill,
			LIGHT_COLOR,
			LIGHT,
			NORMAL,
			ATTENUATION
	);
#endif

#if USE_ANISOTROPY
	SPECULAR_LIGHT += anisotropy_specular(
			LIGHT_COLOR,
			SPECULAR_COLOR,
			SPECULAR_STRENGTH,
			NORMAL,
			VIEW,
			LIGHT,
			ATTENUATION,
			UV,
			ANISOTROPY_DIR,
			ANISOTROPY_RATIO
	);
#else
	SPECULAR_LIGHT += specular_light(
			LIGHT_COLOR,
			SPECULAR_COLOR,
			SPECULAR_STRENGTH,
			NORMAL,
			VIEW,
			LIGHT,
			ATTENUATION
	);
#endif

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
