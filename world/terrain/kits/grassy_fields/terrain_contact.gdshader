shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D color_texture : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_texture : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D orm_texture : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D noise_texture : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec4 tint : source_color;
uniform float tint_strength;
uniform float noise_uv_scale;
uniform float terrain_blend_m;
uniform float gradient_height;
uniform float ground_height_m;
uniform bool ground_from_instance = false;
uniform vec4 ground_color : source_color;
uniform float use_orm;
varying vec3 world_position;
varying float instance_ground;

void vertex() { world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; instance_ground = MODEL_MATRIX[3].y; }

void fragment() {
	float blend = clamp(texture(noise_texture, UV * noise_uv_scale).r
		+ (world_position.y - (ground_from_instance ? instance_ground : ground_height_m)) / max(terrain_blend_m, 0.00001)
		+ gradient_height, 0.0, 1.0);
	vec3 local_color = mix(texture(color_texture, UV).rgb, tint.rgb, tint_strength);
	ALBEDO = mix(ground_color.rgb, local_color, blend);
	vec3 n = texture(normal_texture, UV).xyz * 2.0 - 1.0;
	n.y = -n.y;
	vec3 ground_n = vec3(0.0, 0.0, 1.0);
	NORMAL_MAP = normalize(mix(ground_n, n, blend)) * 0.5 + 0.5;
	float local_roughness = mix(1.0, texture(orm_texture, UV).g, use_orm);
	ROUGHNESS = mix(1.0, local_roughness, blend);
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
