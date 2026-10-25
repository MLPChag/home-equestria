extends RefCounted
## Ponyville's town river and the bridges over it, for pony trips (world/characters/navigation/
## pony_navigator.gd). A long pony lead picks straight legs; one that meets the river stops on
## the bank (the arrival escort stalled at X 103, Z -47 on 2026-09-30). When the straight way
## from a pony to her goal crosses water, route() gives the approach points of the cheapest
## bridge, 5 m off each end on dry bank, in walking order.
##
## Water: the town canal grid (world/water/ponyville_canals.json, 1 m cells, NaN = dry), the
## same data the water surface is built from. Bridges: the fitted deck ends of the three placed
## bridges in world/props/ponyville/rnl_scenery.json (tools/rnl_scenery/plan.py; the two stone
## footbridges were rejected by the layout and do not exist). Verified by
## tools/navigation/probe_river_paths.gd, which walk-grid-routes every approach pair.
## Re-fitted square to the water with dry ends on 2026-10-22 (tools/rnl_scenery/fit_bridges.py;
## tools/rnl_scenery/probe_bridges.gd checks these against the placed nodes).
const CANALS := "res://world/water/ponyville_canals.json"
const BRIDGE_ENDS := {
	"bridge_01": [Vector2(58.43, -56.46), Vector2(71.57, -29.54)],   # South bridge
	"bridge_02": [Vector2(194.96, -76.94), Vector2(197.04, -47.06)], # Market road bridge
	"bridge_03": [Vector2(245.47, -18.62), Vector2(274.53, -11.38)], # East bridge
}
## Approach pairs walked end to end by a pony, used instead of the computed ones. The South
## bridge's old skewed placement put its computed south point beside the ramp rail
## (tools/navigation/river_trips.gd, 2026-09-30); since the 2026-10-22 re-fit every bridge
## runs straight across with dry ends, so the computed points (5 m off each end) are used.
const WALKED := {}
const APPROACH := 5.0
const STEP := 1.5

static var _loaded := false
static var _heights := PackedFloat32Array()
static var _width := 0
static var _depth := 0
static var _origin := Vector2.ZERO
static var _cell := 1.0
static var _approaches: Dictionary = {}   # bridge id -> [Vector2, Vector2], dry ends

static func _load() -> void:
	if _loaded: return
	_loaded = true
	if not FileAccess.file_exists(CANALS): return
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(CANALS))
	if not doc is Dictionary: return
	_width = int(doc.width); _depth = int(doc.depth); _cell = float(doc.cell)
	_origin = Vector2(float(doc.origin[0]), float(doc.origin[1]))
	_heights = Marshalls.base64_to_raw(String(doc.heights)).to_float32_array()
	if _heights.size() != _width * _depth: _heights = PackedFloat32Array()
	for id: String in BRIDGE_ENDS:
		var a: Vector2 = BRIDGE_ENDS[id][0]
		var b: Vector2 = BRIDGE_ENDS[id][1]
		var along := (b - a).normalized()
		_approaches[id] = WALKED[id] if WALKED.has(id) else [_dry_beyond(a, -along), _dry_beyond(b, along)]

## Out from a deck end along the span until the bank is dry, then APPROACH metres more.
static func _dry_beyond(end: Vector2, outward: Vector2) -> Vector2:
	var at := end
	for i in 20:
		if not wet(at): break
		at += outward
	return at + outward * APPROACH

## Water under this ground point (outside the town grid counts as dry).
static func wet(at: Vector2) -> bool:
	_load()
	if _heights.is_empty(): return false
	var i := int(round((at.x - _origin.x) / _cell))
	var j := int(round((at.y - _origin.y) / _cell))
	if i < 0 or j < 0 or i >= _width or j >= _depth: return false
	return not is_nan(_heights[j * _width + i])

## The straight ground line between two points passes over water.
static func crosses(from: Vector2, to: Vector2) -> bool:
	var length := from.distance_to(to)
	var count := maxi(1, ceili(length / STEP))
	for k in range(1, count):
		if wet(from.lerp(to, float(k) / count)): return true
	return false

## Bridge approach points to walk through, in order, from `from` to `to` (world positions);
## [] when the straight way stays dry or no single bridge joins the two banks.
static func route(from: Vector3, to: Vector3) -> Array:
	_load()
	var a := Vector2(from.x, from.z)
	var b := Vector2(to.x, to.z)
	if _heights.is_empty() or not crosses(a, b): return []
	var best: Array = []
	var best_cost := INF
	for id: String in _approaches:
		var ends: Array = _approaches[id]
		for flip in 2:
			var near: Vector2 = ends[flip]
			var far: Vector2 = ends[1 - flip]
			if crosses(a, near) or crosses(far, b): continue
			var cost := a.distance_to(near) + near.distance_to(far) + far.distance_to(b)
			if cost < best_cost: best_cost = cost; best = [near, far]
	var points: Array = []
	for p: Vector2 in best:
		var y: float = WorldTerrain.instance.height_at(Vector3(p.x, 0, p.y)) if is_instance_valid(WorldTerrain.instance) else NAN
		points.append(Vector3(p.x, y if is_finite(y) else from.y, p.y))
	return points

## Every bridge's approach pair, for labs and the probe.
static func approaches() -> Dictionary:
	_load()
	return _approaches.duplicate(true)
