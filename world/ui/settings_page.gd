extends VBoxContainer
## The one settings page: tab buttons along the top, a scrolling list of rows, a status
## line and host buttons (Back / Close) at the bottom. Rows come from Settings.TABS, so the
## home screen, the F7 panel, the desktop pause menu and the VR panel all show the same
## settings. Built from plain Buttons (◀ value ▶), which work with the mouse, the keyboard
## focus keys and a VR controller ray on a spatial panel alike.

signal back_requested

## Called after anything visible changes; a SubViewport panel passes its refresh().
var redraw := Callable()
var font_size := 20
var xr := false
var capturing := ""            # action waiting for a key press
var _tabs: Array[Button] = []
var _lists: Array[VBoxContainer] = []
var _values: Dictionary = {}   # key -> value Label or bind Button
var _scroll: ScrollContainer
var _status: Label
var _quality_note: Label
var _tab := 0
var _lighting_controls: Control
var provider: Control
## Settings → Prompts (world/ui/prompt_settings.gd), shown in place of the rows like AI Settings.
var prompts: Control
var feedback_notes: Control
## Settings → Controls map (world/ui/controls_map/controls_map.gd): photos with callout wires.
var controls_map: Control
var footer: HBoxContainer


## `size` is the page's full size; `back_text` names the host's button ("" for none).
func setup(page_size: Vector2, text_size: int, back_text: String, in_xr := false) -> void:
	theme = preload("res://world/ui/readable_text_theme.gd").make()
	font_size = text_size; xr = in_xr
	size = page_size; custom_minimum_size = page_size
	add_theme_constant_override("separation", 8)
	var title := Label.new(); title.text = "Settings"; title.add_theme_font_size_override("font_size", font_size + 10); add_child(title)
	var bar := GridContainer.new(); bar.columns = 4; bar.add_theme_constant_override("separation", 4); add_child(bar)
	_scroll = ScrollContainer.new(); _scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; add_child(_scroll)
	var holder := VBoxContainer.new(); holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL; _scroll.add_child(holder)
	for t in Settings.TABS.size():
		var tab: Array = Settings.TABS[t]
		var button := _button(bar, str(tab[0]), _show_tab.bind(t))
		button.toggle_mode = true; button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.custom_minimum_size.x = 0; button.clip_text = true
		button.add_theme_font_size_override("font_size", font_size - 3)
		_tabs.append(button)
		var list := VBoxContainer.new(); list.add_theme_constant_override("separation", 4)
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL; holder.add_child(list); _lists.append(list)
		for row in tab[1]:
			_row(list, str(row[0]), str(row[1]))
			if str(row[1]) == "video/quality": _quality_note = _note(list, "")
		if str(tab[0]) == "Graphics" and "--debug" in preload("res://world/dev_tools.gd").user_args():
			_lighting_controls = load("res://world/debug/lighting_page.gd").new()
			list.add_child(_lighting_controls)
			_lighting_controls.setup(font_size, _redraw)
		if str(tab[0]) == "VR comfort":
			_note(list, "A comfort vignette is not available yet.")
		if str(tab[0]) == "Controls":
			_note(list, "Other keys (E use, F fly, M map, I briefcase, J inspect, F5–F8) are fixed for now.")
			_note(list, "Wings or Hercules sandals: F takes off/lands. Space flaps; release to glide. S brakes, Shift powers stronger strokes, Ctrl dives. Left/right mouse banks left/right while flying. Wing stamina returns while gliding or resting. Room-scale VR: A takes off/flaps, B lands; pull the move stick back to brake.")
	provider = preload("res://world/ui/provider_settings.gd").new()
	add_child(provider); provider.setup(self, true)
	provider.custom_minimum_size = Vector2.ZERO
	provider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	provider.size_flags_vertical = Control.SIZE_EXPAND_FILL
	prompts = preload("res://world/ui/prompt_settings.gd").new()
	add_child(prompts); prompts.setup(self, true)
	prompts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prompts.size_flags_vertical = Control.SIZE_EXPAND_FILL
	feedback_notes = preload("res://world/ui/feedback_notes.gd").new()
	add_child(feedback_notes); feedback_notes.setup(self, true)
	feedback_notes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	feedback_notes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	controls_map = preload("res://world/ui/controls_map/controls_map.gd").new()
	add_child(controls_map); controls_map.setup(font_size, _redraw)
	controls_map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	controls_map.hide()
	_status = Label.new(); _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", font_size - 4); _status.add_theme_color_override("font_color", Color("acb4c0"))
	add_child(_status)
	footer = HBoxContainer.new(); footer.add_theme_constant_override("separation", 8); add_child(footer)
	if not back_text.is_empty():
		var back := _button(footer, back_text, func(): back_requested.emit()); back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	Settings.changed.connect(_on_changed)
	show_tab("Graphics")


