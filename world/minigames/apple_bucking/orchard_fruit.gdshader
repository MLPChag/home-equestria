shader_type spatial;
render_mode cull_back;
varying float maturity;
void vertex() { maturity = INSTANCE_CUSTOM.r; }
void fragment() {
	vec3 green = vec3(0.29, 0.53, 0.055);
	ALBEDO = mix(green, COLOR.rgb, smoothstep(0.82, 1.0, maturity));
	ROUGHNESS = 0.48;
}
