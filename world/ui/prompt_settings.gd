extends Control
## Settings → Prompts (dev 2026-10-22: "add a settings tab for prompts and make every prompt
## editable", PonyPonyParadise parity, player builds included). Two kinds of prompt:
## - fragments from res://world/ai/prompts/catalog.json (rules, reply format, memory, events),
##   edited through world/ai/prompt_overrides.gd and applied when a request is sent;
## - whole files: system.md and every pony persona, saved as the existing
##   user://mods/prompts/<file name> override that ai_config.prompt_text already prefers.
## A fragment with fill-in slots (%s, %d) refuses an edit that drops or reorders them.
const OVERRIDES := preload("res://world/ai/prompt_overrides.gd")
const CONFIG := preload("res://world/ai/ai_config.gd")
const PERSONA_DIRS := ["res://world/ai/prompts", "res://world/characters/princesses", "res://world/characters/background/ai"]
const ALL := "All prompts"
const EDITED := "Edited only"
const PERSONAS := "Personas"
const CHARS_PER_TOKEN := 2.6   # measured on the tester capture (docs/AI_TOKENS_PROMPT_2026_10_22.md)
var panel: Node
var controls: Array[Control] = []
var editor: TextEdit
var _search: LineEdit
var _group: OptionButton
var _list: ItemList
var _info: Label
var _status: Label
var _entries: Array = []      # {kind: "fragment"|"persona", id, group, label, path?}
var _shown: Array = []
var _current: Dictionary = {}

func setup(surface: Node, _in_tab := true) -> void:
	panel = surface
	theme = preload("res://world/ui/readable_text_theme.gd").make()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margin := MarginContainer.new(); add_child(margin); margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]: margin.add_theme_constant_override("margin_" + side, 24)
	margin.add_theme_constant_override("margin_top", 12); margin.add_theme_constant_override("margin_bottom", 12)
	var box := VBoxContainer.new(); box.add_theme_constant_override("separation", 8); margin.add_child(box)
	var title := Label.new(); title.text = "Prompts"; title.add_theme_font_size_override("font_size", 28); box.add_child(title)
	var note := Label.new(); note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; note.add_theme_font_size_override("font_size", 17)
	note.text = "Every instruction the ponies receive. Edits apply to the next request and are kept across saves. Longer prompts cost more tokens on every request; Revert restores the shipped text."
	box.add_child(note)
	var filters := HBoxContainer.new(); filters.add_theme_constant_override("separation", 8); box.add_child(filters)
	_search = LineEdit.new(); _search.placeholder_text = "Search prompts"; _search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.custom_minimum_size.y = 44; _search.text_changed.connect(func(_t: String): _fill_list()); filters.add_child(_search)
	_group = OptionButton.new(); _group.custom_minimum_size = Vector2(260, 44); _group.item_selected.connect(func(_i: int): _fill_list())
	filters.add_child(_group)
	_list = ItemList.new(); _list.custom_minimum_size.y = 150; _list.add_theme_font_size_override("font_size", 17)
	_list.item_selected.connect(_pick); box.add_child(_list)
	_info = Label.new(); _info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _info.add_theme_font_size_override("font_size", 16)
	_info.add_theme_color_override("font_color", Color("acb4c0")); box.add_child(_info)
	editor = TextEdit.new(); editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY; editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.custom_minimum_size.y = 160; editor.add_theme_font_size_override("font_size", 17)
	editor.text_changed.connect(_edited); box.add_child(editor)
	var buttons := HBoxContainer.new(); buttons.add_theme_constant_override("separation", 8); box.add_child(buttons)
	for entry in [["Save prompt", _save], ["Revert to default", _revert], ["Revert all edits", _revert_all]]:
		var b := Button.new(); b.text = entry[0]; b.custom_minimum_size.y = 44; b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(entry[1]); buttons.add_child(b); controls.append(b)
	_status = Label.new(); _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _status.add_theme_font_size_override("font_size", 17); box.add_child(_status)
	var buttons_only := controls.duplicate()
	controls.clear()
	controls.append_array([_search, _group, _list, editor]); controls.append_array(buttons_only)
	hide()

func open() -> void:
	_load_entries()
	var groups := [ALL, EDITED, PERSONAS]
	for e: Dictionary in _entries:
		if not str(e.group) in groups: groups.append(str(e.group))
	var keep := _group.get_item_text(_group.selected) if _group.item_count > 0 else ALL
	_group.clear()
	for g: String in groups: _group.add_item(g)
	_group.select(maxi(0, groups.find(keep)))
	_fill_list()
	show(); _refresh()

func _load_entries() -> void:
	_entries.clear()
	for f: Dictionary in OVERRIDES.catalog():
		_entries.append({"kind": "fragment", "id": str(f.id), "group": str(f.group), "label": str(f.label).capitalize() if str(f.label) == str(f.label).to_upper() else str(f.label),
			"where": str(f.file), "slots": int(f.placeholders)})
	for dir: String in PERSONA_DIRS:
		for file: String in DirAccess.get_files_at(dir):
			if file.get_extension() != "md": continue
			var path := dir.path_join(file)
			_entries.append({"kind": "persona", "id": path, "group": PERSONAS, "where": path,
				"label": "System prompt (all ponies)" if file == "system.md" else file.get_basename().capitalize()})

