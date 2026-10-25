shader_type spatial;
render_mode specular_disabled;

uniform sampler2D dust_map : repeat_enable, filter_linear_mipmap_anisotropic;
varying vec3 ground_position;

void vertex() {
	ground_position = VERTEX;
}

void fragment() {
	vec2 p = ground_position.xz;
	float broad = texture(dust_map, p * 0.0031).r;
	float dust = texture(dust_map, p * 0.055 + vec2(0.31, 0.67)).r;
	float grains = texture(dust_map, p * 1.7).r;
	float tone = clamp(0.20 + broad * 0.27 + dust * 0.10 + grains * 0.045, 0.23, 0.64);
	ALBEDO = vec3(tone * 1.015, tone, tone * 1.025);
	ROUGHNESS = 0.98;
	// Derivative bump follows the real surface, including slopes and rock facets.
	// Fade subpixel grains through the texture mip chain instead of sparkling in VR.
	float relief = dust * 0.014 + grains * 0.003;
	vec3 dx = dFdx(VERTEX);
	vec3 dy = dFdy(VERTEX);
	vec3 rx = cross(dy, NORMAL);
	vec3 ry = cross(NORMAL, dx);
	float determinant = dot(dx, rx);
	vec3 gradient = sign(determinant) * (dFdx(relief) * rx + dFdy(relief) * ry);
	NORMAL = normalize(max(abs(determinant), 0.0000001) * NORMAL - gradient);
}
