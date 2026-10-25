shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_prepass_alpha;

uniform sampler2D cloud_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 cloud_color : source_color = vec4(1.0);
uniform vec4 highlight_color : source_color = vec4(1.0);
uniform vec4 shadow_color : source_color = vec4(1.0, 0.459213, 0.0, 1.0);
uniform float cloud_brightness = 3.0;
uniform float highlight_intensity = 8.0;
uniform float shadow_intensity = 16.1193;
uniform float daylight : hint_range(0.0, 1.0) = 1.0;
uniform vec2 pan_speed = vec2(0.0);
uniform float review_time = -1.0;
uniform bool effects_enabled = true;

void fragment() {
	float t = review_time < 0.0 ? TIME : review_time;
	vec4 c = texture(cloud_texture, UV + (effects_enabled ? pan_speed * t : vec2(0.0)));
	vec3 bright = cloud_brightness * cloud_color.rgb;
	vec3 highlight = highlight_intensity * highlight_color.rgb;
	// M_Cloud's Lerp0 alpha is Texture.B; Texture.A is not used here.
	vec3 middle = mix(bright, highlight, c.b);
	// The shadow branch exists but is disconnected from EmissiveColor.
	ALBEDO = middle * mix(0.10, 1.0, daylight);
	ALPHA = c.g;
}
