// The show line around unicorn magic (dev 2026-09-23: "add the same show outline to it as the
// ponies themselves but as the magic color"). An inverted hull, like the ponies' outline:
// the mesh pushed out a little further than the aura, front faces culled, drawn in the magic's
// ink colour (a darker, more saturated shade of the magic colour). Fades with the glow.
// Used as the aura material's next_pass (unicorn_magic.gd).
shader_type spatial;
render_mode blend_mix, unshaded, cull_front, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 line_color : source_color = vec4(0.6, 0.05, 0.3, 1.0);
uniform float intensity : hint_range(0.0, 1.0) = 1.0;
uniform float width = 0.0035;             // metres beyond the aura shell
uniform float grow = 0.004;               // the aura's own push

void vertex() {
	VERTEX += NORMAL * (grow + width);
}

void fragment() {
	ALBEDO = line_color.rgb;
	ALPHA = clamp(intensity, 0.0, 1.0);
}
