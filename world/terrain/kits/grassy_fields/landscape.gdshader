shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Isolated visible branch of MI_Landscape with DrawCliffs? = false.
uniform sampler2D grass_texture : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D layer_weight_texture : repeat_disable, filter_linear;
// RGBA = Ground, Grass, GrassDark, GrassDarker. Callers supply authored or
// review weights; the shader invents no painted distribution.
uniform vec4 layer_weights;
uniform bool use_layer_weight_texture = false;
uniform vec4 ground_color : source_color;
uniform vec4 grass_color : source_color;
uniform vec4 grass_short_color : source_color;
uniform vec4 grass_tall_color : source_color;
uniform float texture_near_size_m;
uniform float texture_far_size_m;
uniform float distance_fade_start_m;
uniform float distance_fade_divisor_m;
uniform float color_overlay_amount;
varying vec3 world_position;
varying float source_pixel_depth_m;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	source_pixel_depth_m = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}

void fragment() {
	float distance_alpha = clamp((source_pixel_depth_m - distance_fade_start_m)
		/ max(distance_fade_divisor_m, 0.00001), 0.0, 1.0);
	// Both source texture samples use UE world XY, which maps to Godot XZ.
	float near_noise = texture(grass_texture, world_position.xz / texture_near_size_m).r;
	float far_noise = texture(grass_texture, world_position.xz / texture_far_size_m).r;
	float detail = mix(1.0, mix(near_noise, far_noise, distance_alpha), color_overlay_amount);
	vec4 weights = layer_weights;
	if (use_layer_weight_texture) {
		weights *= texture(layer_weight_texture, UV);
	}
	weights = max(weights, vec4(0.0));
	float total = dot(weights, vec4(1.0));
	vec3 layers = ground_color.rgb * weights.r + grass_color.rgb * weights.g
		+ grass_short_color.rgb * weights.b + grass_tall_color.rgb * weights.a;
	ALBEDO = layers / max(total * detail, 0.00001);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);
}
