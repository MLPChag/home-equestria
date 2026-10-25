shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform vec4 bottom_color : source_color = vec4(0.119792, 0.441232, 1.0, 1.0);
uniform vec4 top_color : source_color = vec4(0.0, 0.37677, 1.0, 1.0);

void fragment() {
	// M_Sky squares CYL UV.y, inverts the result twice, then lerps
	// TopColor -> BottomColor with that value.
	float y = clamp(UV.y, 0.0, 1.0);
	float alpha = 1.0 - (1.0 - y * y) * (1.0 - y * y);
	ALBEDO = mix(top_color.rgb, bottom_color.rgb, alpha);
}
