// Far pony irises (hybrid_far_mesh.gd): show_eyes/iris.gdshader for BOTH eyes in one draw.
// The first eye reads tint_mask / ink / gaze_uv, the second the *_b copies, picked per vertex
// by UV2.x (0 first, 1 second). Same maths as iris.gdshader; keep the two in step.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D tint_mask : filter_linear_mipmap, repeat_disable;
uniform sampler2D ink : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D tint_mask_b : filter_linear_mipmap, repeat_disable;
uniform sampler2D ink_b : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 iris_color : source_color = vec4(0.38,0.73,0.31,1.0);
uniform vec2 gaze_uv = vec2(0.0);
uniform vec2 gaze_uv_b = vec2(0.0);
uniform float iris_scale = 0.68;
uniform vec2 iris_center = vec2(0.51, 0.5);

void fragment() {
	bool second = UV2.x > 0.5;
	vec2 gaze = second ? gaze_uv_b : gaze_uv;
	vec2 uv = (UV - gaze - iris_center) / iris_scale + iris_center;
	// Both pairs sampled, then selected: exact values, no sampling under divergent control flow.
	vec4 tint_a = texture(tint_mask, uv);
	vec4 tint_b = texture(tint_mask_b, uv);
	vec4 detail_a = texture(ink, uv);
	vec4 detail_b = texture(ink_b, uv);
	vec4 tint = second ? tint_b : tint_a;
	vec4 detail = second ? detail_b : detail_a;
	float inside = step(0.0,uv.x)*step(uv.x,1.0)*step(0.0,uv.y)*step(uv.y,1.0);
	vec3 color = mix(vec3(0.94), iris_color.rgb*tint.r+vec3(tint.g), tint.a*inside);
	color = mix(color,detail.rgb,detail.a*inside);
	ALBEDO = color;
	ROUGHNESS = 0.8;
	SPECULAR = 0.15;
}
