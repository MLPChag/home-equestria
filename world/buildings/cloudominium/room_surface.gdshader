shader_type spatial;
render_mode cull_disabled;
// Cloudominium painted room surfaces (dev 2026-09-28): walls, floors and ceilings take their
// artwork from the shared room frame, not mesh UVs, so paint continues across every piece.
// Ordinary lit albedo with restrained specular; painted walls are not emissive.
uniform sampler2D artwork : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform mat4 world_to_room;
// Until materials.gd set_room() binds the frame, each mesh's own space stands in for the room.
uniform bool room_bound = false;
// 0: cylindrical wall band, one artwork repeat per 1/repeats of the circumference.
// 1: plan (floor or ceiling), artwork square of plan_size metres centred on the tower axis.
uniform int surface_kind = 0;
uniform float base_y = 0.0;
uniform float band_height = 4.55;
uniform float repeats = 6.0;
uniform float plan_size = 9.5;
// Lounge rainbow painted across the upper wall: x = centre angle (radians), y = half span (m),
// z = circle centre height above base_y (m), w = outer radius (m). strength 0 disables it.
uniform vec4 rainbow = vec4(0.0, 3.3, -0.3, 4.6);
uniform float rainbow_band = 0.09;
uniform float rainbow_strength = 0.0;
uniform float wall_radius = 4.2;
varying vec3 room_position;

const vec3 RAINBOW[6] = vec3[6](vec3(0.95, 0.55, 0.55), vec3(0.97, 0.72, 0.48), vec3(0.96, 0.9, 0.55),
		vec3(0.62, 0.86, 0.58), vec3(0.55, 0.77, 0.93), vec3(0.72, 0.61, 0.9));

void vertex() {
	room_position = room_bound ? (world_to_room * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz : VERTEX;
}

vec3 painted_rainbow(vec3 colour, float angle) {
	float offset = mod(angle - rainbow.x + PI, TAU) - PI;
	float along = offset * wall_radius;
	float r = length(vec2(along, room_position.y - base_y - rainbow.z));
	float k = (rainbow.w - r) / rainbow_band;
	float aa = max(fwidth(k), 0.001);
	float inside = smoothstep(-aa, aa, k) * (1.0 - smoothstep(6.0 - aa, 6.0 + aa, k));
	float ends = 1.0 - smoothstep(rainbow.y * 0.6, rainbow.y, abs(along));
	int band = clamp(int(floor(k)), 0, 5);
	vec3 paint = mix(RAINBOW[band], RAINBOW[min(band + 1, 5)], smoothstep(1.0 - aa, 1.0, fract(k)));
	return mix(colour, paint, inside * ends * rainbow_strength);
}

void fragment() {
	vec3 paint;
	if (surface_kind == 0) {
		float angle = atan(room_position.x, room_position.z);
		float turn = angle / TAU + 0.5;
		// Increasing angle runs to a viewer's left inside the tower; 1 - turn keeps art unmirrored.
		vec2 coordinates = vec2((1.0 - turn) * repeats, clamp(1.0 - (room_position.y - base_y) / band_height, 0.001, 0.999));
		// Mip selection from a copy whose seam is on the opposite side, so the wrap line stays sharp.
		vec2 dx = dFdx(coordinates);
		vec2 dy = dFdy(coordinates);
		float other = fract(turn + 0.5);
		float other_dx = -dFdx(other) * repeats;
		float other_dy = -dFdy(other) * repeats;
		if (abs(other_dx) + abs(other_dy) < abs(dx.x) + abs(dy.x)) {
			dx.x = other_dx;
			dy.x = other_dy;
		}
		paint = textureGrad(artwork, coordinates, dx, dy).rgb;
		if (rainbow_strength > 0.0) {
			paint = painted_rainbow(paint, angle);
		}
	} else {
		paint = texture(artwork, room_position.xz / plan_size + vec2(0.5)).rgb;
	}
	ALBEDO = paint;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
}
