extends RefCounted
## Explicit tester capture only. No headers, configuration files or binary audio.
## Each event is closed immediately so completed writes survive a game crash.

static func folder() -> String:
	var target := OS.get_environment("EQ_AI_CAPTURE_DIR")
	if not target.is_empty(): return target
	var dev := preload("res://world/dev_tools.gd")
	return "user://ai_trace" if "--ai-trace-full" in dev.user_args() or dev.tester_capture() else ""


static func record(source: String, event: String, details: Dictionary, secret := "") -> void:
	var target := folder()
	if target.is_empty(): return
	var row := {"time": Time.get_datetime_string_from_system(true), "ticks_usec": Time.get_ticks_usec(),
		"pid": OS.get_process_id(), "source": source, "event": event, "details": details}
	var line := JSON.stringify(row)
	# Providers can echo credentials in errors; redact the configured key even there.
	if not secret.is_empty():
		var escaped := JSON.stringify(secret)
		line = line.replace(escaped.substr(1, escaped.length() - 2), "<REDACTED>")
	if DirAccess.make_dir_recursive_absolute(target) != OK:
		push_warning("[ai-capture] Cannot create capture folder")
		return
	var path := target.path_join("ai-events.jsonl")
	var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file == null:
		push_warning("[ai-capture] Cannot write capture events")
		return
	file.seek_end()
	file.store_line(line)
	file.close()
