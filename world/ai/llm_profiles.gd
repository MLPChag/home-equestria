extends RefCounted
## Player-local named dialogue configurations. Never logged or included in world saves.
const CONFIG := preload("res://world/ai/ai_config.gd")
const DEFAULT_PATH := "user://llm_profiles.json"
var path := DEFAULT_PATH
var error := ""
var profiles: Dictionary = {}
var _readable := true

func open(file_path := DEFAULT_PATH) -> bool:
	path = file_path; profiles = {}; error = ""; _readable = true
	if not FileAccess.file_exists(path): return true
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK: return _bad_file()
	var value: Variant = parser.data
	if not value is Dictionary or value.get("version") != 1 or not value.get("profiles") is Dictionary:
		return _bad_file()
	for name: Variant in value.profiles:
		if not name is String or not valid_name(name) or not value.profiles[name] is Dictionary:
			return _bad_file()
		if not CONFIG.validate_llm(value.profiles[name]).is_empty(): return _bad_file()
	profiles = value.profiles.duplicate(true)
	return true

func _bad_file() -> bool:
	_readable = false; error = "Saved LLM presets could not be read. The original file has been preserved."
	return false

static func valid_name(value: String) -> bool:
	if value.strip_edges().is_empty() or value.length() > 64 or value != value.strip_edges(): return false
	for i in value.length():
		if value.unicode_at(i) < 32 or value.unicode_at(i) == 127: return false
	return true

func names() -> Array:
	var result := profiles.keys(); result.sort()
	return result

func get_profile(name: String) -> Dictionary:
	return profiles.get(name, {}).duplicate(true)

func save_profile(name: String, connection: Dictionary) -> bool:
	name = name.strip_edges()
	if not valid_name(name): error = "Name the preset using 1–64 characters."; return false
	error = CONFIG.validate_llm(connection)
	if not error.is_empty(): return false
	var llm: Dictionary = CONFIG.DEFAULTS.llm.duplicate(true)
	for key in llm:
		if connection.has(key): llm[key] = connection[key]
	for key in ["provider", "base_url", "model", "api_key"]: llm[key] = str(llm[key]).strip_edges()
	llm.generation_overrides = CONFIG.OPTIONS.selected(connection)
	llm.base_url = str(llm.base_url).rstrip("/")
	var next := profiles.duplicate(true); next[name] = llm
	return _write(next)

func delete_profile(name: String) -> bool:
	if not profiles.has(name): error = "Select a saved preset first."; return false
	var next := profiles.duplicate(true); next.erase(name)
	return _write(next)

func _write(next: Dictionary) -> bool:
	if not _readable: return _bad_file()
	error = ""
	var absolute := ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(absolute.get_base_dir()) != OK:
		error = "Could not create the LLM preset folder."; return false
	var file := FileAccess.open(absolute + ".tmp", FileAccess.WRITE)
	if file == null: error = "Could not save LLM presets."; return false
	if OS.get_name() != "Windows":
		if FileAccess.set_unix_permissions(absolute + ".tmp", FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER) != OK:
			file.close(); error = "Could not protect the LLM preset file."; return false
	file.store_string(JSON.stringify({"version":1,"profiles":next}, "\t")); file.flush()
	var result := file.get_error(); file.close()
	if result != OK or DirAccess.rename_absolute(absolute + ".tmp", absolute) != OK:
		error = "Could not finish saving LLM presets."; return false
	profiles = next
	return true
