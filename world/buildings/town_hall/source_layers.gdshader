shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Source textures retain their native dimensions, mipmaps and repeating UVs.
// One array per image size batches matching materials without an atlas seam.
uniform sampler2DArray source_layers : source_color, filter_linear_mipmap, repeat_enable;
varying flat float layer;

void vertex() {
	layer = round(COLOR.r * 255.0);
}

void fragment() {
	ALBEDO = texture(source_layers, vec3(UV, layer)).rgb;
	ROUGHNESS = 0.85;
	SPECULAR = 0.3;
	if (!FRONT_FACING) NORMAL = -NORMAL;
}
