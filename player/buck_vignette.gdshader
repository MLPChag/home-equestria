shader_type spatial;
// Black vignette in front of the eyes after a buck (player/buck_daze.gd). Clear centre, dark rim.
render_mode unshaded, depth_test_disabled, cull_disabled, blend_mix, shadows_disabled;
uniform float amount = 1.0;

void fragment() {
	vec2 p = (UV - 0.5) * vec2(1.3, 1.0);
	float rim = smoothstep(0.08, 0.5, length(p));
	ALBEDO = vec3(0.0);
	ALPHA = clamp(rim * amount * 1.4 + amount * amount * 0.35, 0.0, 1.0);
}
