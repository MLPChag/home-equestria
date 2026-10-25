shader_type spatial;
render_mode depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;
#include "res://world/terrain/kits/grassy_fields/wind.gdshaderinc"
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D mask_texture : filter_linear_mipmap_anisotropic;
uniform float gradient_strength = 0.3;
uniform float bend_m = 0.2;
uniform float affect_radius_m = 0.8;
uniform float trample_m = -0.2;
uniform float wind_influence = 3.0;
uniform float wind_directional_strength_m = 0.01;
uniform vec2 wind_direction = vec2(-1.0, 0.0);
uniform float wind_intensity = 2.0;
uniform float wind_speed = 0.1;
uniform bool effects_enabled = true;
uniform float review_time = -1.0;
uniform bool interaction_enabled = false;
uniform vec3 interaction_position = vec3(0.0);
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float tip_weight = clamp(1.0 - UV2.y, 0.0, 1.0);
	float weight = tip_weight * gradient_strength;
	if (effects_enabled) {
		vec3 directional = grassy_directional_wind(wind_direction, wind_intensity,
			wind_directional_strength_m);
		vec3 offset = grassy_simple_wind(wp, grassy_effect_time(review_time),
			wind_intensity * wind_influence, 0.25, wind_speed, directional) * weight;
		if (interaction_enabled) offset += grassy_interaction(wp, interaction_position,
			affect_radius_m, bend_m, trample_m, tip_weight);
		VERTEX += (inverse(MODEL_MATRIX) * vec4(offset, 0.0)).xyz;
	}
}
void fragment() {
	ALBEDO = texture(albedo_texture, UV).rgb;
	ALPHA = texture(mask_texture, UV).r;
	ALPHA_SCISSOR_THRESHOLD = 0.3333;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
