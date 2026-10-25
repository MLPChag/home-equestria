extends "res://world/life/arrival_wake.gd"
## Ordinary sleep fades over the whole view; the arrival story keeps its eyelids.
## Before the fade, the wake picker (world/life/wake_picker.gd) dims the view to drowsy and
## shows the chosen wake time, the controls, and at night a moon that fills while Space/A is
## held for Luna's dream.
const FADE_OUT_SECONDS := 2.0
const FADE_IN_SECONDS := 2.0
const DROWSY := 0.6
const MOON_PIXELS := 96
var _hint: Label
var _hint3d: Label3D
var _moon: MoonMeter
var _moon_view: SubViewport
var _moon3d: Sprite3D

func setup(host: Node) -> void:
	super.setup(host)
	set_process(false)
	_top.hide(); _bottom.hide()
	_set_closed(0.0)

func close_eyes() -> void:
	await _fade(1.0, FADE_OUT_SECONDS)

func open_eyes(seconds := FADE_IN_SECONDS) -> void:
	_say("")
	hide_picker()
	await _fade(0.0, seconds)

## Heavy eyelids while the wake time is chosen.
func drowse(seconds := 0.5) -> void:
	await _fade(DROWSY, seconds)

## Wall time keeps the short transition bounded even when a frame takes longer.
## A newer fade (say the picker confirmed while still drowsing) takes over from an older one.
var _fade_serial := 0
func _fade(to: float, seconds: float) -> void:
	_fade_serial += 1
	var serial := _fade_serial
	var from := _closed
	var began := Time.get_ticks_usec()
	while true:
		var elapsed := float(Time.get_ticks_usec() - began) * .000001
		_set_closed(lerpf(from, to, smoothstep(0.0, 1.0, minf(1.0, elapsed / maxf(.001, seconds)))))
		if elapsed >= seconds: return
		if not await SHUTDOWN.frame(self) or serial != _fade_serial: return

func show_text(text: String) -> void:
	_say(text)

## The picker's words: `line` in the usual place, `hint` smaller beneath it; `moon` < 0 hides
## the Luna meter, else 0..1 is how full it is.
func show_picker(line: String, hint: String, moon: float) -> void:
	_say(line)
	_build_picker()
	if is_instance_valid(_hint): _hint.text = hint
	if is_instance_valid(_hint3d): _hint3d.text = hint
	_moon.visible = moon >= 0.0
	_moon.value = maxf(moon, 0.0)
	_moon.queue_redraw()
	if is_instance_valid(_moon3d): _moon3d.visible = _moon.visible

func hide_picker() -> void:
	if is_instance_valid(_hint): _hint.text = ""
	if is_instance_valid(_hint3d): _hint3d.text = ""
	if is_instance_valid(_moon): _moon.visible = false
	if is_instance_valid(_moon3d): _moon3d.visible = false

func _build_picker() -> void:
	if is_instance_valid(_moon): return
	_text.offset_bottom = -150
	_hint = Label.new(); _hint.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; _hint.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_hint.offset_bottom = -70; _hint.add_theme_font_size_override("font_size", 20)
	_hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.78))
	_hint.add_theme_color_override("font_outline_color", Color.BLACK); _hint.add_theme_constant_override("outline_size", 6)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE; _layer.add_child(_hint)
	_moon = MoonMeter.new()
	if headset and is_instance_valid(_text3d):
		# The headset sees the meter through a small viewport on a sprite beside the words.
		_moon_view = SubViewport.new(); _moon_view.size = Vector2i(MOON_PIXELS, MOON_PIXELS)
		_moon_view.transparent_bg = true; _moon_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(_moon_view); _moon_view.add_child(_moon)
		_moon.set_anchors_preset(Control.PRESET_FULL_RECT); _moon.size = Vector2(MOON_PIXELS, MOON_PIXELS)
		var camera := _text3d.get_parent() as Camera3D
		_hint3d = _text3d.duplicate() as Label3D; _hint3d.name = "WakeHint"
		_hint3d.font_size = 26; _hint3d.outline_size = 7; _hint3d.modulate = Color(0.8, 0.8, 0.78)
		_hint3d.position = _text3d.position + Vector3(0, -0.045, 0); _hint3d.text = ""
		camera.add_child(_hint3d)
		_text3d.position.y += 0.03
		_moon3d = Sprite3D.new(); _moon3d.name = "WakeMoon"; _moon3d.texture = _moon_view.get_texture()
		_moon3d.pixel_size = 0.0004; _moon3d.no_depth_test = true; _moon3d.render_priority = 112
		_moon3d.shaded = false; _moon3d.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_moon3d.position = _text3d.position + Vector3(0, 0.06, 0)
		camera.add_child(_moon3d)
		var hud := preload("res://world/ui/head_locked_hud.gd")
		hud.attach(camera, _hint3d); hud.attach(camera, _moon3d)
	else:
		# Above the wake line (whose bottom sits 150 px up, about 40 px tall).
		_layer.add_child(_moon)
		_moon.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		_moon.offset_left = -MOON_PIXELS * 0.5; _moon.offset_right = MOON_PIXELS * 0.5
		_moon.offset_bottom = -200; _moon.offset_top = -200 - MOON_PIXELS

func finish() -> void:
	queue_free()

func _exit_tree() -> void:
	super._exit_tree()
	if is_instance_valid(_hint3d): _hint3d.queue_free()
	if is_instance_valid(_moon3d): _moon3d.queue_free()

## A crescent moon in a ring; the ring fills (and the moon brightens) while Luna is being asked for.
class MoonMeter extends Control:
	var value := 0.0
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var centre := size * 0.5
		var radius := minf(size.x, size.y) * 0.36
		var dim := Color(0.55, 0.6, 0.75, 0.55)
		var moonlight := Color(0.75, 0.83, 1.0)
		draw_arc(centre, radius, 0.0, TAU, 48, Color(0.0, 0.0, 0.0, 0.45), 7.0, true)
		if value > 0.001:
			draw_arc(centre, radius, -PI * 0.5, -PI * 0.5 + TAU * value, 48, moonlight, 4.5, true)
		# Left-facing crescent: the left half circle, closed by a half ellipse.
		var r := radius * 0.62
		var points := PackedVector2Array()
		for i in 17:
			var a := PI * 0.5 + PI * float(i) / 16.0
			points.append(centre + Vector2(cos(a), sin(a)) * r)
		for i in range(1, 16):
			var a := PI * 1.5 - PI * float(i) / 16.0
			points.append(centre + Vector2(cos(a) * 0.4, sin(a)) * r)
		draw_colored_polygon(points, dim.lerp(moonlight, value))
