// Native Left/Right Head UVs share these three socket boundary loops.
// The head hull must not draw a second coat-coloured rim inside the eye;
// the separate skinned eyelash material owns that edge. Outer head UVs remain.
bool inside_native_eye_socket(vec2 uv) {
	return uv.x >= 0.480 && uv.x <= 0.610 && uv.y >= 0.690 && uv.y <= 0.820;
}
