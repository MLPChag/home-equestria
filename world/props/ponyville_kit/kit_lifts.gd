extends RefCounted
## A kit placement's height with the ground the building pads raised under it (tools/terrain/
## pad_lifts.gd writes pad_lifts.json). Dressing, state visuals and activity spots all use this.
const LIFTS := "res://world/towns/ponyville/pad_lifts.json"
static var _rows: Dictionary = {}
static var _loaded := false

static func y(row: Dictionary) -> float:
	if not _loaded:
		_loaded = true
		if FileAccess.file_exists(LIFTS):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LIFTS))
			if parsed is Dictionary: _rows = (parsed as Dictionary).get("kit", {})
	return float(row.y) + float(_rows.get(str(row.get("id", "")), 0.0))
