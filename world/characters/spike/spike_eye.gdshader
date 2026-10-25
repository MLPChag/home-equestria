shader_type spatial;
render_mode diffuse_toon, specular_toon;
// Spike's eyes: white eyeball shells with the model's own iris texture (green, slit pupil,
// highlight; spike_iris_l/r.png) projected straight ahead, the way the Source model's eye shader
// did. UV2 is a planar map along his forward axis, centred on each eye's original eye locator
// (0.2 m per UV unit), so the iris rests where the model put it, a little toward his nose.
// gaze slides the iris (UV units, + = his left / up); the lids are the mesh's shape keys.
uniform vec4 sclera: source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D iris_texture: source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 iris_size = vec2(0.72, 0.72);
uniform vec2 gaze = vec2(0.0, 0.0);
uniform float inward = 0.0;
// Kept for older materials (the first Spike's drawn iris); unused with the texture.
uniform vec4 iris_color: source_color = vec4(0.32, 0.72, 0.30, 1.0);

void fragment() {
	vec2 p = vec2(UV2.x, 1.0 - UV2.y);
	vec2 c = vec2(0.5) + vec2(inward + gaze.x, gaze.y);
	vec2 q = (p - c) / iris_size + 0.5;
	vec3 col = sclera.rgb;
	if (q.x > 0.0 && q.x < 1.0 && q.y > 0.0 && q.y < 1.0) {
		vec4 iris = texture(iris_texture, vec2(q.x, 1.0 - q.y));
		col = mix(col, iris.rgb, iris.a);
	}
	ALBEDO = col;
	ROUGHNESS = 0.4;
	SPECULAR = 0.3;
}
