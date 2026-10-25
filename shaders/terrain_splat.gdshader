shader_type spatial;
render_mode cull_back, diffuse_burley, specular_disabled;

// Unity paints terrain with up to eight layers, packed four-per-RGBA across two
// alphamaps. Ponydale uses all eight but four of them cover 96% of the ground,
// so we shade the four highest-coverage layers and renormalise. That keeps the
// texture fetch count affordable at 90 fps in stereo on the 3060 floor.
//
// The alphamaps are weight *data*, not colour: they must not carry source_color
// or Godot sRGB-decodes them, which silently rescales every weight.

uniform sampler2D splat0 : filter_linear, repeat_disable;
uniform sampler2D splat1 : filter_linear, repeat_disable;

uniform sampler2D layer0 : filter_linear_mipmap, repeat_enable, source_color;
uniform sampler2D layer1 : filter_linear_mipmap, repeat_enable, source_color;
uniform sampler2D layer2 : filter_linear_mipmap, repeat_enable, source_color;
uniform sampler2D layer3 : filter_linear_mipmap, repeat_enable, source_color;
uniform sampler2D layer4 : filter_linear_mipmap, repeat_enable, source_color;
uniform sampler2D layer5 : filter_linear_mipmap, repeat_enable, source_color;

// Six layers, not four. Ponydale's town square is painted almost entirely with
// "ponyville dirt", a layer with only 1.6% coverage map-wide -- dropping it by
// global coverage left the square with zero weight in every sampled channel,
// which resolved to pure black. Low-coverage layers are not low-importance;
// they are exactly the authored detail (paths, plazas) players walk on.
uniform bool use_extra_layers = true;

// Selects which packed channel feeds each sampled layer. One-hot columns rather
// than an index array: dynamic indexing into a local array is the kind of thing
// shader compilers handle inconsistently, and a matrix multiply is free here.
// splat_mask0[j][i] = 1 when sampled layer i reads splat0's channel j.
uniform mat4 splat_mask0 = mat4(1.0);
uniform mat4 splat_mask1 = mat4(0.0);
// Same scheme for layers 4 and 5; only .xy of the result is used.
uniform mat4 splat_mask0b = mat4(0.0);
uniform mat4 splat_mask1b = mat4(0.0);

uniform vec2 tile_size_extra = vec2(5.0, 3.0);

// Metres of world space covered by one tile of each layer.
uniform vec4 tile_size = vec4(50.0, 5.0, 60.0, 3.0);

// Near-field detail. The dominant layer tiles at 50 m, which has no texture at
// walking distance and reads as flat plastic -- fatal in VR, where the ground a
// metre from your feet is most of what you see. One extra fetch of the dominant
// layer at high frequency, applied as luminance only so it adds texture without
// shifting hue, and faded out with distance so it never aliases.
uniform float detail_ratio = 16.0;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.45;
uniform float detail_near = 10.0;
uniform float detail_far = 55.0;

uniform vec3 tint : source_color = vec3(1.0);
// Large-scale value variation. Without it a 50 m grass tile repeated across
// 700 m reads as obvious wallpaper from any elevated viewpoint.
uniform float macro_variation : hint_range(0.0, 1.0) = 0.20;
uniform float macro_scale = 170.0;

// 0 = normal, 1 = raw splat0 RGB, 2 = raw splat1 RGB, 3 = selected weights.
// Set via HE_TERRAIN_DEBUG; the splat maps are the usual suspect when ground
// comes out a flat single colour.
uniform int debug_view = 0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float macro(vec2 p) {
	// Cheap low-frequency value noise; two offset sine lobes break up tiling
	// without costing a texture fetch.
	return 0.5 + 0.5 * sin(p.x * 1.7 + sin(p.y * 1.3)) * sin(p.y * 0.9 + 1.7);
}

void fragment() {
	vec4 s0 = texture(splat0, UV);
	vec4 s1 = texture(splat1, UV);
	vec4 w = splat_mask0 * s0 + splat_mask1 * s1;
	vec2 wx = vec2(0.0);
	if (use_extra_layers) {
		wx = (splat_mask0b * s0 + splat_mask1b * s1).xy;
	}

	// Guard against a zero-weight sample. Any ground the sampled layers do not
	// cover must fall back to the dominant layer, never to black -- an unpainted
	// pixel should look slightly wrong, not like a hole in the world.
	float total = w.x + w.y + w.z + w.w + wx.x + wx.y;
	if (total < 0.02) {
		w.x = 1.0;
		total = 1.0;
	}
	w /= total;
	wx /= total;

	vec2 p = world_pos.xz;
	vec3 col =
		texture(layer0, p / tile_size.x).rgb * w.x +
		texture(layer1, p / tile_size.y).rgb * w.y +
		texture(layer2, p / tile_size.z).rgb * w.z +
		texture(layer3, p / tile_size.w).rgb * w.w;
	if (use_extra_layers) {
		col += texture(layer4, p / tile_size_extra.x).rgb * wx.x
			+ texture(layer5, p / tile_size_extra.y).rgb * wx.y;
	}

	float near = 1.0 - smoothstep(detail_near, detail_far,
		length(world_pos - CAMERA_POSITION_WORLD));
	if (near > 0.002) {
		vec3 d = texture(layer0, p * detail_ratio / tile_size.x).rgb;
		float dl = dot(d, vec3(0.299, 0.587, 0.114));
		col *= mix(1.0, dl * 2.0, near * detail_strength);
	}

	col *= mix(1.0 - macro_variation, 1.0 + macro_variation, macro(p / macro_scale));

	ALBEDO = col * tint;
	if (debug_view == 1) { ALBEDO = s0.rgb; }
	else if (debug_view == 2) { ALBEDO = s1.rgb; }
	else if (debug_view == 3) { ALBEDO = w.xyz; }
	else if (debug_view == 4) { ALBEDO = vec3(fract(UV), 0.0); }
	if (debug_view != 0) {
		// Debug views are data, not shading -- show them unlit and unfogged.
		EMISSION = ALBEDO;
		ALBEDO = vec3(0.0);
	}
	ROUGHNESS = 1.0;
}
