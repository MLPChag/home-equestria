shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;
// Reserved for meshes with their own authored outline. This invisible pass
// keeps their opaque colour/depth/shadow materials intact.
stencil_mode write, 1;

uniform float grow = 0.0;
uniform bool back_faces_only = false;
// Cover the world detector's widest (Bold) diagonal sample: 1.7 * sqrt(2).
// This is in clip units; the screen effect uses 0.001 * viewport height.
uniform float screen_padding = 0.00481;

void vertex() {
	VERTEX += normalize(NORMAL) * grow;
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec4 clip = PROJECTION_MATRIX * view;
	// Fifty micrometres avoids equal-depth rounding gaps in the mask. Keep a
	// world-space bias, so it cannot grow into a large halo at long distance.
	view.z += 0.00005;
	clip.z = (PROJECTION_MATRIX * view).z;
	vec2 direction = (PROJECTION_MATRIX * vec4(MODELVIEW_NORMAL_MATRIX * NORMAL, 0.0)).xy;
	float magnitude = length(direction);
	if (magnitude > 0.0001) {
		clip.xy += direction / magnitude * screen_padding *
			vec2(VIEWPORT_SIZE.y / VIEWPORT_SIZE.x, 1.0) * clip.w;
	}
	POSITION = clip;
}

void fragment() {
	if (back_faces_only && FRONT_FACING) {
		discard;
	}
	ALPHA = 0.0;
}
