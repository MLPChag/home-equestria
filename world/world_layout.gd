class_name WorldLayout
extends RefCounted
## The 15 km world frame (world/world_layout.json, WORLD.md): regions (native zones and
## generated-only canon places), links (roads, rails, rivers) and the canon-map transform.
## Loaded once per process; `tools/world_layout.py` validates and derives zones.json from it.

const PATH := "res://world/world_layout.json"
static var _cached: Dictionary = {}


static func data() -> Dictionary:
	if _cached.is_empty():
		var text := FileAccess.get_file_as_string(PATH)
		var parsed = JSON.parse_string(text)
		_cached = parsed if parsed is Dictionary else {}
	return _cached


static func regions() -> Array:
	return data().get("regions", [])


static func links() -> Array:
	return data().get("links", [])


static func region(id: String) -> Dictionary:
	for r in regions():
		if r.get("id") == id:
			return r
	return {}


## Region of the native zone `zone_id` (e.g. "ponyville"), or empty.
static func region_of_zone(zone_id: String) -> Dictionary:
	for r in regions():
		if r.get("zone") == zone_id:
			return r
	return {}


## Where the player and roster stand in a region (`spawn` [x, z]); the region centre when
## the layout has none. Ponyville's is the plaza spot the roster ring is built around.
static func spawn(id: String) -> Vector2:
	var r := region(id)
	if r.has("spawn") and (r.spawn as Array).size() >= 2:
		return Vector2(float(r.spawn[0]), float(r.spawn[1]))
	var c := center(id)
	return Vector2(c.x, c.z)


static func center(id: String) -> Vector3:
	var r := region(id)
	if r.is_empty():
		return Vector3.INF
	var c: Array = r.center
	return Vector3(float(c[0]), float(c[1]), float(c[2]))


## World XZ box (xmin, zmin, xmax, zmax) of a region: the zone footprint moved to its centre,
## or a square of `radius` for generated regions.
static func footprint(r: Dictionary) -> Rect2:
	var c: Array = r.center
	var cx := float(c[0])
	var cz := float(c[2])
	if r.has("footprint"):
		var fp: Array = r.footprint
		var lx := (float(fp[0]) + float(fp[2])) * 0.5
		var lz := (float(fp[1]) + float(fp[3])) * 0.5
		return Rect2(cx + float(fp[0]) - lx, cz + float(fp[1]) - lz, float(fp[2]) - float(fp[0]), float(fp[3]) - float(fp[1]))
	var radius := float(r.get("radius", 400.0))
	return Rect2(cx - radius, cz - radius, radius * 2.0, radius * 2.0)


## Nearest region to a world position (by distance to the footprint edge, 0 when inside).
static func nearest(pos: Vector3, kinds: Array = []) -> Dictionary:
	var best := {}
	var best_d := INF
	for r in regions():
		if not kinds.is_empty() and not (r.get("kind") in kinds):
			continue
		var d := distance_to(r, pos)
		if d < best_d:
			best_d = d
			best = r
	return best


static func distance_to(r: Dictionary, pos: Vector3) -> float:
	var f := footprint(r)
	var dx := maxf(0.0, maxf(f.position.x - pos.x, pos.x - f.end.x))
	var dz := maxf(0.0, maxf(f.position.y - pos.z, pos.z - f.end.y))
	return Vector2(dx, dz).length()


static func sea_level() -> float:
	return float(data().get("sea_level", -80.0))


static func canon_to_world(px: Vector2) -> Vector2:
	var c: Dictionary = data().canon
	var m := float(c.m_per_px)
	return Vector2((px.x - float(c.ponyville_px[0])) * m + float(c.ponyville_world[0]),
		(px.y - float(c.ponyville_px[1])) * m + float(c.ponyville_world[1]))


static func world_to_canon(xz: Vector2) -> Vector2:
	var c: Dictionary = data().canon
	var m := float(c.m_per_px)
	return Vector2((xz.x - float(c.ponyville_world[0])) / m + float(c.ponyville_px[0]),
		(xz.y - float(c.ponyville_world[1])) / m + float(c.ponyville_px[1]))
