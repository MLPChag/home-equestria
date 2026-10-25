// Original skinned cards and native asymmetric control bones. Expression ink is
// black on every coat; the resting smile has no brow contour. Per-instance amount
// also keeps cached far meshes from sharing another pony's expression visibility.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;
instance uniform float brow_amount : hint_range(0.0, 1.0) = 0.0;
void fragment() {
	if (brow_amount <= 0.0) { discard; }
	float t = clamp((UV.x - .16) / .69, 0.0, 1.0);
	float curve = .225 - .07 * sin(t * 3.14159265);
	// Fade by growing solid ink, reaching the authored thickness before a half-weight
	// expression. Sad/shy brows must be as readable as the full angry pose.
	float width = .0235 * pow(max(sin(t * 3.14159265),0.0), .55) * smoothstep(0.0, .45, brow_amount);
	float inside = width - abs(UV.y - curve);
	ALBEDO = vec3(0.0);
	ALPHA = smoothstep(-fwidth(inside), fwidth(inside), inside);
	ALPHA_SCISSOR_THRESHOLD = .5;
	ROUGHNESS = 1.0;
}
