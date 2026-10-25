shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Direct port of /Game/GrassyFields/Materials/M_Cliff from export-05.
// Source node references below use their names in M_Cliff.t3d. Unreal values
// expressed in centimetres are supplied as metres by grassy_fields_materials.gd
// because GLTFExportOptions.export_uniform_scale=0.01 makes the mesh metres.
//
// The source's MF_RVTColor and MF_RVTHeight are Runtime Virtual Texture reads.
// The browser uses its explicit ground plane. Placed world models receive a
// terrain tangent plane at their root; this is a local contact approximation,
// not a spatial RVT colour/height texture over an entire mountain.

uniform sampler2D rock_texture : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D base_normal_texture : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D blend_noise_texture : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec4 tint : source_color = vec4(0.663077, 0.643044, 0.859375, 0.0);
uniform float tint_strength = 0.4;
uniform float terrain_blend_m = 0.3096665192;
uniform float gradient_height = -1.080569;
uniform float noise_uv_scale = 16.027515;
uniform float upvector_sharpness = 10.0;
uniform float upvector_bias = -3.0;
uniform float texture_near_size_m = 15.0;
uniform float texture_far_size_m = 30.0;
uniform float texture_fade_start_m = 15.0;
uniform float texture_fade_divisor_m = 30.0;
uniform vec4 ground_color : source_color = vec4(0.134753, 0.291667, 0.057725, 1.0);
uniform vec3 ground_normal_world = vec3(0.0, 1.0, 0.0);
uniform float ground_height_m = 0.0;
instance uniform bool use_terrain_contact = false;
// World plane dot(normal, position) + w = 0. Zero normal means no terrain.
instance uniform vec4 terrain_contact_plane = vec4(0.0);

varying vec3 world_position;
varying vec3 world_normal;
varying vec3 world_tangent;
varying vec3 world_binormal;
varying float source_pixel_depth_m;


void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_NORMAL_MATRIX * NORMAL));
	world_tangent = normalize((MODEL_NORMAL_MATRIX * TANGENT));
	world_binormal = normalize((MODEL_NORMAL_MATRIX * BINORMAL));
	// UE PixelDepth is positive view-axis depth in world units, not radial
	// distance to the camera.
	source_pixel_depth_m = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}


// Engine WorldAlignedTexture divides UE world XYZ by TextureSize XYZ and
// samples YZ, XZ, and XY. Epic GLTFCoreUtilities.cpp maps UE (X,Y,Z) to glTF
// (X,Z,Y) without a sign change; Godot therefore sees those UVs as (Z,Y),
// (X,Y), and (X,Z).
// WorldAlignedTexture's exported LinearInterpolate_0 then mixes the UE-Y and
// UE-X projections by abs(UE normal X); LinearInterpolate_1 mixes that result
// with the UE-Z projection by abs(UE normal Z). The authored
// ProjectionTransitionContrast=1 runs through CheapContrast, whose exported
// graph is clamp((2*C+1)*x-C): at C=1 this is clamp(3*x-1), not identity.
vec3 world_aligned_texture(vec3 position_m, vec3 normal_world, float size_m) {
	vec3 ue_x_projection = texture(
		rock_texture, vec2(position_m.z, position_m.y) / size_m).rgb;
	vec3 ue_y_projection = texture(
		rock_texture, position_m.xy / size_m).rgb;
	vec3 ue_z_projection = texture(
		rock_texture, vec2(position_m.x, position_m.z) / size_m).rgb;
	float ue_x_weight = clamp(3.0 * abs(normal_world.x) - 1.0, 0.0, 1.0);
	float ue_z_weight = clamp(3.0 * abs(normal_world.y) - 1.0, 0.0, 1.0);
	vec3 xy_texture = mix(ue_y_projection, ue_x_projection, ue_x_weight);
	return mix(xy_texture, ue_z_projection, ue_z_weight);
}