func _fill_list() -> void:
	var group := _group.get_item_text(_group.selected) if _group.item_count > 0 else ALL
	var needle := _search.text.strip_edges().to_lower()
	_list.clear(); _shown.clear()
	for e: Dictionary in _entries:
		var edited := _is_edited(e)
		if group == EDITED and not edited: continue
		if group not in [ALL, EDITED] and str(e.group) != group: continue
		if not needle.is_empty() and not (needle in str(e.label).to_lower() or needle in _default_text(e).to_lower()): continue
		_shown.append(e)
		_list.add_item(("● " if edited else "") + str(e.label) + ("" if group != ALL else "  · " + str(e.group)))
	if not _shown.is_empty() and (_current.is_empty() or _shown.find(_current) < 0): _list.select(0); _pick(0)
	elif _shown.find(_current) >= 0: _list.select(_shown.find(_current))
	_refresh()

func _pick(index: int) -> void:
	if index < 0 or index >= _shown.size(): return
	_current = _shown[index]
	editor.text = _current_text(_current)
	editor.clear_undo_history()
	_status.text = ""
	_describe()

func _describe() -> void:
	if _current.is_empty(): _info.text = ""; return
	var tokens := int(ceil(editor.text.length() / CHARS_PER_TOKEN))
	var bits := ["~%d tokens" % tokens, "edited" if _is_edited(_current) else "default", str(_current.where)]
	if int(_current.get("slots", 0)) > 0: bits.append("keep its %d fill-in slot(s) like %%s" % int(_current.slots))
	_info.text = " · ".join(bits)
	_refresh()

func _edited() -> void:
	_describe()

func _save() -> void:
	if _current.is_empty(): return
	var why := ""
	if str(_current.kind) == "fragment":
		why = OVERRIDES.save(str(_current.id), editor.text)
	else:
		why = _write_persona(str(_current.id), editor.text)
		_reload_director()
	_status.text = why if not why.is_empty() else "Saved. The next request uses it."
	_fill_list_keep()

func _revert() -> void:
	if _current.is_empty(): return
	if str(_current.kind) == "fragment": OVERRIDES.revert(str(_current.id))
	else:
		var path := _persona_override(str(_current.id))
		if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		_reload_director()
	editor.text = _current_text(_current)
	_status.text = "Back to the shipped text."
	_fill_list_keep()

func _revert_all() -> void:
	OVERRIDES.revert_all()
	for e: Dictionary in _entries:
		if str(e.kind) == "persona" and _is_edited(e):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(_persona_override(str(e.id))))
	_reload_director()
	if not _current.is_empty(): editor.text = _current_text(_current)
	_status.text = "Every prompt is back to the shipped text."
	_fill_list_keep()

func _fill_list_keep() -> void:
	var keep := _current
	_fill_list()
	var index := _shown.find(keep)
	if index >= 0: _list.select(index)
	_describe()

func _is_edited(e: Dictionary) -> bool:
	if str(e.kind) == "fragment": return OVERRIDES.is_edited(str(e.id))
	return FileAccess.file_exists(_persona_override(str(e.id)))

func _default_text(e: Dictionary) -> String:
	if str(e.kind) == "fragment": return str(OVERRIDES.entry(str(e.id)).get("text", ""))
	return FileAccess.get_file_as_string(str(e.id)) if FileAccess.file_exists(str(e.id)) else ""

func _current_text(e: Dictionary) -> String:
	if str(e.kind) == "fragment": return OVERRIDES.text(str(e.id))
	return CONFIG.prompt_text(str(e.id))

func _persona_override(path: String) -> String:
	return CONFIG.MOD_PROMPTS.path_join(path.get_file())

func _write_persona(path: String, text: String) -> String:
	if text == _default_text({"kind": "persona", "id": path}):
		var existing := _persona_override(path)
		if FileAccess.file_exists(existing): DirAccess.remove_absolute(ProjectSettings.globalize_path(existing))
		return ""
	DirAccess.make_dir_recursive_absolute(CONFIG.MOD_PROMPTS)
	var file := FileAccess.open(_persona_override(path), FileAccess.WRITE)
	if file == null: return "Could not save (%s)." % error_string(FileAccess.get_open_error())
	file.store_string(text); file.close()
	return ""

## Persona and system files are read when the director (re)loads its configuration.
func _reload_director() -> void:
	if not is_inside_tree(): return
	var director: Node = get_tree().get_first_node_in_group("conversation_director")
	if director != null and director.has_method("reload_config"): director.reload_config()

func _refresh() -> void:
	if panel != null and panel.has_method("refresh"): panel.refresh()
