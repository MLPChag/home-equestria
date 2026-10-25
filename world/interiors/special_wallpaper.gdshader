shader_type spatial;
render_mode cull_disabled, specular_disabled;
uniform sampler2D paper : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool circular = false;
varying vec3 room_position;
void vertex() {
	room_position = VERTEX;
}
void fragment() {
	// Twelve mirrored spans meet exactly at the round hall's back seam.
	// Its 4.68 m radius gives a 2.45 m repeat, matching the flat room partitions.
	vec2 paper_uv = circular ? vec2(atan(room_position.x, room_position.z) * (12.0 / TAU), -room_position.y / 2.45044) : UV / 2.45044;
	paper_uv = 1.0 - abs(mod(paper_uv, 2.0) - 1.0);
	ALBEDO = texture(paper, paper_uv).rgb;
	ROUGHNESS = 0.88;
	if (!FRONT_FACING) { NORMAL = -NORMAL; }
}
