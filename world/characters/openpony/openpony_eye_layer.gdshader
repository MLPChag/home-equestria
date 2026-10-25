shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_burley;
uniform sampler2D layer_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 gaze_uv = vec2(0.0);
uniform float iris_scale = 1.25;
// Bigger pupils (fillies, dev 2026-09-23): the pupil layer is scaled about its own centre.
uniform float pupil_scale = 1.0;
uniform float layer_opacity = 1.0;
uniform bool oval_highlights = false;
uniform vec2 pupil_centre = vec2(0.483, 0.496);
// A third, small shine low on the iris (fillies): drawn on the shine layer.
uniform bool third_shine = false;
uniform vec2 third_shine_at = vec2(0.405, 0.665);
uniform float third_shine_radius = 0.028;
void fragment() {
	vec2 at = (UV - vec2(0.5) - gaze_uv) / iris_scale + vec2(0.5);
	vec2 sample_at = pupil_centre + (at - pupil_centre) / pupil_scale;
	vec4 paint = texture(layer_texture, sample_at);
	paint.a *= layer_opacity;
	if (oval_highlights) {
		vec2 q = at - vec2(0.548, 0.350);
		q = mat2(vec2(0.906, 0.423), vec2(-0.423, 0.906)) * q;
		float large = length(q / vec2(0.064, 0.105));
		float small = length((at - vec2(0.394, 0.470)) / vec2(0.025, 0.030));
		float d = min(large, small);
		paint = vec4(vec3(1.0), 1.0 - smoothstep(0.94, 1.0, d));
	}
	if (third_shine) {
		float d = length((at - third_shine_at) * vec2(1.0, 0.8));
		float dot_alpha = 1.0 - smoothstep(third_shine_radius * 0.8, third_shine_radius, d);
		paint = mix(paint, vec4(1.0), dot_alpha);
		paint.a = max(paint.a, dot_alpha);
	}
	ALBEDO = paint.rgb;
	ALPHA = paint.a;
	ROUGHNESS = 0.35;
	SPECULAR = 0.2;
}
