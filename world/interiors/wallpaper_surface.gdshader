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
// Wallpaper is projected in house-aligned metres only onto pale vertical plaster.
// The source atlas remains the mask so its timber and roof detail is preserved.
uniform bool wallpaper = false;
// Copied exterior shells use backfaces; authored room surfaces use frontfaces.
// A closed repair also names its inward normal, excluding its coplanar outer cap.
uniform bool wallpaper_front_faces = false;
uniform vec3 wallpaper_inward_normal = vec3(0.0);
uniform sampler2D wallpaper_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform mat4 wallpaper_frame;
uniform float wallpaper_metres = 2.4;
// Authored roof faces share this room pass. UV2.x is a baked face-role marker,
// not a runtime guess from atlas colors or a smoothed surface normal.
uniform bool authored_ceiling = false;
uniform vec4 ceiling_color : source_color = vec4(0.78, 0.75, 0.68, 1.0);
// Measured inner plaster patch where the imported atlas baked an exterior awning.
uniform bool plaster_patch = false;
uniform bool plaster_patch_mirror_x = false;
uniform vec3 plaster_patch_min;
uniform vec3 plaster_patch_max;
uniform vec2 plaster_patch_keep_band;
varying vec3 paper_position;
varying vec3 paper_normal;
varying vec3 v_world;
void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	paper_position = (wallpaper_frame * vec4(v_world, 1.0)).xyz;
	paper_normal = normalize(mat3(wallpaper_frame) * MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
	bool ceiling = wallpaper && authored_ceiling && UV2.x > 0.5;
	bool moved_ceiling = ceiling && UV2.x < 1.5;
	if (wallpaper) {
		// Both sides previously existed across the outside and room passes.
		// A moved roof face must keep that coverage, including its thin edges.
		if (!moved_ceiling && FRONT_FACING != wallpaper_front_faces) { discard; }
		if (dot(wallpaper_inward_normal, wallpaper_inward_normal) > 0.5 && dot(normalize(paper_normal), wallpaper_inward_normal) < 0.5) { discard; }

	} else if (!interior_view && FRONT_FACING) { discard; }
	if (!FRONT_FACING) { NORMAL = -NORMAL; }
	vec2 uv = planar ? v_world.xz / planar_size : UV;
	ALBEDO = ceiling ? ceiling_color.rgb : base_color.rgb * (has_texture ? texture(albedo_map, uv).rgb : vec3(1.0));
	if (planar && abs((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y) < 0.5) { ALBEDO = side_color.rgb; }
	if (wallpaper && !ceiling) {
		vec3 original = has_texture ? texture(albedo_map, UV).rgb : vec3(1.0);
		// Imported facades: cream/white/lavender plaster, red-brown wood, ochre thatch.
		// Ratios preserve cream plaster through baked shading; red/pink timbers stay.
		float plaster = smoothstep(0.60, 0.76, original.g / max(original.r, 0.001));
		plaster *= smoothstep(0.58, 0.72, original.b / max(original.r, 0.001));
		vec3 face_normal = normalize(cross(dFdx(paper_position), dFdy(paper_position)));
		float wall = 1.0 - step(0.5, abs(face_normal.y));
		vec3 patch_position = paper_position;
		if (plaster_patch_mirror_x) { patch_position.x = -abs(patch_position.x); }
		if (plaster_patch && all(greaterThanEqual(patch_position, plaster_patch_min)) && all(lessThanEqual(patch_position, plaster_patch_max)) && (paper_position.y < plaster_patch_keep_band.x || paper_position.y > plaster_patch_keep_band.y)) { plaster = 1.0; }
		float mask = plaster * wall;
		vec2 paper_uv = abs(face_normal.x) > abs(face_normal.z) ? paper_position.zy : paper_position.xy;
		// Mirrored repeats meet without hard colour seams on generated tiles.
		paper_uv = 1.0 - abs(mod(paper_uv / wallpaper_metres, 2.0) - 1.0);
		ALBEDO = mix(ALBEDO, texture(wallpaper_map, paper_uv).rgb, mask);
	}
	EMISSION = ALBEDO * interior_light.rgb;

	ROUGHNESS = 1.0;
}
