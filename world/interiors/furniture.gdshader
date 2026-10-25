shader_type spatial;
// Household furniture with a per-house finish (world/interiors). The prop's own atlas is kept for
// metal, stone, enamel and glass; wood, coloured fabric and linen are repainted from the mask
// (tools/props/household/build.py writes <id>_mask.png: R wood, G fabric, B linen, A = texel
// brightness relative to its material's base colour, halved), so grain, weave and the baked
// shading stay while the colour changes.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D mr_tex : hint_default_white, filter_linear_mipmap, repeat_disable;
uniform sampler2D mask_tex : hint_default_black, filter_linear_mipmap, repeat_disable;

uniform vec3 wood_color : source_color = vec3(0.72, 0.56, 0.39);
uniform float wood_mix : hint_range(0.0, 1.0) = 0.0;       // 0 keeps the original honey oak
uniform float wood_contrast : hint_range(0.0, 1.5) = 1.0;  // grain strength (paint hides grain)
uniform float wood_roughness = -1.0;                       // < 0 keeps the atlas roughness
uniform vec3 fabric_color : source_color = vec3(0.85, 0.6, 0.65);
uniform float fabric_mix : hint_range(0.0, 1.0) = 0.0;
uniform vec3 linen_color : source_color = vec3(0.94, 0.9, 0.84);
uniform float linen_mix : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec3 col = texture(albedo_tex, UV).rgb;
	vec4 mask = texture(mask_tex, UV);
	float shade = mask.a * 2.0;
	vec3 wood = wood_color * mix(1.0, shade, wood_contrast);
	col = mix(col, wood, mask.r * wood_mix);
	col = mix(col, fabric_color * shade, mask.g * fabric_mix);
	col = mix(col, linen_color * shade, mask.b * linen_mix);
	ALBEDO = col;
	vec4 mr = texture(mr_tex, UV);
	ROUGHNESS = wood_roughness < 0.0 ? mr.g : mix(mr.g, wood_roughness, mask.r * wood_mix);
	METALLIC = mr.b;
}
