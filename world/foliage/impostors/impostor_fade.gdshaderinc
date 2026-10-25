// Per-tree crossfade between a far tree and its impostor (world/foliage/impostors/tree_impostors.gd).
// impostor_fade: distance band (x..y) from the main camera (XR: the centre between the eyes) to
// the tree root over which the impostor replaces the mesh; y <= 0 turns the fade off.
// Both sides use the same screen dither, so every pixel shows exactly one of the two.
uniform vec2 impostor_fade = vec2(0.0);

float impostor_fade_amount(vec3 eye, vec3 root) {
	if (impostor_fade.y <= 0.0) return 0.0;
	return smoothstep(impostor_fade.x, impostor_fade.y, distance(eye, root));
}

float impostor_dither(vec2 frag) {
	return fract(52.9829189 * fract(dot(frag, vec2(0.06711056, 0.00583715))));
}
