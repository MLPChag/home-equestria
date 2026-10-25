extends RefCounted
## Measured local coordinates from the authored kit, recorded through Blender MCP.
const PATH := "res://world/props/ponyville_kit/activity/fit.json"
static var _loaded := false
static var _data: Dictionary = {}

static func get_kind(kind: String) -> Dictionary:
	if not _loaded:
		_loaded = true
		if FileAccess.file_exists(PATH):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
			if parsed is Dictionary: _data = parsed
	var record: Dictionary = _data.get(kind, {})
	return record.duplicate(true) if bool(record.get("measured", false)) else {}

static func point(value: Variant) -> Vector3:
	if not value is Array or value.size() != 3: return Vector3.INF
	for component: Variant in value:
		if not (component is float or component is int) or not is_finite(float(component)): return Vector3.INF
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

static func transform(value: Variant) -> Transform3D:
	if not value is Dictionary: return Transform3D(Basis.IDENTITY, Vector3.INF)
	var origin := point(value.get("origin"))
	var rotation := point(value.get("rotation_degrees", [0, 0, 0]))
	if not origin.is_finite() or not rotation.is_finite(): return Transform3D(Basis.IDENTITY, Vector3.INF)
	return Transform3D(Basis.from_euler(rotation * PI / 180.0), origin)

static func box(value: Variant) -> AABB:
	if not value is Dictionary: return AABB()
	var origin := point(value.get("position"))
	var size := point(value.get("size"))
	if not origin.is_finite() or not size.is_finite() or size.x <= 0 or size.y <= 0 or size.z <= 0: return AABB()
	return AABB(origin, size)
