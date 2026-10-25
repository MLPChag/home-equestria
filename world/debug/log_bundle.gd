class_name LogBundle
extends RefCounted
## Support bundle for bug reports. Usable without the class cache:
##   preload("res://world/debug/log_bundle.gd").make_bundle()  -> "user://support/bundle-....zip" or ""
##   preload("res://world/debug/log_bundle.gd").open_logs_folder()
## Contents: version.txt, logs/*, settings.cfg, ai_config.json with every api key redacted,
## the newest save's header (small top-level fields only, never the world state), and the AI
## request traces (ai_trace/*, ai/llm_status.json) when a tester build or --ai-trace wrote them.

const APP_FILES := preload("res://tools/build/packs.gd")
const OUT_DIR := "user://support"
const LOGS_DIR := "user://logs"
const WORLDS_DIR := "user://worlds"
const AI_TRACE_DIR := "user://ai_trace"
const AI_STATUS := "user://ai/llm_status.json"
const REDACT_KEY := "(?i)\"([a-z0-9_]*(api_?key|token|secret|password)[a-z0-9_]*)\"\\s*:\\s*\"(?:[^\"\\\\]|\\\\.)*\""

static func output_directory(android: bool = OS.has_feature("android"), user_data: String = OS.get_user_data_dir(), external_roots: PackedStringArray = []) -> String:
	if android:
		var directories: Array[String] = APP_FILES.android_directories(user_data, external_roots)
		for directory: String in directories:
			if directory == user_data: continue
			var support := directory.path_join("support")
			if DirAccess.make_dir_recursive_absolute(support) == OK: return support
		return "" # Do not silently export to an inaccessible internal folder.
	return OUT_DIR

static func make_bundle(android: bool = OS.has_feature("android"), user_data: String = OS.get_user_data_dir(), external_roots: PackedStringArray = []) -> String:
	var out_dir := output_directory(android, user_data, external_roots)
	if out_dir.is_empty(): return ""
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var stamp := Time.get_datetime_string_from_system(false, true).replace("-", "").replace(":", "").replace(" ", "-")
	var path := out_dir.path_join("bundle-%s.zip" % stamp)
	var zip := ZIPPacker.new()
	if zip.open(path) != OK:
		push_error("[support] cannot write %s" % path); return ""
	var version := str(ProjectSettings.get_setting("application/config/version", "dev"))
	_add(zip, "version.txt", ("Home: Equestria %s\n%s %s\n%s\n" % [version, OS.get_name(), OS.get_version(),
		RenderingServer.get_video_adapter_name()]).to_utf8_buffer())
	for name in _files(LOGS_DIR):
		_add(zip, "logs/" + name, FileAccess.get_file_as_bytes(LOGS_DIR.path_join(name)))
	if FileAccess.file_exists("user://settings.cfg"):
		_add(zip, "settings.cfg", FileAccess.get_file_as_bytes("user://settings.cfg"))
	if FileAccess.file_exists("user://ai_config.json"):
		_add(zip, "ai_config.json", redact(FileAccess.get_file_as_string("user://ai_config.json")).to_utf8_buffer())
	for name in _files(AI_TRACE_DIR):
		_add(zip, "ai_trace/" + name, FileAccess.get_file_as_bytes(AI_TRACE_DIR.path_join(name)))
	if FileAccess.file_exists(AI_STATUS):
		_add(zip, "ai/llm_status.json", FileAccess.get_file_as_bytes(AI_STATUS))
	var save := newest_save()
	if not save.is_empty():
		_add(zip, "save_header.json", JSON.stringify(save_header(save), "\t").to_utf8_buffer())
	zip.close()
	print("[support] bundle written: ", ProjectSettings.globalize_path(path))
	return path

static func opened_directory(android: bool = OS.has_feature("android"), user_data: String = OS.get_user_data_dir(), external_roots: PackedStringArray = []) -> String:
	return output_directory(android, user_data, external_roots) if android else LOGS_DIR

static func open_logs_folder() -> void:
	var directory := opened_directory()
	if directory.is_empty(): return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	OS.shell_open(ProjectSettings.globalize_path(directory))

## Replaces the value of any "..api_key.."/token/secret/password string field with <redacted>.
static func redact(text: String) -> String:
	var regex := RegEx.create_from_string(REDACT_KEY)
	return regex.sub(text, "\"$1\": \"<redacted>\"", true)

static func newest_save() -> String:
	var best := ""; var best_time := -1
	if not DirAccess.dir_exists_absolute(WORLDS_DIR): return ""
	for world in DirAccess.get_directories_at(WORLDS_DIR):
		for folder in [WORLDS_DIR.path_join(world), WORLDS_DIR.path_join(world).path_join("archive")]:
			for name in _files(folder):
				var is_save: bool = name == "autosave.json" or name.begins_with("slot_") or folder.ends_with("archive")
				if not name.ends_with(".json") or not is_save: continue
				var file: String = folder.path_join(name)
				var time := FileAccess.get_modified_time(file)
				if time > best_time: best_time = time; best = file
	return best

static func save_header(path: String) -> Dictionary:
	var header := {"file": path.trim_prefix("user://"), "bytes": FileAccess.get_size(path)}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		header["parse_error"] = true; return header
	var keys: Array = []
	for key: String in (data as Dictionary):
		var value: Variant = data[key]
		keys.append(key)
		if value is Dictionary or value is Array: continue
		header[key] = value
	header["sections"] = keys
	return header

static func _add(zip: ZIPPacker, name: String, bytes: PackedByteArray) -> void:
	if zip.start_file(name) == OK:
		zip.write_file(bytes)
		zip.close_file()

static func _files(dir: String) -> PackedStringArray:
	return DirAccess.get_files_at(dir) if DirAccess.dir_exists_absolute(dir) else PackedStringArray()