func _row(list: VBoxContainer, label_text: String, key: String) -> void:
	if key.begins_with("action:"):
		var action := key.get_slice(":", 1)
		# The controls map is a page of its own, not a Settings action.
		var run := (func(): show_tab("Controls map")) if action == "controls_map" else (func(): Settings.run_action(action))
		_button(list, label_text, run).size_flags_horizontal = Control.SIZE_EXPAND_FILL
		return
	var line := HBoxContainer.new(); line.add_theme_constant_override("separation", 6); list.add_child(line)
	var label := Label.new(); label.text = Settings.row_label(label_text, key); label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", font_size); line.add_child(label)
	if key.begins_with("bind:"):
		var action := key.get_slice(":", 1)
		var bind := _button(line, "", _capture.bind(action)); bind.custom_minimum_size.x = font_size * 13
		_values[key] = bind
		if xr: bind.disabled = true
		return
	_button(line, "◀", func(): Settings.cycle(key, -1))
	var value := Label.new(); value.custom_minimum_size.x = font_size * 12; value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.add_theme_font_size_override("font_size", font_size); line.add_child(value)
	_values[key] = value
	_button(line, "▶", func(): Settings.cycle(key, 1))


func _note(list: VBoxContainer, text: String) -> Label:
	var label := Label.new(); label.text = text; label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size - 5); label.add_theme_color_override("font_color", Color("acb4c0"))
	list.add_child(label)
	return label


func _button(parent: Node, text: String, callback: Callable) -> Button:
	var b := Button.new(); b.text = text; b.custom_minimum_size = Vector2(font_size * 2.4, font_size * 1.9)
	b.add_theme_font_size_override("font_size", font_size); b.pressed.connect(callback)
	b.focus_entered.connect(_redraw); b.mouse_entered.connect(_redraw); b.mouse_exited.connect(_redraw)
	parent.add_child(b)
	return b


func _show_tab(index: int) -> void:
	_tab = index
	for i in _lists.size():
		_lists[i].visible = i == index
		_tabs[i].set_pressed_no_signal(i == index)
	_scroll.scroll_vertical = 0
	feedback_notes.hide()
	controls_map.hide()
	if current_tab() == "Controls map":
		_scroll.hide(); provider.hide(); prompts.hide(); controls_map.open()
	elif current_tab() == "AI Settings":
		_scroll.hide(); prompts.hide(); provider.open()
	elif current_tab() == "Prompts":
		_scroll.hide(); provider.hide(); prompts.open()
	elif current_tab() == "Saved notes":
		_scroll.hide(); provider.hide(); prompts.hide(); feedback_notes.open()
	else:
		provider.hide(); prompts.hide(); _scroll.show()
	refresh()


func show_tab(title: String) -> void:
	for i in Settings.TABS.size():
		if str(Settings.TABS[i][0]) == title: _show_tab(i)


func current_tab() -> String:
	return str(Settings.TABS[_tab][0])


func refresh() -> void:
	if is_instance_valid(_lighting_controls): _lighting_controls.refresh()
	for key: String in _values:
		var node: Control = _values[key]
		if not is_instance_valid(node): continue
		if key.begins_with("bind:"):
			var action := key.get_slice(":", 1)
			(node as Button).text = "Press a key…" if capturing == action else Settings.key_name(Settings.binding(action))
		else:
			(node as Label).text = Settings.display(key)
	if is_instance_valid(_quality_note): _quality_note.text = _quality_description()
	_status.text = Settings.message
	_redraw()


func _quality_description() -> String:
	var chosen := str(Settings.get_value("video/quality"))
	var base := str(Settings.get_value("video/quality_base")) if chosen == "Custom" else chosen
	var detail := "More scenery and effects, with detailed ponies visible farther away."
	if base in ["Very Low", "Low"]:
		detail = "Simpler scenery and effects; distant ponies use simpler detail sooner."
	elif base == "Medium":
		detail = "Balanced scenery and effects, with simpler detail on distant ponies."
	var heading := "Custom, based on %s: " % base if chosen == "Custom" else "%s: " % chosen
	return heading + detail + " Nearby interactions and pony population stay the same."


## Focusable buttons of the visible tab, top to bottom (title screen / VR stick focus).
func focusables() -> Array:
	var out: Array = []
	out.append_array(_tabs)
	if current_tab() == "AI Settings":
		out.append_array(provider.controls)
		out.append_array(footer.get_children())
		return out
	if current_tab() == "Prompts":
		out.append_array(prompts.controls)
		out.append_array(footer.get_children())
		return out
	if current_tab() == "Saved notes":
		out.append_array(feedback_notes.controls)
		out.append_array(footer.get_children())
		return out
	if current_tab() == "Controls map":
		out.append_array(controls_map.controls)
		out.append_array(footer.get_children())
		return out
	for node in _lists[_tab].find_children("*", "Button", true, false):
		if not (node as Button).disabled: out.append(node)
	out.append_array(footer.get_children())
	return out


func _on_changed(_key: String) -> void:
	if is_inside_tree(): refresh()


func _capture(action: String) -> void:
	capturing = action
	Settings.message = "Press a key for %s (Esc cancels)." % action.replace("_", " ")
	refresh()


func _input(event: InputEvent) -> void:
	if capturing.is_empty() or not is_visible_in_tree(): return
	if not (event is InputEventKey) or not event.pressed or event.echo: return
	var key := event as InputEventKey
	var code: int = key.physical_keycode if key.physical_keycode != 0 else key.keycode
	var action := capturing
	capturing = ""
	if code == KEY_ESCAPE:
		Settings.message = ""
	else:
		Settings.message = "%s → %s" % [action.replace("_", " "), Settings.key_name(code)]
		Settings.bind_key(action, code)
	get_viewport().set_input_as_handled()
	refresh()


func _redraw() -> void:
	if redraw.is_valid(): redraw.call()
