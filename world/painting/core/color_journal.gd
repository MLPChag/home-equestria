extends RefCounted
## The colour discovery journal (docs/DESIGN.md 2.16): one entry per discovered colour name, with
## the named hex, the brush hex that discovered it and the unix time. JSON in user://journal.json
## (injectable path; "" keeps it in memory only). add() and clear() save at once when a path is
## set. Pure logic, no Node dependency.
##
## File format: {"version": 1, "entries": [{"name": String, "named_hex": "#RRGGBB",
## "brush_hex": "#RRGGBB", "time": int}, ...]} in the order of discovery.

const PaintingIO := preload("res://world/painting/core/painting_io.gd")

const PATH := "user://journal.json"
const VERSION := 1

## Emitted after add() adds an entry, after clear() and after load_file().
signal changed

var _path: String
var _entries: Array[Dictionary] = []   # discovery order
var _index: Dictionary = {}            # name -> position in _entries


func _init(path: String = PATH) -> void:
	_path = path


## The JSON file path ("" = memory only).
func get_file_path() -> String:
	return _path


## Changes the file path. The entries stay; call load_file() to read the new file.
func set_file_path(path: String) -> void:
	_path = path


## Replaces the entries with the file content. A missing or broken file gives an empty journal;
## broken entries are skipped. A file that is not a journal (bad JSON, no "entries" list) is moved
## aside to journal.broken-<unix time>.json first (PaintingPaintingIO.move_aside_broken), so the next
## save does not overwrite it.
func load_file() -> void:
	_entries.clear()
	_index.clear()
	if _path != "" and FileAccess.file_exists(_path):
		var json := JSON.new()
		var data: Variant = null
		if json.parse(FileAccess.get_file_as_string(_path)) == OK:
			data = json.data
		if data is Dictionary and (data as Dictionary).get("entries") is Array:
			for item: Variant in (data as Dictionary)["entries"]:
				var e: Dictionary = _valid_entry(item)
				if not e.is_empty() and not _index.has(e["name"]):
					_index[e["name"]] = _entries.size()
					_entries.append(e)
		else:
			push_warning("PaintingColorJournal: %s is not a journal; starting empty" % _path)
			PaintingIO.move_aside_broken(_path)
	changed.emit()


## Writes the JSON atomically (<file>.tmp, then rename). OK without a path.
func save_file() -> Error:
	if _path == "":
		return OK
	var err: Error = DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(_path).get_base_dir())
	if err != OK:
		return err
	var doc: Dictionary = {"version": VERSION, "entries": _entries}
	return PaintingIO.write_atomic(_path, JSON.stringify(doc, "\t").to_utf8_buffer())


func has(name: String) -> bool:
	return _index.has(name)


## Adds a discovery. [param time] is the unix time in seconds (-1 = now). Returns false (and
## changes nothing) when the name is empty or already in the journal. Saves when a path is set.
func add(name: String, named_hex: String, brush_hex: String, time: int = -1) -> bool:
	if name == "" or _index.has(name):
		return false
	var e: Dictionary = {
		"name": name,
		"named_hex": _norm_hex(named_hex),
		"brush_hex": _norm_hex(brush_hex),
		"time": time if time >= 0 else int(Time.get_unix_time_from_system()),
	}
	_index[name] = _entries.size()
	_entries.append(e)
	save_file()
	changed.emit()
	return true


## A copy of the entry for [param name], or an empty Dictionary.
func get_entry(name: String) -> Dictionary:
	return _entries[int(_index[name])].duplicate() if _index.has(name) else {}


## Copies of all entries, newest first (on equal times the later discovery first).
func entries() -> Array[Dictionary]:
	var order: Array[int] = []
	for i: int in _entries.size():
		order.append(i)
	order.sort_custom(func(x: int, y: int) -> bool:
		var tx: int = int(_entries[x]["time"])
		var ty: int = int(_entries[y]["time"])
		return tx > ty or (tx == ty and x > y))
	var out: Array[Dictionary] = []
	for i: int in order:
		out.append(_entries[i].duplicate())
	return out


func count() -> int:
	return _entries.size()


## Forgets every entry. Saves when a path is set.
func clear() -> void:
	_entries.clear()
	_index.clear()
	save_file()
	changed.emit()


# A clean entry from file data, or {} when it is not usable.
static func _valid_entry(item: Variant) -> Dictionary:
	if not (item is Dictionary):
		return {}
	var d: Dictionary = item
	var name: Variant = d.get("name")
	if not (name is String) or String(name) == "":
		return {}
	var t: Variant = d.get("time", 0)
	return {
		"name": String(name),
		"named_hex": _norm_hex(str(d.get("named_hex", ""))),
		"brush_hex": _norm_hex(str(d.get("brush_hex", ""))),
		"time": int(t) if (t is int or t is float) else 0,
	}


# "#RRGGBB" in upper case; "" when the text is not a 6-digit hex colour.
static func _norm_hex(hex: String) -> String:
	var h: String = hex.strip_edges().trim_prefix("#").to_upper()
	return "#" + h if h.length() == 6 and h.is_valid_hex_number() else ""
