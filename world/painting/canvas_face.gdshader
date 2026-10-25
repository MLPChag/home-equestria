shader_type spatial;
// The live canvas face while someone paints (world/painting/easel_runtime.gd): one texel per
// cell, nearest filtered; empty cells (alpha 0) show the bare canvas colour, so the image is
// never flattened per frame. Idle easels use a plain StandardMaterial3D instead.
uniform sampler2D canvas_tex : source_color, filter_nearest;
uniform vec3 blank : source_color = vec3(0.949, 0.933, 0.894);
// A little self-light, the same as the idle canvas (easel_build.gd CANVAS_GLOW): a canvas in
// shade otherwise shows only blue sky light and the paints read wrong.
uniform float backlight = 0.4;

void fragment() {
	vec4 cell = texture(canvas_tex, UV);
	ALBEDO = mix(blank, cell.rgb, cell.a);
	EMISSION = ALBEDO * backlight;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
}
