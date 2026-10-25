shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

#include "res://world/terrain/kits/grassy_fields/wind.gdshaderinc"
#include "res://world/foliage/vegetation_color.gdshaderinc"
uniform float ground_hue_strength : hint_range(0.0,1.0) = 0.85;
varying vec4 local_ground_color;

// M_TreeLeaves: card expansion + Inflate, source normal gradient, cutout,
// Fresnel-coloured transmission, MPC wind. Authored distances are centimetres.
uniform sampler2D opacity_mask : repeat_enable, filter_linear_mipmap;
uniform vec4 leaf_color : source_color;
uniform vec4 underside_color : source_color;
uniform vec4 highlight_color : source_color;
uniform float gradient_height = 1.0;
uniform float gradient_strength = 0.511615;
uniform float fresnel_exponent = 1.5;
uniform float highlight_strength = 0.35;
uniform float billboard_size_cm = 5.0;
uniform float inflate_cm = -1.5;
uniform float billboard_scale = 9.0;
uniform float cutoff = 0.333333;
uniform float wind_intensity = 1.0;
uniform float wind_speed = 1.0;
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_influence = 1.0;
uniform float wind_directional_strength = 10.0;
uniform float review_time = -1.0;
uniform bool effects_enabled = true;
varying vec3 source_world_normal;

void vertex() {
	source_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	vec3 world_m = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	local_ground_color=vegetation_ground(world_m.xz);
	// Multiply_4/5 -> AppendVector_0 -> ViewToInstance -> Normalize ->
	// BillboardSize -> InstanceToWorld. Keep instance scale in the displacement.
	vec2 corner = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);
	vec3 facing_world = mat3(INV_VIEW_MATRIX) * vec3(corner, 0.0);
	vec3 facing_local = inverse(mat3(MODEL_MATRIX)) * facing_world;
	facing_local /= max(length(facing_local), 0.00001);
	vec3 card_offset = (mat3(MODEL_MATRIX) * facing_local * billboard_size_cm
		+ source_world_normal * inflate_cm) * billboard_scale * 0.01;
	vec3 displacement = card_offset;
	if (effects_enabled) {
		float t = review_time < 0.0 ? TIME : review_time;
		vec2 direction = wind_direction / max(length(wind_direction), 0.00001);
		displacement += vec3(direction.x * wind_directional_strength, 1.0,
			direction.y * wind_directional_strength) * wind_intensity * 0.01;
		displacement += grassy_wind_offset(world_m, t, wind_intensity * wind_influence, 0.25, wind_speed);
	}
	VERTEX += inverse(mat3(MODEL_MATRIX)) * displacement;
}

void fragment() {
	if (texture(opacity_mask, UV).r < cutoff) { discard; }
	// LinearInterpolate_0: Leaf -> Underside by 1-pow((normal.z+height)*.5,strength).
	float top_weight = pow(max((normalize(source_world_normal).y + gradient_height) * 0.5, 0.0), gradient_strength);
	ALBEDO = mix(underside_color.rgb, leaf_color.rgb, top_weight);
	ALBEDO=vegetation_hue(ALBEDO,local_ground_color,ground_hue_strength*vegetation_green_mask(leaf_color.rgb));
	float facing = max(dot(normalize(NORMAL), normalize(VIEW)), 0.0);
	float fresnel = 0.04 + 0.96 * pow(1.0 - facing, fresnel_exponent);
	// Native output is SubsurfaceColor (not Emissive). Godot backlighting avoids
	// screen-space subsurface blur; different lighting model, same source colour.
	BACKLIGHT = ALBEDO + vegetation_hue(highlight_color.rgb,local_ground_color,ground_hue_strength*vegetation_green_mask(leaf_color.rgb)) * fresnel * highlight_strength;
	ROUGHNESS = 1.0;
}
