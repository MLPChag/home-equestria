shader_type spatial;
// Cartoon flagstone mapped in world space on three axes (stone_dressing.gd): ramps, stoops and
// foundations have no usable UVs, and stones run on continuously across ramp, landing and base.
render_mode cull_disabled;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0);
// Metres one texture tile covers.
uniform float tile = 1.6;
uniform float sharpness = 4.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 w = pow(abs(world_normal), vec3(sharpness));
	w /= max(w.x + w.y + w.z, 1e-4);
	vec3 p = world_pos / tile;
	vec3 c = texture(albedo_texture, p.zy).rgb * w.x + texture(albedo_texture, p.xz).rgb * w.y + texture(albedo_texture, p.xy).rgb * w.z;
	ALBEDO = c * tint.rgb;
	ROUGHNESS = 0.92;
}
