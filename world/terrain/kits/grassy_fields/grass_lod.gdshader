shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;
#include "res://world/terrain/kits/grassy_fields/wind.gdshaderinc"
uniform sampler2D card_texture : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D wind_noise : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 ground_color : source_color;
uniform vec4 wind_line_color : source_color;
uniform float gradient_strength = 0.3;
uniform float wind_line_size_cm = 3000.0;
uniform float wind_line_speed = 0.03;
uniform float roughness = 1.0;
uniform float wind_influence = 7.0;
uniform float wind_directional_strength_cm = 25.0;
uniform float grass_hiding_offset_cm = -50.0;
uniform float instance_fade = 1.0;
uniform vec2 wind_direction = vec2(-1.0, 0.0);
uniform float wind_speed = 0.1;
uniform float wind_intensity = 2.0;
uniform bool effects_enabled = true;
uniform bool scale_wind_with_height = false;
uniform float review_time = -1.0;
varying vec3 world_position;
float grass_lod_gradient(vec2 uv) {
	// M_GrassLOD: CheapContrast((1 - LinearGradient.V) * strength + 0.3, 1).
	return clamp(3.0 * ((1.0 - uv.y) * gradient_strength + 0.3) - 1.0, 0.0, 1.0);
}
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (effects_enabled) {
		float mask = grass_lod_gradient(UV);
		vec3 directional = grassy_directional_wind(wind_direction, wind_intensity,
			wind_directional_strength_cm * 0.01);
		vec3 offset = grassy_simple_wind(wp, grassy_effect_time(review_time),
			wind_intensity * wind_influence, 0.25, wind_speed, directional) * mask;
		if (scale_wind_with_height) offset *= min(1.0, length(MODEL_MATRIX[1].xyz));
		// PerInstanceFadeAmount has no ordinary MeshInstance equivalent. A caller may
		// supply the same 0..1 fade; the source adds (1-fade)*GrassHidingOffset on UE Z.
		offset.y += (1.0 - clamp(instance_fade, 0.0, 1.0)) * grass_hiding_offset_cm * 0.01;
		VERTEX += (inverse(MODEL_MATRIX) * vec4(offset, 0.0)).xyz;
		wp += offset;
	}
	world_position = wp;
}
void fragment() {
	float mask = grass_lod_gradient(UV);
	float t = effects_enabled ? grassy_effect_time(review_time) : 0.0;
	vec2 noise_uv = world_position.xz * 100.0 / max(wind_line_size_cm, 0.001)
		+ vec2(wind_line_speed * t);
	vec3 line = texture(wind_noise, noise_uv).rgb * mask;
	ALBEDO = mix(ground_color.rgb, wind_line_color.rgb, line);
	ALPHA = texture(card_texture, UV).r;
	ALPHA_SCISSOR_THRESHOLD = 0.3333;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	ROUGHNESS = roughness;
	SPECULAR = 0.0;
	METALLIC = 0.0;
}
