extends RefCounted
## How every save file touches the disk (docs/ALPHA_SAVES.md). Writes go to `<file>.tmp`,
## are flushed, the current file is copied to `<file>.previous` (only when it still parses,
## so a damaged file never replaces the last good backup), then the tmp is renamed over it.
## Reads accept the file, or fall back to `.previous`, or rename a damaged file to
## `<file>.corrupt-<time>` so it is kept but no longer in the way.

## check() verdict for a file made by a newer build: it is left exactly as it is.
const NEWER := "newer"


static func stamp() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d-%02d%02d%02d" % [t.year, t.month, t.day, t.hour, t.minute, t.second]


## Parsed JSON, or null when the file is missing, too large or not JSON.
static func parse(path: String, max_bytes := 0) -> Variant:
	if not FileAccess.file_exists(path): return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or (max_bytes > 0 and file.get_length() > max_bytes): return null
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK: return null
	return parser.data


static func write(path: String, doc: Variant, max_bytes := 0) -> Error:
	var absolute := ProjectSettings.globalize_path(path)
	var status := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if status != OK: return status
	var text := JSON.stringify(doc, "\t", true, true)
	var expected_bytes := text.to_utf8_buffer().size()
	if max_bytes > 0 and expected_bytes > max_bytes: return ERR_OUT_OF_MEMORY
	var file := FileAccess.open(absolute + ".tmp", FileAccess.WRITE)
	if file == null: return FileAccess.get_open_error()
	file.store_string(text); file.flush()
	var result := file.get_error(); file.close()
	if result != OK: return result
	result = _check_written_size(absolute + ".tmp", expected_bytes)
	if result != OK: return result
	if FileAccess.file_exists(absolute) and parse(absolute) != null:
		result = _copy_atomic(absolute, absolute + ".previous")
		if result != OK: return result
	return DirAccess.rename_absolute(absolute + ".tmp", absolute)


## Never truncate the destination before a complete copy has been flushed.
## Replacement uses Godot rename semantics; it is not atomic on every platform.
## FileAccess reports expected storage failures without DirAccess.copy's engine errors.
static func _copy_atomic(source: String, target: String) -> Error:
	var input := FileAccess.open(source, FileAccess.READ)
	if input == null: return FileAccess.get_open_error()
	var expected_bytes := input.get_length()
	var output := FileAccess.open(target + ".tmp", FileAccess.WRITE)
	if output == null: return FileAccess.get_open_error()
	var result := OK
	while input.get_position() < expected_bytes:
		var bytes := input.get_buffer(mini(65536, expected_bytes - input.get_position()))
		result = input.get_error()
		if result != OK: break
		output.store_buffer(bytes)
		result = output.get_error()
		if result != OK: break
	output.flush()
	if result == OK: result = output.get_error()
	input.close(); output.close()
	if result != OK: return result
	result = _check_written_size(target + ".tmp", expected_bytes)
	if result != OK: return result
	return DirAccess.rename_absolute(target + ".tmp", target)


## Godot's cached write error can miss a failure that occurs only in flush().
## Reopen after close to check the real file length before publishing it.
static func _check_written_size(path: String, expected_bytes: int) -> Error:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return FileAccess.get_open_error()
	return OK if file.get_length() == expected_bytes else ERR_FILE_CANT_WRITE


## Move a damaged file out of the way, keeping it. Returns the new path ("" on failure).
static func quarantine(path: String) -> String:
	var absolute := ProjectSettings.globalize_path(path)
	# Several recoveries can happen in one second. Never replace earlier evidence,
	# even if a process ID and monotonic timestamp recur after a restart.
	var base := absolute + ".corrupt-" + stamp() + "-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var target := base
	var suffix := 0
	while FileAccess.file_exists(target):
		suffix += 1
		target = base + "-%d" % suffix
	return target if DirAccess.rename_absolute(absolute, target) == OK else ""


## check(doc: Variant) -> String: "" when usable, NEWER when made by a newer build, else why not.
## Returns {doc, status, message}; status is ok, missing, recovered (loaded from
## .previous; message explains failed disk repair), newer (untouched) or lost.
static func read_checked(path: String, max_bytes: int, check: Callable) -> Dictionary:
	var has_main := FileAccess.file_exists(path)
	if not has_main and not FileAccess.file_exists(path + ".previous"):
		return {"doc": null, "status": "missing", "message": ""}
	var main: Variant = parse(path, max_bytes)
	var verdict: String = check.call(main) if main != null else "unreadable"
	if verdict == "": return {"doc": main, "status": "ok", "message": ""}
	var name := path.get_file()
	if verdict == NEWER:
		return {"doc": null, "status": "newer", "message": "%s was made by a newer version of the game; it is kept unchanged." % name}
	var backup: Variant = parse(path + ".previous", max_bytes)
	var backup_verdict: String = check.call(backup) if backup != null else "unreadable"
	if backup_verdict == NEWER:
		# Protect both files. Quarantining the primary would let a later open miss
		# the newer backup and create empty state that eventually overwrites it.
		return {"doc": null, "status": "newer", "message": "%s's previous copy was made by a newer version of the game; existing files are kept unchanged." % name}
	var kept_path := quarantine(path) if has_main else ""
	var kept := kept_path.get_file() if not kept_path.is_empty() else ""
	if backup_verdict == "":
		# If quarantine failed, the original evidence must remain untouched.
		var repair: Error = ERR_CANT_CREATE if has_main and kept_path.is_empty() else _copy_atomic(ProjectSettings.globalize_path(path + ".previous"), ProjectSettings.globalize_path(path))
		var message := "%s was damaged (%s); loaded its previous copy. Damaged file kept as %s." % [name, verdict, kept if not kept.is_empty() else name] if has_main else "%s was missing; loaded its previous copy." % name
		if repair != OK: message += " Could not restore the current file on disk; its previous copy is kept unchanged."
		return {"doc": backup, "status": "recovered", "message": message}
	return {"doc": null, "status": "lost", "message": "%s could not be used (%s); kept as %s." % [name, verdict, kept if kept != "" else name]}
