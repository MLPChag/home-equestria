shader_type spatial;
render_mode diffuse_burley, specular_disabled;
#include "res://world/foliage/vegetation_color.gdshaderinc"
#include "res://world/foliage/impostors/impostor_fade.gdshaderinc"
// Far Everfree crown (tools/everfree_trees/build_trees.gd): the RNL blob in the leaf cards'
// colours, lighter on top and darker underneath like the cards, with the same ground hue
// and season tint, so the swap from cards past 110 m keeps its colour. Far tiles with an
// impostor set impostor_fade on a copy, dissolving it into the impostor past 500 m.
uniform vec4 leaf_color : source_color;
uniform vec4 underside_color : source_color;
uniform float ground_hue_strength : hint_range(0.0, 1.0) = 0.35;
varying vec4 local_ground_color;
varying vec3 world_normal;
varying float fade_t;

void vertex() {
	local_ground_color = vegetation_ground((MODEL_MATRIX * vec4(VERTEX, 1.0)).xz);
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	fade_t = impostor_fade_amount(MAIN_CAM_INV_VIEW_MATRIX[3].xyz, MODEL_MATRIX[3].xyz);
}

void fragment() {
	if (impostor_dither(FRAGCOORD.xy) < fade_t) { discard; }
	float top = pow(max((world_normal.y + 1.0) * 0.5, 0.0), 0.511615);
	vec3 base = mix(underside_color.rgb, leaf_color.rgb, top);
	ALBEDO = vegetation_hue(base, local_ground_color, ground_hue_strength * vegetation_green_mask(leaf_color.rgb));
	ROUGHNESS = 1.0;
}
