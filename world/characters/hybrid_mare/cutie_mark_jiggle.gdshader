// Twin of the native cutie-mark patch material (StandardMaterial3D: depth pre-pass alpha, both
// faces, per-pixel lit, roughness from the source) that also follows the coat's slap wobble, so
// the mark stays on the moving cheek instead of sinking under or floating off it
// (pony_flank_touch.gd swaps it in; dev 2026-10-20 slap jiggle).
shader_type spatial;
render_mode depth_prepass_alpha, cull_disabled;

#include "res://world/characters/hybrid_mare/flank_jiggle.gdshaderinc"

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float roughness = 1.0;
uniform vec3 uv1_scale = vec3(1.0);
uniform vec3 uv1_offset = vec3(0.0);

void vertex() {
	VERTEX += flank_jiggle(VERTEX);
	UV = UV * uv1_scale.xy + uv1_offset.xy;
}

void fragment() {
	vec4 texel = texture(albedo_texture, UV);
	ALBEDO = albedo_color.rgb * texel.rgb;
	ALPHA = albedo_color.a * texel.a;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.5;
}
