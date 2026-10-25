shader_type spatial;
render_mode cull_disabled;
// Cloudominium cloud furniture (dev 2026-09-28): soft white puffs shaded pale blue underneath
// and towards their silhouette, with sparse swirl lines like the show's clouds. Lit, not emissive.
// The same shader dresses the lavender cloud sofa (cloud_fabric) with other colours.
uniform sampler2D swirls : source_color, filter_linear_mipmap_anisotropic, repeat_enable, hint_default_transparent;
uniform vec4 base_color : source_color = vec4(0.98, 0.99, 1.0, 1.0);
uniform vec4 shade_color : source_color = vec4(0.8, 0.9, 0.97, 1.0);
uniform vec4 line_color : source_color = vec4(0.64, 0.82, 0.94, 1.0);
uniform float swirl_size = 0.9;
uniform float line_strength = 0.75;
uniform float roughness_value = 0.95;
varying vec3 local_position;
varying vec3 local_normal;
varying vec3 world_normal;

void vertex() {
	local_position = VERTEX;
	local_normal = NORMAL;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	float under = smoothstep(0.3, -0.8, normalize(world_normal).y);
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.5);
	vec3 colour = mix(base_color.rgb, shade_color.rgb, clamp(under * 0.7 + rim * 0.5, 0.0, 1.0));
	vec3 weights = pow(abs(normalize(local_normal)), vec3(4.0));
	weights /= weights.x + weights.y + weights.z;
	vec3 p = local_position / swirl_size;
	float line = texture(swirls, vec2(p.z, -p.y)).a * weights.x
			+ texture(swirls, p.xz).a * weights.y
			+ texture(swirls, vec2(p.x, -p.y)).a * weights.z;
	ALBEDO = mix(colour, line_color.rgb, line * line_strength);
	ROUGHNESS = roughness_value;
	SPECULAR = 0.12;
}
