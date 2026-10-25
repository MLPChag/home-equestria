shader_type spatial;
render_mode cull_disabled;
uniform sampler2D artwork : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform mat4 world_to_room;
uniform int surface_kind = 0;
varying vec3 room_position;

void vertex() {
	room_position = (world_to_room * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 coordinates;
	if (surface_kind == 0) {
		float turn = atan(room_position.x, room_position.z) / 6.28318530718 + 0.5;
		// Four mirrored spans join at matching texels around the complete trunk.
		// Artwork scale stays near 7m rather than stretching one square around 31m.
		float u = 1.0 - abs(mod(turn * 4.0, 2.0) - 1.0);
		coordinates = vec2(u, clamp(1.0 - room_position.y / 7.2, 0.001, 0.999));
	} else {
		coordinates = room_position.xz / 10.26 + vec2(0.5);
	}
	ALBEDO = texture(artwork, coordinates).rgb;
	ROUGHNESS = 0.94;
	SPECULAR = 0.18;
}
