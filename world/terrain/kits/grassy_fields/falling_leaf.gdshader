shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;
uniform sampler2D leaf_texture : source_color, filter_linear_mipmap_anisotropic;
uniform vec4 leaf_color : source_color;
uniform float opacity_cutoff = 0.33329999446868896;
void fragment() {
	vec4 leaf = texture(leaf_texture, UV);
	if (leaf.r < opacity_cutoff) { discard; }
	ALBEDO = leaf_color.rgb;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
