extends RefCounted
## Native 3D flight routes (phase 5 of docs/NAVIGATION_OVERHAUL_COMPLETE_2026_10_02.txt,
## docs/NAVIGATION_PHASE_5_2026_10_02.md). One PonyAirNavigation per game holds the baked air
## volume (world/navigation/air_data/, built by tools/navigation/air_extract_geometry.gd and the
## nav_air baker) and a follower per flying pony. pony_flight.gd asks it for the cruise between
## takeoff and the glide-in; outside the baked volume, for bodies larger than the baked envelope,
## with `-- --native-navigation off` or without the native class, flights use their old corridors.
const BACKEND := preload("res://world/navigation/native_navigation_backend.gd")
const CLASS_NAME := "PonyAirNavigation"
const DATA := "res://world/navigation/air_data/ponyville_everfree.pegasus_mare.airnav"
## The data is baked for a full-size pegasus mare's envelope; bigger bodies need their own bake.
const MAX_BODY_SCALE := 1.15
## nav_air::Cell
const FREE := 1
const SOLID := 2
## nav_air::AirCommandMode
const ARRIVED := 3
const FAILED := 4

static var _air: RefCounted = null
static var _tried := false
static var _next_id := 0


## The loaded air volume, or null (reported once, loudly, when native navigation is on).
static func instance() -> RefCounted:
	if _tried:
		return _air
	_tried = true
	if BACKEND.mode() == "off":
		return null
	if not ClassDB.class_exists(CLASS_NAME):
		_report("%s is not in this build of native/pony_solver for %s; flights use their old corridors" % [CLASS_NAME, OS.get_name()])
		return null
	if not FileAccess.file_exists(DATA):
		_report("No baked air volume at %s; flights use their old corridors" % DATA)
		return null
	var air: RefCounted = ClassDB.instantiate(CLASS_NAME)
	var info: Dictionary = air.load_bytes(FileAccess.get_file_as_bytes(DATA))
	if not bool(info.get("ok", false)):
		_report("The baked air volume did not load (%s); flights use their old corridors" % str(info.get("error", "?")))
		return null
	_air = air
	return _air


## Her size against the baked full-size mare: body scale times model scale (the princesses are
## full-size bodies on a bigger model).
static func size_of(pony: Node) -> float:
	var body: float = float(pony.get("body_scale")) if pony.get("body_scale") != null else 1.0
	var model: float = float(pony.get("model_scale")) if pony.get("model_scale") != null else 1.0
	return body * model


static func new_id() -> int:
	_next_id += 1
	return _next_id


static func _report(message: String) -> void:
	push_error(message)
	printerr(message)
