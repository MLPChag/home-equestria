shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform sampler2D color_texture : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_texture : filter_linear_mipmap_anisotropic;
uniform sampler2D orm_texture : filter_linear_mipmap_anisotropic;
uniform vec4 tint : source_color;
uniform float tint_strength;
void fragment() {
	ALBEDO = mix(texture(color_texture, UV).rgb, tint.rgb, tint_strength);
	vec3 n = texture(normal_texture, UV).xyz * 2.0 - 1.0; n.y = -n.y;
	NORMAL_MAP = normalize(n) * 0.5 + 0.5;
	vec3 orm = texture(orm_texture, UV).rgb;
	AO = orm.r; ROUGHNESS = orm.g; METALLIC = orm.b;
}
