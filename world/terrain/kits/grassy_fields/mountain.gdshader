shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D rock_texture : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_texture : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D rgb_mask : repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec4 cliff_tint : source_color;
uniform vec4 grass_color : source_color;
uniform float tint_strength;
uniform float texture_size_m;
varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

vec3 world_aligned_xy(vec3 p) {
	// M_Mountain reads WorldAlignedTexture output 0, named "XY Texture".
	// It does not read output 2 (the normal-weighted "XYZ Texture"). Unreal
	// XY becomes Godot XZ under Epic's (X,Z,Y) glTF axis conversion.
	return texture(rock_texture, p.xz / texture_size_m).rgb;
}

void fragment() {
	vec3 cliff = mix(world_aligned_xy(world_position), cliff_tint.rgb, tint_strength);
	float grass_mask = texture(rgb_mask, UV).g;
	ALBEDO = mix(cliff, grass_color.rgb, grass_mask);
	vec3 n = texture(normal_texture, UV).xyz * 2.0 - 1.0;
	n.y = -n.y;
	NORMAL_MAP = normalize(n) * 0.5 + 0.5;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
