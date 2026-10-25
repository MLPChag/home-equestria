shader_type spatial;
render_mode cull_disabled;
// Cloudominium object paint (dev 2026-09-28) in the mesh's own space, independent of its UVs:
// primitive BoxMesh atlases, imported models and hand-built cloth all receive the same art.
// 0: art repeats every art_size metres, projected along the dominant local axis (tiles).
// 1: one decal of art_size metres centred on the local origin, on upward faces (quilt top).
// 2: diagonal rainbow bands of band_width metres (guitar body).
uniform int art_mode = 0;
uniform sampler2D art : source_color, filter_linear_mipmap_anisotropic, repeat_enable, hint_default_transparent;
uniform vec4 base_color : source_color = vec4(1.0);
uniform vec2 art_size = vec2(1.0);
uniform vec2 decal_centre = vec2(0.0);
uniform float band_width = 0.06;
uniform float roughness_value = 0.9;
uniform float specular_value = 0.25;
varying vec3 local_position;
varying vec3 local_normal;

const vec3 RAINBOW[6] = vec3[6](vec3(0.87, 0.16, 0.17), vec3(0.95, 0.44, 0.2), vec3(0.99, 0.85, 0.3),
		vec3(0.38, 0.74, 0.3), vec3(0.12, 0.6, 0.83), vec3(0.42, 0.23, 0.61));

void vertex() {
	local_position = VERTEX;
	local_normal = NORMAL;
}

// Premultiplied sample so blending between projections never picks up transparent texel colour.
vec4 painted(vec2 coordinates) {
	vec4 texel = texture(art, coordinates / art_size);
	return vec4(texel.rgb * texel.a, texel.a);
}

void fragment() {
	vec3 colour = base_color.rgb;
	vec3 n = normalize(local_normal);
	if (art_mode == 0) {
		vec3 weights = pow(abs(n), vec3(4.0));
		weights /= weights.x + weights.y + weights.z;
		vec4 paint = painted(vec2(local_position.z, -local_position.y)) * weights.x
				+ painted(local_position.xz) * weights.y
				+ painted(vec2(local_position.x, -local_position.y)) * weights.z;
		colour = colour * (1.0 - paint.a) + paint.rgb;
	} else if (art_mode == 1) {
		vec2 coordinates = (local_position.xz - decal_centre) / art_size + vec2(0.5);
		vec4 texel = texture(art, clamp(coordinates, vec2(0.0), vec2(1.0)));
		float upward = smoothstep(0.25, 0.55, n.y);
		colour = mix(colour, texel.rgb, texel.a * upward);
	} else {
		float k = (local_position.x + local_position.y) / band_width;
		float aa = max(fwidth(k), 0.001);
		int band = int(mod(floor(k), 6.0));
		colour = mix(RAINBOW[band], RAINBOW[(band + 1) % 6], smoothstep(1.0 - aa, 1.0, fract(k)));
	}
	ALBEDO = colour;
	ROUGHNESS = roughness_value;
	SPECULAR = specular_value;
}
