shader_type spatial;
// Diffuse room fill follows the sky controller, including its dim night baseline.
// Keep thin-roof GI leaks out of the room shell; normal scene lamps still add light.
render_mode cull_disabled, specular_disabled, ambient_light_disabled;
global uniform vec4 interior_light;
uniform sampler2D albedo_map : source_color, filter_linear_mipmap_anisotropic;
uniform bool interior_view = true;
uniform bool has_texture = false;
uniform vec4 base_color : source_color = vec4(1.0);
// Floors laid in world space (planks continue across slab pieces and the threshold ramp).
uniform bool planar = false;
uniform vec2 planar_size = vec2(3.5, 7.0);
// Planar floors: only the walking surface is wood. Slab sides that poke out past the walls
// read as the stone foundation instead of wood running out of the house (dev 2026-09-23).
uniform vec4 side_color : source_color = vec4(0.62, 0.58, 0.56, 1.0);
varying vec3 v_world;
void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	if (!interior_view && FRONT_FACING) { discard; }
	if (!FRONT_FACING) { NORMAL = -NORMAL; }
	vec2 uv = planar ? v_world.xz / planar_size : UV;
	ALBEDO = base_color.rgb * (has_texture ? texture(albedo_map, uv).rgb : vec3(1.0));
	if (planar && abs((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y) < 0.5) { ALBEDO = side_color.rgb; }
	EMISSION = ALBEDO * interior_light.rgb;

	ROUGHNESS = 1.0;
}
