shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Same curved surface as the sclera: no floating alpha cards or eye holes.
uniform sampler2D tint_mask : filter_linear_mipmap, repeat_disable;
uniform sampler2D ink : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 iris_color : source_color = vec4(0.38,0.73,0.31,1.0);
uniform vec2 gaze_uv = vec2(0.0);
// dev 2026-09-25: iris 80 % of the open eye's height (20 % white left under it when its top
// touches the lid). Measured with open lids: the eye shows V 0.13-0.93 of the art (0.80 tall);
// the iris art is 0.946 tall, so 0.8 * 0.80 / 0.946 = 0.68. Scaled about the art's centre.
uniform float iris_scale = 0.68;
uniform vec2 iris_center = vec2(0.51, 0.5);

void fragment() {
	vec2 uv = (UV - gaze_uv - iris_center) / iris_scale + iris_center;
	vec4 tint = texture(tint_mask, uv);
	vec4 detail = texture(ink, uv);
	float inside = step(0.0,uv.x)*step(uv.x,1.0)*step(0.0,uv.y)*step(uv.y,1.0);
	vec3 color = mix(vec3(0.94), iris_color.rgb*tint.r+vec3(tint.g), tint.a*inside);
	color = mix(color,detail.rgb,detail.a*inside);
	ALBEDO = color;
	ROUGHNESS = 0.8;
	SPECULAR = 0.15;
}