void fragment() {
	vec3 geometric_world_normal = normalize(world_normal);
	// LinearInterpolate_13 alpha is Clamp((PixelDepth - FadeStart) / FadeEnd).
	// FadeEnd is the divisor in the authored graph, not (end - start).
	float distance_alpha = clamp(
		(source_pixel_depth_m - texture_fade_start_m)
		/ max(texture_fade_divisor_m, 0.00001), 0.0, 1.0);
	vec3 near_rock = world_aligned_texture(
		world_position, geometric_world_normal, max(texture_near_size_m, 0.00001));
	vec3 far_rock = world_aligned_texture(
		world_position, geometric_world_normal, max(texture_far_size_m, 0.00001));
	vec3 rock_color = mix(near_rock, far_rock, distance_alpha);
	rock_color = mix(rock_color, tint.rgb, tint_strength); // LinearInterpolate_4.

	// TextureSampleParameter2D_0 is a standalone Unreal normal PNG. Unlike the
	// GLB material bake, it was not adjusted by Epic's glTF exporter, so invert
	// its green tangent component before giving the vector to Godot.
	vec3 rock_tangent_normal = texture(base_normal_texture, UV).xyz * 2.0 - 1.0;
	rock_tangent_normal.y = -rock_tangent_normal.y;
	rock_tangent_normal = normalize(rock_tangent_normal);
	vec3 explicit_world_normal = normalize(
		world_tangent * rock_tangent_normal.x
		+ world_binormal * rock_tangent_normal.y
		+ world_normal * rock_tangent_normal.z);

	// WorldAlignedBlend "w/ Explicit Normal", Clamped=true, Alpha=1:
	// clamp((dot(N,Up)*0.5+0.5)*Sharpness + Bias-Sharpness*0.5)
	// simplifies to clamp(dot(N,Up)*0.5*Sharpness + Bias).
	float top_alpha = clamp(
		dot(explicit_world_normal, normalize(ground_normal_world))
		* 0.5 * upvector_sharpness + upvector_bias, 0.0, 1.0);
	// VertexColor.R is the graph's "Used for erasing the grass" mask.
	float painted_top_alpha = top_alpha * clamp(COLOR.r, 0.0, 1.0);
	vec3 top_color = mix(rock_color, ground_color.rgb, painted_top_alpha);

	// Saturate_1 = noise(UV*NoiseUvScale)
	//   + (AbsoluteWorldPosition.Z - RVTHeight.WorldHeight)/TerrainBlendAmount
	//   + GradientHeight. Godot Y is the converted UE Z axis.
	float blend_noise = texture(blend_noise_texture, UV * noise_uv_scale).r;
	float terrain_alpha = clamp(
		blend_noise + (world_position.y - ground_height_m)
		/ max(terrain_blend_m, 0.00001) + gradient_height, 0.0, 1.0);
	if (use_terrain_contact) {
		terrain_alpha = 1.0;
		if (terrain_contact_plane.y > 0.01) {
			float above_ground = (dot(terrain_contact_plane.xyz, world_position)
				+ terrain_contact_plane.w) / terrain_contact_plane.y;
			terrain_alpha = clamp(blend_noise + above_ground
				/ max(terrain_blend_m, 0.00001) + gradient_height, 0.0, 1.0);
		}
	}

	ALBEDO = mix(ground_color.rgb, top_color, terrain_alpha); // LinearInterpolate_0.
	// MakeMaterialAttributes roughness is 1, and LinearInterpolate_6 mixes 1
	// with that same value. MF_RVTColor roughness is not connected here.
	ROUGHNESS = 1.0;
	// M_CliffEditorOnlyData wires both Metallic and Specular to
	// MaterialExpressionConstant_1. Its omitted R retains Constant's 0 default.
	METALLIC = 0.0;
	SPECULAR = 0.0;

	vec3 ground_tangent_normal = normalize(vec3(
		dot(normalize(ground_normal_world), world_tangent),
		dot(normalize(ground_normal_world), world_binormal),
		dot(normalize(ground_normal_world), world_normal)));
	vec3 top_tangent_normal = normalize(mix(
		rock_tangent_normal, ground_tangent_normal, painted_top_alpha));
	NORMAL_MAP = normalize(mix(ground_tangent_normal, top_tangent_normal, terrain_alpha)) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;
}
