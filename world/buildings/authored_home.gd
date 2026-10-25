extends "res://world/buildings/house_interior.gd"
## Common house contract for authored interiors. Scene exports and genuine home-specific
## routing/bed behavior stay on the adapters; their measurements come from homes.json.
const HOME_DATA := "res://world/buildings/homes.json"
static var _homes: Dictionary = {}
var home_kind := ""

func _home_data() -> Dictionary:
	if _homes.is_empty():
		_homes = JSON.parse_string(FileAccess.get_file_as_string(HOME_DATA))
	return _homes.get(home_kind, {})

func _ready() -> void:
	var data := _home_data()
	if bool(data.get("standard_setup", false)):
		super._ready()
		return
	add_to_group("house_interiors")
	_bed_settled = true
	_floor_fitted = true
	_furnished = true
	furnish_done = true
	if data.has("furnish"): furnish = bool(data.furnish)
	if data.has("reserved_for"): set_meta("reserved_for", data.reserved_for)
	if data.has("ceiling_y"): _ceiling_y = float(data.ceiling_y)

func place_id() -> String:
	var data := _home_data()
	return str(data.place_id) if data.has("place_id") else super.place_id()

func label() -> String:
	var data := _home_data()
	return str(data.label) if data.has("label") else super.label()

func center() -> Vector3:
	var data := _home_data()
	if not data.has("center"): return super.center()
	var point := _point(data.center)
	if data.has("center_scale"): point /= float(data.center_scale)
	return to_global(point)

func slots() -> Array[Vector3]:
	var data := _home_data()
	if not data.has("slots"): return super.slots()
	var result: Array[Vector3] = []
	for point: Array in data.slots: result.append(to_global(_point(point)))
	return result

func _reach_squared() -> float:
	var data := _home_data()
	if data.has("reach_squared"): return float(data.reach_squared)
	return super._reach_squared()

func ensure_bed(id: String = "") -> Node3D:
	if bool(_home_data().get("no_bed", false)): return null
	return super.ensure_bed(id)

static func _point(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])
