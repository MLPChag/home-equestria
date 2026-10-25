extends Control
## Shared desktop/XR Settings page for lasting notes and review-only older feedback.
const STORE := preload("res://world/ai/dialogue_feedback.gd")
const CLASSIFIER := preload("res://world/ai/feedback_classifier.gd")
var controls: Array[Control] = []
var panel: Node
var store: RefCounted
var _list: ItemList
var _detail: TextEdit
var _scope: OptionButton
var _keep: Button
var _delete: Button
var _status: Label
var _shown: Array[Dictionary] = []
var _selected := ""

func setup(surface: Node, _in_tab := true) -> void:
	panel = surface
	theme = preload("res://world/ui/readable_text_theme.gd").make()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margin := MarginContainer.new(); add_child(margin); margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + side, 12)
	var box := VBoxContainer.new(); box.add_theme_constant_override("separation", 8); margin.add_child(box)
	var title := Label.new(); title.text = "Saved notes"; title.add_theme_font_size_override("font_size", 26); box.add_child(title)
	var note := Label.new(); note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; note.add_theme_font_size_override("font_size", 16)
	note.text = "Style notes last until you delete them. Pretend actions belong to the current scene. Older or uncertain feedback stays here for review and is never sent to ponies unless you keep it as a style note."
	box.add_child(note)
	_list = ItemList.new(); _list.custom_minimum_size.y = 120; _list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.add_theme_color_override("font_color", Color("eef2f5"))
	_list.add_theme_font_size_override("font_size", 17); _list.item_selected.connect(_pick); box.add_child(_list)
	_detail = TextEdit.new(); _detail.editable = false; _detail.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_detail.add_theme_color_override("font_readonly_color", Color("eef2f5"))
	_detail.custom_minimum_size.y = 100; _detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail.add_theme_font_size_override("font_size", 17); box.add_child(_detail)
	var scope_row := HBoxContainer.new(); box.add_child(scope_row)
	var label := Label.new(); label.text = "Applies to"; label.add_theme_font_size_override("font_size", 17); scope_row.add_child(label)
	_scope = OptionButton.new(); _scope.size_flags_horizontal = Control.SIZE_EXPAND_FILL; _scope.custom_minimum_size.y = 42
	_scope.add_theme_font_size_override("font_size", 17); scope_row.add_child(_scope)
	_scope.add_item("Choose a pony or all ponies…"); _scope.set_item_metadata(0, "")
	_scope.add_item("All ponies"); _scope.set_item_metadata(1, "*")
	_scope.item_selected.connect(func(_i: int) -> void: _update_buttons(); _redraw())
	var buttons := HBoxContainer.new(); buttons.add_theme_constant_override("separation", 8); box.add_child(buttons)
	_keep = Button.new(); _keep.text = "Keep as style note"; _keep.pressed.connect(_keep_selected); buttons.add_child(_keep)
	_delete = Button.new(); _delete.text = "Delete note"; _delete.pressed.connect(_delete_selected); buttons.add_child(_delete)
	for button: Button in [_keep, _delete]:
		button.custom_minimum_size.y = 44; button.size_flags_horizontal = Control.SIZE_EXPAND_FILL; button.add_theme_font_size_override("font_size", 17)
	_status = Label.new(); _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _status.add_theme_font_size_override("font_size", 16); box.add_child(_status)
	controls.append_array([_list, _detail, _scope, _keep, _delete])
	for control: Control in controls:
		control.focus_entered.connect(_redraw); control.mouse_entered.connect(_redraw); control.mouse_exited.connect(_redraw)
	hide()

func open() -> void:
	var director := get_tree().get_first_node_in_group("conversation_director")
	var current: RefCounted = director.feedback if director != null else null
	if current == null:
		current = STORE.new()
		var context := OS.get_environment("EQ_CONTEXT_ROOT")
		current.open(context.path_join("dialogue_feedback.cfg") if not context.is_empty() else "user://dialogue_feedback.cfg")
	use_store(current)
	show(); _redraw()

## Also used by the isolated UI fixture: no live save/provider is needed.
func use_store(current: RefCounted) -> void:
	_load_scopes()
	if store != null and store.changed.is_connected(_reload): store.changed.disconnect(_reload)
	store = current
	store.changed.connect(_reload)
	_status.text = "" if store.load_error() == OK else "Saved notes could not be read. Nothing has been overwritten."
	_reload()

func _load_scopes() -> void:
	if _scope.item_count > 2: return
	var profiles := CLASSIFIER.profiles()
	var ids := profiles.keys(); ids.sort_custom(func(a: String, b: String) -> bool: return str(profiles[a].get("name", a)).naturalnocasecmp_to(str(profiles[b].get("name", b))) < 0)
	for id: String in ids:
		_scope.add_item(str(profiles[id].get("name", id))); _scope.set_item_metadata(_scope.item_count - 1, id)

func _reload() -> void:
	_shown = store.entries()
	var selected := _list.get_selected_items()
	var previous_index := int(selected[0]) if not selected.is_empty() else 0
	_list.clear()
	var keep := -1
	for i in _shown.size():
		var row: Dictionary = _shown[i]
		var scope := "all ponies" if row.scope == "*" else str(row.scope).capitalize()
		var prefix := "Style · " + scope if row.kind == "style" else "Review"
		_list.add_item(prefix + " — " + str(row.text).replace("\n", " ").left(95))
		if str(row.id) == _selected: keep = i
	if not _shown.is_empty():
		if keep < 0: keep = clampi(previous_index, 0, _shown.size() - 1)
		_list.select(keep); _pick(keep)
	else:
		_selected = ""; _detail.text = "No saved notes."; _scope.select(0); _update_buttons()
	_redraw()

func _pick(index: int) -> void:
	if index < 0 or index >= _shown.size(): return
	var row: Dictionary = _shown[index]
	_selected = str(row.id)
	_detail.text = str(row.text)
	_status.text = str(row.reason)
	var scope := str(row.scope) if row.kind == "style" else ""
	# An explicit pony name offers a safe suggestion; legacy text is still inactive.
	if scope.is_empty():
		var context := CLASSIFIER.context_for(str(row.text), "")
		if context.mentioned.size() == 1: scope = str(context.mentioned[0])
	_scope.select(0)
	for i in _scope.item_count:
		if str(_scope.get_item_metadata(i)) == scope: _scope.select(i); break
	_keep.text = "Save scope" if row.kind == "style" else "Keep as style note"
	_update_buttons(); _redraw()

func _update_buttons() -> void:
	var writable: bool = store != null and store.load_error() == OK and not _selected.is_empty()
	_delete.disabled = not writable
	_keep.disabled = not writable or str(_scope.get_item_metadata(_scope.selected)).is_empty()

func _keep_selected() -> void:
	var result: Error = store.keep_as_style(_selected, str(_scope.get_item_metadata(_scope.selected)))
	_status.text = "Style note saved." if result == OK else "Could not save this note (%s)." % error_string(result)
	_redraw()

func _delete_selected() -> void:
	var result: Error = store.remove(_selected)
	_status.text = "Note deleted." if result == OK else "Could not delete this note (%s)." % error_string(result)
	_redraw()

func _redraw() -> void:
	if is_instance_valid(panel) and panel.has_method("_redraw"): panel._redraw()
