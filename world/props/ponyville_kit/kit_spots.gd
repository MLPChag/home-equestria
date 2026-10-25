extends RefCounted
## Read the authored kit once. Select from a resident's actual assigned house,
## never from the current body position: loaded and essence steps choose alike.
const PLACEMENTS := "res://world/props/ponyville_kit/placements.json"
const LAYOUT := "res://world/towns/ponyville/layout.json"
const GARDEN := ["rose_bed", "flowering_shrub", "bush_round_small", "bush_round_medium", "bush_cluster_large"]
const PUBLIC := ["well", "bench", "tree_stump"]
const APPROACH_CLEARANCE := 0.8
static var _loaded := false
static var _by_id: Dictionary = {}
static var _by_kind: Dictionary = {}
static var _by_owner: Dictionary = {}
static var _layout_homes: Dictionary = {}
static var _population: WeakRef
static var _home_groups: Dictionary = {}
static var _home_points: Dictionary = {}

static func _index() -> void:
	if _loaded: return
	_loaded = true
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PLACEMENTS))
	if not parsed is Dictionary: return
	for value: Variant in parsed.get("entries", []):
		if not value is Dictionary: continue
		var row: Dictionary = value
		var id := str(row.get("id", ""))
		var kind := str(row.get("kind", ""))
		var owner := str(row.get("group", ""))
		if id.is_empty() or kind.is_empty() or _by_id.has(id): continue
		_by_id[id] = row
		if not _by_kind.has(kind): _by_kind[kind] = []
		(_by_kind[kind] as Array).append(id)
		if not _by_owner.has(owner): _by_owner[owner] = {}
		var kinds: Dictionary = _by_owner[owner]
		if not kinds.has(kind): kinds[kind] = []
		(kinds[kind] as Array).append(id)
	# Persisted home addresses are the exact rounded generic-house origin, not
	# nearest-neighbour guesses. This also works before its zone is instantiated.
	var layout: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	if not layout is Dictionary: return
	for row: Dictionary in layout.get("placements", []):
		var point := Vector3(float(row.x), preload("res://world/props/ponyville_kit/kit_lifts.gd").y(row), float(row.z))
		var address := "house:%d:%d:%d" % [roundi(point.x * 10), roundi(point.y * 10), roundi(point.z * 10)]
		var owner := "house:" + str(row.id)
		# An ambiguous authored address supplies no owner; a live home can validate it.
		_layout_homes[address] = {} if _layout_homes.has(address) else {"owner": owner, "position": point}

## The kit group uses the real plot node name. Generic home.place_id() instead
## uses rounded world coordinates and cannot be compared to "house:plot_*".
## Remember only this population's observed mappings, so an unloaded house can
## still resolve without borrowing an address from another saved world.
static func _home(population: Node, id: String) -> Dictionary:
	if not is_instance_valid(population): return {}
	if _population == null or _population.get_ref() != population:
		_population = weakref(population); _home_groups.clear(); _home_points.clear()
	var house: Node3D = population.home_house(id) if population.has_method("home_house") else null
	var place := ""
	if is_instance_valid(house):
		place = str(house.place_id())
		var node: Node = house
		var owner := ""
		while node != null:
			var candidate := "house:" + str(node.name)
			if _by_owner.has(candidate): owner = candidate; break
			node = node.get_parent()
		_home_groups[place] = owner
		_home_points[place] = house.global_position
	elif "houses" in population:
		var houses: Dictionary = population.get("houses")
		place = str(houses.get(id, ""))
	if not place.is_empty() and not _home_groups.has(place):
		var authored: Dictionary = _layout_homes.get(place, {})
		if not authored.is_empty():
			_home_groups[place] = str(authored.owner)
			_home_points[place] = authored.position
	var point: Vector3 = _home_points.get(place, Vector3.INF)
	if not point.is_finite() and population.has_method("home_position"):
		point = population.home_position(id, true)
	var bounds := Rect2()
	if "config" in population:
		var config: Variant = population.get("config")
		if config != null:
			var region_id: String = population.residence_region(id) if population.has_method("residence_region") else str(config.assignments.get(id, ""))
			var region := WorldLayout.region(region_id)
			if not region.is_empty(): bounds = WorldLayout.footprint(region).grow(300.0)
	return {"owner": str(_home_groups.get(place, "")), "position": point, "bounds": bounds}

