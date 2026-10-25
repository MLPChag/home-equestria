shader_type spatial;
render_mode diffuse_burley, specular_disabled;
#include "res://world/foliage/impostors/impostor_fade.gdshaderinc"
// The far tree's bark (its StandardMaterial3D: albedo texture, rough, no specular) with the
// impostor crossfade, used only by far tiles whose species has an impostor.
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
varying float fade_t;

void vertex() {
	fade_t = impostor_fade_amount(MAIN_CAM_INV_VIEW_MATRIX[3].xyz, MODEL_MATRIX[3].xyz);
}

void fragment() {
	if (impostor_dither(FRAGCOORD.xy) < fade_t) { discard; }
	ALBEDO = albedo_color.rgb * texture(albedo_texture, UV).rgb;
	ROUGHNESS = 1.0;
}
