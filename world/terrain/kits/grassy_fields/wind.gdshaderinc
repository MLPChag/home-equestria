// Epic SimpleGrassWind, reconstructed from UE 5.8's exported material function.
// Inputs/outputs at this boundary are Godot XYZ metres. Internally positions and
// offsets are converted to Unreal XYZ centimetres (UE X,Y,Z -> glTF/Godot X,Z,Y).
float grassy_effect_time(float review_time) {
	return review_time < 0.0 ? TIME : review_time;
}
vec3 grassy_ue_cm(vec3 godot_m) {
	return vec3(godot_m.x, godot_m.z, godot_m.y) * 100.0;
}
vec3 grassy_godot_m(vec3 ue_cm) {
	return vec3(ue_cm.x, ue_cm.z, ue_cm.y) * 0.01;
}
vec3 grassy_smooth_triangle(vec3 phase) {
	// SimpleGrassWind nodes: frac; *2-1; abs; 3-2*x; x*x*(3-2*x).
	vec3 x = abs(fract(phase) * 2.0 - 1.0);
	return x * x * (3.0 - 2.0 * x);
}
vec3 grassy_rotate_axis_offset(vec3 position, vec3 pivot, vec3 axis, float turns) {
	// UE RotateAboutAxis's angle is expressed in turns and returns an offset.
	float angle = turns * 6.28318530718;
	vec3 v = position - pivot;
	vec3 rotated = v * cos(angle) + cross(axis, v) * sin(angle)
		+ axis * dot(axis, v) * (1.0 - cos(angle));
	return rotated - v;
}
vec3 grassy_simple_wind(vec3 world_position_m, float time_s, float intensity,
		float weight, float speed, vec3 additional_godot_m) {
	vec3 p = grassy_ue_cm(world_position_m);
	vec3 direction = vec3(0.0, 1.0, 0.0); // native function constant4 RGB
	vec3 wave_a = grassy_smooth_triangle(p / 200.0 - time_s * speed * 0.5 + 0.5);
	vec3 wave_b = grassy_smooth_triangle(p / 1024.0
		+ direction * (-time_s * speed * 0.5) + 0.5);
	// Exported graph combines distance(first wave, 0) with dot(direction, second).
	float turns = length(wave_a) + dot(direction, wave_b);
	vec3 additional = grassy_ue_cm(additional_godot_m);
	vec3 axis = normalize(cross(direction, vec3(0.0, 0.0, 1.0)));
	vec3 pivot = additional + vec3(0.0, 0.0, -10.0);
	vec3 rotated = grassy_rotate_axis_offset(additional, pivot, axis, turns);
	return grassy_godot_m(rotated * weight * intensity + additional);
}
// Shared interface used by grass, foliage, and tree leaves.
vec3 grassy_wind_offset(vec3 world_m, float time_s, float intensity,
		float weight, float speed) {
	return grassy_simple_wind(world_m, time_s, intensity, weight, speed, vec3(0.0));
}
vec3 grassy_directional_wind(vec2 ue_xy, float intensity, float strength_m) {
	float l = length(ue_xy);
	vec2 d = l > 0.00001 ? ue_xy / l : vec2(1.0, 0.0);
	// UE horizontal XY maps to Godot XZ.
	return vec3(d.x, 0.0, d.y) * intensity * strength_m;
}
vec3 grassy_interaction(vec3 world_m, vec3 player_m, float radius_m,
		float bend_m, float trample_m, float height_weight) {
	vec3 delta = world_m - player_m;
	float proximity = 1.0 - clamp(length(delta) / max(radius_m, 0.0001), 0.0, 1.0);
	vec2 horizontal = delta.xz;
	vec2 away = length(horizontal) > 0.00001 ? normalize(horizontal) : vec2(0.0);
	vec3 bend = vec3(away.x * bend_m, 0.0, away.y * bend_m) * height_weight;
	return (bend + vec3(0.0, trample_m, 0.0)) * proximity;
}
