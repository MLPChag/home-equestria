extends VBoxContainer
## On-panel keyboard for text fields on the VR World Panel (dev 2026-09-29: "how do you type
## an API key on a Quest without losing your mind"). Its keys are focus-less Buttons, so the
## LineEdit being edited keeps focus and receives the InputEventKey each key pushes into the
## panel's SubViewport. "Load key file" fills the field from api_key.txt instead of typing:
## next to the game on desktop, or in the app's files folder on a headset.
signal key_file_loaded(text: String)
const ROWS := [
	"1234567890-_",
	"qwertyuiop[]",
	"asdfghjkl;:'",
	"zxcvbnm,./@#",
]
const APP_FILES := preload("res://tools/build/packs.gd")
const KEY_NAMES := ["api_key.txt", "api_key.txt.txt"]
var panel: Node  # spatial_menu_panel: send_key(InputEventKey), refresh()
var status: Label
var _shift := false
var _letters: Array[Button] = []

func setup(surface: Node, width: float, font: int) -> void:
	panel = surface
	custom_minimum_size.x = width
	add_theme_constant_override("separation", 4)
	var hint := Label.new(); hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", font - 4); hint.add_theme_color_override("font_color", Color("acb4c0"))
	hint.text = "Typing into the field above. Or put the key in api_key.txt (next to the game; on a headset in the app's files folder, Android/data/.../files) and press Load key file."
	add_child(hint)
	var key_width := (width - 4.0 * 11.0) / 12.0
	for row: String in ROWS:
		var line := HBoxContainer.new(); line.add_theme_constant_override("separation", 4); add_child(line)
		for ch in row:
			var b := _key(line, ch, key_width, font)
			b.pressed.connect(_type.bind(b))
			if (ch as String).to_lower() != (ch as String).to_upper(): _letters.append(b)
	var bottom := HBoxContainer.new(); bottom.add_theme_constant_override("separation", 4); add_child(bottom)
	var shift := _key(bottom, "Shift", key_width * 1.5, font); shift.toggle_mode = true
	shift.toggled.connect(func(on: bool): _shift = on; _relabel())
	var space := _key(bottom, "Space", key_width * 4.0, font); space.pressed.connect(func(): _send(KEY_SPACE, " ".unicode_at(0)))
	var back := _key(bottom, "Backspace", key_width * 2.2, font); back.pressed.connect(func(): _send(KEY_BACKSPACE, 0))
	var enter := _key(bottom, "Enter", key_width * 1.4, font); enter.pressed.connect(func(): _send(KEY_ENTER, 0))
	var clear := _key(bottom, "Clear", key_width * 1.4, font); clear.pressed.connect(_clear)
	var file := _key(bottom, "Load key file", key_width * 2.6, font); file.pressed.connect(_load_file)
	status = Label.new(); status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_font_size_override("font_size", font - 4); add_child(status)

func _key(parent: Node, text: String, width: float, font: int) -> Button:
	var b := Button.new(); b.text = text; b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(width, 48); b.add_theme_font_size_override("font_size", font)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL; parent.add_child(b)
	return b

func _relabel() -> void:
	for b in _letters: b.text = b.text.to_upper() if _shift else b.text.to_lower()

func _type(b: Button) -> void:
	var ch: String = b.text
	_send(KEY_NONE, ch.unicode_at(0))

func _send(keycode: Key, unicode: int) -> void:
	if panel == null: return
	var down := InputEventKey.new(); down.pressed = true; down.keycode = keycode; down.physical_keycode = keycode; down.unicode = unicode
	panel.send_key(down)
	var up := down.duplicate() as InputEventKey; up.pressed = false
	panel.send_key(up)

## The focused LineEdit, or the prompt editor's TextEdit (Settings → Prompts).
func _focused_edit() -> Control:
	var viewport: Viewport = panel.viewport if panel != null and "viewport" in panel else get_viewport()
	var owner: Control = viewport.gui_get_focus_owner() if viewport != null else null
	return owner if owner is LineEdit or owner is TextEdit else null

func _clear() -> void:
	var edit := _focused_edit()
	if edit == null: return
	if edit is TextEdit: (edit as TextEdit).text = ""; (edit as TextEdit).text_changed.emit()
	else: (edit as LineEdit).text = ""; (edit as LineEdit).text_changed.emit("")
	panel.refresh()

## api_key.txt: the first non-empty line, trimmed. Exported desktop builds also look next to
## the executable; Android shares the resource-pack internal/external file locations.
static func file_candidates(android: bool, exported: bool, user_data: String, executable: String,
		external_roots: PackedStringArray = []) -> Array[String]:
	var directories: Array[String] = [user_data]
	if android: directories = APP_FILES.android_directories(user_data, external_roots)
	var candidates: Array[String] = []
	for directory: String in directories:
		for name: String in KEY_NAMES: candidates.append(directory.path_join(name))
	if exported and not android: candidates.append(executable.get_base_dir().path_join("api_key.txt"))
	return candidates

func _load_file(candidates: Array[String] = []) -> void:
	var edit := _focused_edit() as LineEdit
	if edit == null: status.text = "Tap a key field first, then load the file into it."; return
	if candidates.is_empty():
		candidates = file_candidates(OS.has_feature("android"), OS.has_feature("template"), OS.get_user_data_dir(), OS.get_executable_path())
	for path in candidates:
		if not FileAccess.file_exists(path): continue
		var text := FileAccess.get_file_as_string(path)
		for line in text.split("\n"):
			var value := line.strip_edges()
			if value.is_empty() or value.begins_with("#"): continue
			edit.text = value; edit.text_changed.emit(value); edit.caret_column = value.length()
			status.text = "Loaded %d characters from %s" % [value.length(), ProjectSettings.globalize_path(path)]
			key_file_loaded.emit(value); panel.refresh()
			return
	status.text = "No api_key.txt found. Looked in: " + ", ".join(candidates.map(func(p: String): return ProjectSettings.globalize_path(p)))
	panel.refresh()