static func _kinds(kind: String) -> Array:
	return GARDEN if kind == "garden" else [kind]

static func _candidates(home: Dictionary, kind: String) -> Array:
	var ids: Array = []
	if kind in PUBLIC:
		for id: String in _by_kind.get(kind, []):
			var row: Dictionary = _by_id[id]
			if str(row.group).begins_with("house:"): continue
			var bounds: Rect2 = home.get("bounds", Rect2())
			if bounds.has_area() and not bounds.has_point(Vector2(float(row.x), float(row.z))): continue
			ids.append(id)
	else:
		var owned: Dictionary = _by_owner.get(str(home.get("owner", "")), {})
		for actual: String in _kinds(kind): ids.append_array(owned.get(actual, []))
	return ids

## Presence conditions for the morning roll, no terrain query or model load.
## when.spot accepts one of these kind keys, or an array requiring every key.
static func available(population: Node, resident_id: String) -> Dictionary:
	_index()
	var home := _home(population, resident_id)
	if home.is_empty() or not (home.position as Vector3).is_finite(): return {}
	var result := {}
	for kind: String in _by_kind:
		if not _candidates(home, kind).is_empty(): result[kind] = true
	if not _candidates(home, "garden").is_empty(): result.garden = true
	return result

## Resolve "garden" or "spot:garden". Owned kinds never use another plot's goods.
## Public destinations use the assigned home as their stable nearest-point anchor.
static func resolve(population: Node, resident_id: String, target: String) -> Dictionary:
	_index()
	var kind := target.trim_prefix("spot:")
	var home := _home(population, resident_id)
	if home.is_empty(): return {}
	var origin: Vector3 = home.position
	if not origin.is_finite(): return {}
	var chosen := ""
	var distance := INF
	for id: String in _candidates(home, kind):
		var row: Dictionary = _by_id[id]
		var point := Vector3(float(row.x), preload("res://world/props/ponyville_kit/kit_lifts.gd").y(row), float(row.z))
		var gap := Vector2(point.x - origin.x, point.z - origin.z).length_squared()
		if gap < distance or (gap == distance and (chosen.is_empty() or id < chosen)):
			chosen = id; distance = gap
	if chosen.is_empty(): return {}
	return _record(_by_id[chosen], origin, population.get_tree() if population.is_inside_tree() else null)

## Copy of an exact authored instance for the state/visual owner; no resident selection.
static func by_id(id: String) -> Dictionary:
	_index()
	return _record(_by_id[id], Vector3.INF, null) if _by_id.has(id) else {}

static func _record(row: Dictionary, home: Vector3, _tree: SceneTree) -> Dictionary:
	var position := Vector3(float(row.x), preload("res://world/props/ponyville_kit/kit_lifts.gd").y(row), float(row.z))
	var transform := Transform3D(Basis(Vector3.UP, float(row.yaw)), position)
	var outward := -transform.basis.z
	# Kit models face Blender -Y, which is +Z here: a bench's seat front (its backrest is at
	# -Z, activity/fit.json) is approached from +Z, never from behind the backrest.
	if str(row.kind) == "bench": outward = transform.basis.z
	# Wall planting is approached from the side away from its house. Public
	# well fronts retain the authored -Z orientation used by kit rendering.
	if home.is_finite() and str(row.group).begins_with("house:"):
		var away := Vector3(position.x - home.x, 0.0, position.z - home.z)
		if away.length_squared() > 0.01: outward = away.normalized()
	var approach := position + outward * (float(row.get("radius", 0.0)) + APPROACH_CLEARANCE)
	# Preserve actual terrain height when resident. This is a route target, not
	# route certification: the handler must still use its navigator's ground,
	# slope, clearance and arrival checks. No body/root transform is written here.
	var grounded := false
	if is_instance_valid(WorldTerrain.instance):
		var height: float = WorldTerrain.instance.height_at(approach)
		if is_finite(height): approach.y = height; grounded = true
	# seat_point stays INF here: the live seat marker belongs to life (DayAction.spot fills it),
	# so this placement index never reads the seating layer.
	var seat_point := Vector3.INF
	return {"id": str(row.id), "kind": str(row.kind), "owner": str(row.group),
		"transform": transform, "position": position, "approach": approach,
		"grounded": grounded, "seat_point": seat_point, "radius": float(row.get("radius", 0.0))}
