shader_type spatial;
render_mode depth_draw_opaque, diffuse_burley, specular_disabled;
// Shadow-only authored crown volume: no alpha cards or distant-impostor dither.
void fragment() {
	ALBEDO = vec3(0.0);
	ROUGHNESS = 1.0;
}
