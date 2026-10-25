shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
#include "res://world/terrain/kits/grassy_fields/wind.gdshaderinc"
uniform vec4 ground_color : source_color;
uniform vec4 wind_line_color : source_color;
uniform sampler2D wind_noise : source_color, filter_linear_mipmap, repeat_enable;
uniform float gradient_strength = 0.3;
uniform float wind_line_size_cm = 10000.0;
uniform float wind_line_speed = -0.02;
uniform vec2 wind_direction = vec2(-1.0, 0.0);
uniform float wind_speed = 0.1;
uniform float wind_intensity = 2.0;
uniform float wind_influence = 1.5;
uniform float wind_directional_strength_cm = 20.0;
uniform float roughness = 1.0;
uniform float specular = 0.0;
uniform bool effects_enabled = true;
uniform bool scale_wind_with_height = false;
uniform float review_time = -1.0;
uniform bool interaction_enabled = false;
uniform vec3 interaction_position = vec3(0.0);
uniform float affect_radius_m = 0.75;
uniform float bend_strength_m = 0.5;
uniform float trample_strength_m = -0.4;
uniform float affect_radius_intensity = 0.5;
varying vec3 world_position;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float weight = clamp(3.0 * ((1.0 - UV.y) * gradient_strength + 0.3) - 1.0, 0.0, 1.0);
	if (effects_enabled) {
		float t = grassy_effect_time(review_time);
		vec3 directional = grassy_directional_wind(wind_direction, wind_intensity,
			wind_directional_strength_cm * 0.01);
		vec3 offset = grassy_simple_wind(wp, t, wind_intensity * wind_influence,
			0.25, wind_speed, directional) * weight;
		if (scale_wind_with_height) offset *= min(1.0, length(MODEL_MATRIX[1].xyz));
		if (interaction_enabled) {
			vec3 delta = wp - interaction_position;
			vec2 horizontal = delta.xz;
			vec2 away = length(horizontal) > 0.00001 ? normalize(horizontal) : vec2(0.0);
			float proximity = 1.0 - clamp(length(delta) / max(affect_radius_m, 0.0001)
				- affect_radius_intensity, 0.0, 1.0);
			offset += vec3(away.x * bend_strength_m, trample_strength_m,
				away.y * bend_strength_m) * proximity;
		}
		VERTEX += (inverse(MODEL_MATRIX) * vec4(offset, 0.0)).xyz;
		wp += offset;
	}
	world_position = wp;
}
void fragment() {
	float gradient = clamp(3.0 * ((1.0 - UV.y) * gradient_strength + 0.3) - 1.0, 0.0, 1.0);
	float t = effects_enabled ? grassy_effect_time(review_time) : 0.0;
	vec2 noise_uv = world_position.xz * 100.0 / max(wind_line_size_cm, 0.001)
		+ normalize(wind_direction) * wind_line_speed * t;
	vec3 line = texture(wind_noise, noise_uv).rgb * gradient;
	ALBEDO = mix(ground_color.rgb, wind_line_color.rgb, line);
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	ROUGHNESS = roughness;
	SPECULAR = specular;
}
