shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;
#include "res://world/foliage/vegetation_color.gdshaderinc"
varying vec4 local_ground_color;
uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
varying flat vec2 atlas_cell;
void vertex() {
	vec3 centre = MODEL_MATRIX[3].xyz;
	local_ground_color = vegetation_ground(centre.xz);
	vec3 size = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	// Use the viewport camera in both the color and shadow passes, including XR.
	vec3 toward = normalize(MAIN_CAM_INV_VIEW_MATRIX[3].xyz - centre + vec3(0.0, 0.0, 0.00001));
	vec3 local_view = vec3(dot(toward, MODEL_MATRIX[0].xyz) / max(size.x, 0.00001),
		dot(toward, MODEL_MATRIX[1].xyz) / max(size.y, 0.00001),
		dot(toward, MODEL_MATRIX[2].xyz) / max(size.z, 0.00001));
	float azimuth = mod(floor(atan(local_view.x, local_view.z) * 8.0 / TAU + 0.5), 8.0);
	float elevation = clamp(floor(asin(clamp(local_view.y, -1.0, 1.0)) / radians(35.0) + 0.5), 0.0, 2.0);
	atlas_cell = vec2(azimuth, elevation);
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.00001), toward));
	vec3 up = cross(toward, right);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(right * max(size.x, size.z), 0.0),
		vec4(up * size.y, 0.0), vec4(toward * size.z, 0.0), vec4(centre, 1.0));
}
void fragment() {
	vec4 color = texture(atlas, (UV + atlas_cell) / vec2(8.0, 3.0));
	ALBEDO = vegetation_hue(color.rgb, local_ground_color, 0.85 * vegetation_green_mask(color.rgb));
	ALPHA = color.a;
	ALPHA_SCISSOR_THRESHOLD = 0.35;
	// A broad canopy receives daylight from above; avoid view-facing lighting changes.
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	ROUGHNESS = 1.0;
}
