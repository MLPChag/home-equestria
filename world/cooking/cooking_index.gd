extends RefCounted
## Static kitchen fixtures register by cell once. Hand offers touch only nearby cells.
const CELL := 4.0
static var cells: Dictionary = {}
static var members: Dictionary = {}
static var by_station: Dictionary = {}

static func cell(point: Vector3) -> Vector3i:
	return Vector3i(floori(point.x / CELL), floori(point.y / CELL), floori(point.z / CELL))

static func add(station: Node3D) -> void:
	if not station.is_inside_tree(): return
	var id := station.get_instance_id()
	var key := cell(station.global_position)
	if members.get(id) == key: return
	remove(station)
	if not cells.has(key): cells[key] = {}
	cells[key][id] = weakref(station)
	members[id] = key
	by_station[station.station_id] = weakref(station)

static func remove(station: Node3D) -> void:
	var id := station.get_instance_id()
	if not members.has(id): return
	var key: Vector3i = members[id]
	if cells.has(key):
		cells[key].erase(id)
		if cells[key].is_empty(): cells.erase(key)
	members.erase(id)
	if by_station.has(station.station_id) and by_station[station.station_id].get_ref() == station: by_station.erase(station.station_id)

static func near(point: Vector3, radius := 2.0) -> Array[Node3D]:
	var result: Array[Node3D] = []
	if not point.is_finite(): return result
	var low := cell(point - Vector3.ONE * radius)
	var high := cell(point + Vector3.ONE * radius)
	for x in range(low.x, high.x + 1):
		for y in range(low.y, high.y + 1):
			for z in range(low.z, high.z + 1):
				var entries: Dictionary = cells.get(Vector3i(x,y,z), {})
				for reference: WeakRef in entries.values():
					var station: Node3D = reference.get_ref()
					if is_instance_valid(station) and station.global_position.distance_squared_to(point) <= radius * radius: result.append(station)
	return result

static func lookup(station_id: String) -> Node3D:
	var reference: WeakRef = by_station.get(station_id)
	return reference.get_ref() if reference != null else null
