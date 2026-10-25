extends CanvasLayer
## "Desktop or VR?" before the title on every launch (dev 2026-10-20: "it should happen EVERY
## launch UNLESS save is deliberately chosen"). Ticking "Remember my choice" saves it as
## Settings "Start in VR" (user://launch.cfg, world/launch_config.gd) and stops the question;
## Start in VR > Ask every launch brings it back. Choosing VR restarts the game, because
## OpenXR only starts before any script runs.
signal chosen(mode: String, remember: bool)

const FONT := preload("res://world/ui/fonts/CelestiaMediumRedux.ttf")
const PINK := Color("f6a6d9")
const LILAC := Color("c06fdb")
const PLUM := Color("6b3f86")
const WHITE := Color(1, 1, 1)
const DEEP := Color(0.25, 0.13, 0.31)
var _remember: CheckBox


func _ready() -> void:
	layer = 100
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var back := ColorRect.new()
	back.color = DEEP
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(back)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", 28)
	back.add_child(box)
	box.add_child(_label("How do you want to play?", 48, WHITE))
	var desktop := _button("Desktop", "off")
	box.add_child(desktop)
	box.add_child(_button("VR headset", "on"))
	_remember = CheckBox.new()
	_remember.text = "Remember my choice"
	_remember.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_remember.add_theme_font_override("font", FONT)
	_remember.add_theme_font_size_override("font_size", 28)
	for state in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color", "font_hover_pressed_color"]:
		_remember.add_theme_color_override(state, WHITE)
	box.add_child(_remember)
	box.add_child(_label("A remembered choice can be changed in Settings, VR comfort, Start in VR.", 22, PINK))
	desktop.grab_focus()


func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", FONT)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(text: String, mode: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(520, 96)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.add_theme_font_override("font", FONT)
	button.add_theme_font_size_override("font_size", 36)
	for state in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
		button.add_theme_color_override(state, WHITE)
	button.add_theme_stylebox_override("normal", _style(LILAC))
	button.add_theme_stylebox_override("hover", _style(PINK))
	button.add_theme_stylebox_override("focus", _style(PINK))
	button.add_theme_stylebox_override("pressed", _style(LILAC.darkened(0.12)))
	button.pressed.connect(func() -> void: chosen.emit(mode, _remember.button_pressed))
	return button


func _style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = WHITE
	style.set_border_width_all(4)
	style.set_corner_radius_all(38)
	return style
