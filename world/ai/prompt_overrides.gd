extends RefCounted
## Player-edited prompts (dev 2026-10-22: "add a settings tab for prompts and make every prompt
## editable"; PonyPonyParadise parity). The game code keeps its own prompt literals; every
## fragment the AI can receive is listed in res://world/ai/prompts/catalog.json
## (tools/ai/build_prompt_catalog.py). An edited fragment is stored in user://prompts/overrides.json
## and swapped in at the request boundary (world/ai/llm_client.gd build_request), so a request
## sends the player's wording wherever the default wording would have gone.
## Fragments with format slots (%s, %d, ...) keep the filled-in values: the default becomes a
## pattern, and the player's text receives the captured values in the same order.
## Personas and system.md stay files: user://mods/prompts/<same file name> (ai_config.prompt_text).
## Nothing is loaded until an override exists, so an unedited game pays one file check per load.
const CATALOG := "res://world/ai/prompts/catalog.json"
const PATH := "user://prompts/overrides.json"
## Where edits live; tests point it at a scratch file.
static var store_path := PATH
const SPEC := "%(?:%|[-+ 0#]*\\d*(?:\\.\\d+)?[sdifxXc])"

static var _loaded := false
static var _overrides: Dictionary = {}       # id -> player text
static var _rules: Array = []                # [default, replacement, RegEx or null], longest first
static var _catalog: Array = []
static var _spec: RegEx

## Every catalog entry: {id, group, label, file, line, placeholders, text}.
static func catalog() -> Array:
	if _catalog.is_empty() and FileAccess.file_exists(CATALOG):
		var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
		if doc is Dictionary and doc.get("prompts") is Array: _catalog = doc.prompts
	return _catalog

static func entry(id: String) -> Dictionary:
	for e: Dictionary in catalog():
		if str(e.id) == id: return e
	return {}

static func overrides() -> Dictionary:
	_load()
	return _overrides

static func text(id: String) -> String:
	_load()
	return str(_overrides[id]) if _overrides.has(id) else str(entry(id).get("text", ""))

static func is_edited(id: String) -> bool:
	return overrides().has(id)

## "" when the player's text can replace the default; otherwise what is wrong with it.
static func problem(id: String, edited: String) -> String:
	var e := entry(id)
	if e.is_empty(): return "Unknown prompt."
	var want := _specs(str(e.text))
	var got := _specs(edited)
	if want == got: return ""
	if want.is_empty(): return "This prompt has no fill-in slots; remove: %s" % " ".join(got)
	return "Keep the fill-in slots %s in this order (found %s)." % [" ".join(want), " ".join(got) if not got.is_empty() else "none"]

## Saves (or, with the default text, clears) one edit. Returns "" or the reason it was refused.
static func save(id: String, edited: String) -> String:
	var why := problem(id, edited)
	if not why.is_empty(): return why
	_load()
	if edited == str(entry(id).text): _overrides.erase(id)
	else: _overrides[id] = edited
	return _write()

static func revert(id: String) -> String:
	_load()
	_overrides.erase(id)
	return _write()

static func revert_all() -> String:
	_load()
	_overrides.clear()
	return _write()

## The request boundary: the system prompt and every message with edits applied.
static func apply(prompt: String) -> String:
	_load()
	if _rules.is_empty() or prompt.is_empty(): return prompt
	for rule: Array in _rules:
		if rule[2] == null:
			prompt = prompt.replace(str(rule[0]), str(rule[1]))
		else:
			prompt = _apply_pattern(prompt, rule[2], str(rule[1]))
	return prompt

static func apply_messages(messages: Array) -> Array:
	_load()
	if _rules.is_empty(): return messages
	var out: Array = []
	for message: Variant in messages:
		if message is Dictionary and (message as Dictionary).get("content") is String:
			var copy: Dictionary = (message as Dictionary).duplicate()
			copy.content = apply(str(copy.content))
			out.append(copy)
		else:
			out.append(message)
	return out

## Forget the loaded state (tests; a save already refreshes it).
static func reload() -> void:
	_loaded = false
	_overrides.clear(); _rules.clear()

static func _load() -> void:
	if _loaded: return
	_loaded = true
	_overrides.clear(); _rules.clear()
	if not FileAccess.file_exists(store_path): return
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(store_path))
	if not doc is Dictionary: return
	for id: Variant in doc:
		if doc[id] is String and not entry(str(id)).is_empty(): _overrides[str(id)] = doc[id]
	_build_rules()

static func _build_rules() -> void:
	_rules.clear()
	for id: String in _overrides:
		var original := str(entry(id).text)
		if original.is_empty() or problem(id, str(_overrides[id])) != "": continue
		_rules.append([original, str(_overrides[id]), _pattern(original) if not _specs(original).is_empty() else null])
	_rules.sort_custom(func(a: Array, b: Array) -> bool: return str(a[0]).length() > str(b[0]).length())

static func _write() -> String:
	DirAccess.make_dir_recursive_absolute(store_path.get_base_dir())
	var file := FileAccess.open(store_path, FileAccess.WRITE)
	if file == null: return "Could not save prompt edits (%s)." % error_string(FileAccess.get_open_error())
	file.store_string(JSON.stringify(_overrides, "\t"))
	file.close()
	_build_rules()
	return ""

static func _spec_regex() -> RegEx:
	if _spec == null:
		_spec = RegEx.new(); _spec.compile(SPEC)
	return _spec

## Format slots in order, without the literal %%.
static func _specs(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for m in _spec_regex().search_all(text):
		if m.get_string() != "%%": out.append(m.get_string())
	return out

## The default with every slot as a capture group (a trailing slot takes the rest of its line).
static func _pattern(original: String) -> RegEx:
	var source := ""
	var at := 0
	var matches := _spec_regex().search_all(original)
	for i in matches.size():
		var m: RegExMatch = matches[i]
		source += _escape(original.substr(at, m.get_start() - at))
		if m.get_string() == "%%": source += "%"
		else: source += "([^\\n]*)" if m.get_end() == original.length() else "([\\s\\S]*?)"
		at = m.get_end()
	source += _escape(original.substr(at))
	var regex := RegEx.new()
	return regex if regex.compile(source) == OK else null

static func _escape(text: String) -> String:
	var out := ""
	for c in text:
		out += ("\\" + c) if c in "\\^$.|?*+()[]{}" else c
	return out

static func _apply_pattern(prompt: String, regex: RegEx, replacement: String) -> String:
	var out := ""
	var at := 0
	for m in regex.search_all(prompt):
		out += prompt.substr(at, m.get_start() - at)
		var values: Array = []
		for g in range(1, m.get_group_count() + 1): values.append(m.get_string(g))
		out += _fill(replacement, values)
		at = m.get_end()
	return out + prompt.substr(at)

## The player's text with captured values placed into its slots in order.
static func _fill(text: String, values: Array) -> String:
	var out := ""
	var at := 0
	var index := 0
	for m in _spec_regex().search_all(text):
		out += text.substr(at, m.get_start() - at)
		if m.get_string() == "%%": out += "%"
		else:
			out += str(values[index]) if index < values.size() else ""
			index += 1
		at = m.get_end()
	return out + text.substr(at)
