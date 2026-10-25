shader_type spatial;
render_mode world_vertex_coords, cull_disabled, diffuse_burley, specular_disabled;
#include "res://world/foliage/vegetation_color.gdshaderinc"
#include "res://world/foliage/impostors/impostor_fade.gdshaderinc"
// A distant tree as one quad (tools/impostors/bake_trees.gd): pictures of the full tree from
// `frames` directions around it, `grid` x `grid` cells per atlas. Albedo atlas: colour before
// ground hue and season (sRGB), alpha = coverage. Normal atlas: tree-space normal in rgb, leaf
// mask in a. The quad stands upright on the tree root and turns about Y toward the main camera
// (XR: the point between the eyes, so both eyes see the same quad); the two frames nearest to
// the view direction are blended. Lit like the trees themselves (burley, crown normals), with
// the same ground hue and season tint as the leaf cards and the far crown.
uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_atlas : filter_linear_mipmap, repeat_disable;
uniform float frames = 16.0;
uniform float grid = 4.0;
// Square picture side and the height of its centre above the root, in tree units.
uniform float quad_size = 20.0;
uniform float quad_centre_y = 8.0;
// Cells are grid x grid in the atlas: never sample mips small enough to reach a neighbour.
uniform float max_lod = 5.0;
uniform float ground_hue_strength = 0.35;
uniform float alpha_cutoff = 0.5;
varying flat vec4 cells;
varying flat float frame_mix;
varying flat vec3 tree_x;
varying flat vec3 tree_z;
varying flat vec4 ground;
varying flat float fade_t;

vec2 cell_of(float k) {
	return vec2(mod(k, grid), floor(k / grid));
}

void vertex() {
	vec3 root = MODEL_MATRIX[3].xyz;
	float scale = length(MODEL_MATRIX[0].xyz);
	tree_x = MODEL_MATRIX[0].xyz / scale;
	tree_z = MODEL_MATRIX[2].xyz / scale;
	vec3 eye = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;
	vec3 to_eye = eye - root;
	vec2 toward = to_eye.xz;
	toward = dot(toward, toward) > 1e-8 ? normalize(toward) : vec2(0.0, 1.0);
	// Frame k was baked from azimuth k * TAU / frames in tree space (x = sin, z = cos).
	float f = fract(atan(dot(to_eye, tree_x), dot(to_eye, tree_z)) / TAU) * frames;
	float k0 = floor(f);
	frame_mix = f - k0;
	cells = vec4(cell_of(k0), cell_of(mod(k0 + 1.0, frames)));
	vec3 right = vec3(toward.y, 0.0, -toward.x);
	VERTEX = root + (right * (UV.x - 0.5) * quad_size + vec3(0.0, quad_centre_y + (0.5 - UV.y) * quad_size, 0.0)) * scale;
	NORMAL = vec3(toward.x, 0.0, toward.y);
	ground = vegetation_ground(root.xz);
	fade_t = impostor_fade.y > 0.0 ? impostor_fade_amount(eye, root) : 1.0;
}

void fragment() {
	if (impostor_dither(FRAGCOORD.xy) >= fade_t) { discard; }
	vec2 atlas_px = vec2(textureSize(albedo_atlas, 0));
	vec2 dx = dFdx(UV) * atlas_px / grid;
	vec2 dy = dFdy(UV) * atlas_px / grid;
	float lod = clamp(0.5 * log2(max(max(dot(dx, dx), dot(dy, dy)), 1e-8)), 0.0, max_lod);
	vec2 uv0 = (cells.xy + UV) / grid;
	vec2 uv1 = (cells.zw + UV) / grid;
	vec4 albedo = mix(textureLod(albedo_atlas, uv0, lod), textureLod(albedo_atlas, uv1, lod), frame_mix);
	vec4 packed = mix(textureLod(normal_atlas, uv0, lod), textureLod(normal_atlas, uv1, lod), frame_mix);
	ALPHA = albedo.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;
	vec3 n = packed.rgb * 2.0 - 1.0;
	vec3 world_n = normalize(tree_x * n.x + vec3(0.0, n.y, 0.0) + tree_z * n.z);
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);
	ALBEDO = vegetation_hue(albedo.rgb, ground, ground_hue_strength * packed.a);
	ROUGHNESS = 1.0;
}
