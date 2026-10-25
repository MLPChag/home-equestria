extends "res://world/buildings/authored_home.gd"
const BED_SLOT := preload("res://world/buildings/bed_slot.gd")
## Metre-scale adapter for Pinkie's authored stairs and cupcake-tower bedroom.
const PLACE := "house:sugarcube_tower"
const RESIDENT := "pinkie_pie"
@export var stair_path: Array[Vector3] = []
@export var ground_path_count := 0
@export var room_bounds := Rect2(-1.0, -1.5, 1.8, 2.8)
@export var room_floor := 11.6
@export var room_ceiling := 15.2
@export var stair_width := 1.0
@export var route_clearance := 1.8
@export var bed_path := NodePath("../TowerRoom/PinkieBed")
@export var bakery_path := NodePath("../HouseInterior")
var _bakery: Node3D

func _init() -> void:
	home_kind = "sugarcube_tower"
	set_meta("reserved_for", "")

func _ready() -> void:
	super._ready()
	_ceiling_y = room_ceiling
	_bakery = get_node_or_null(bakery_path) as Node3D
	if _bakery != null:
		doorway = to_local(_bakery.to_global(_bakery.doorway))
		approach = to_local(_bakery.outside())
		door_width = float(_bakery.door_width) * _bakery.global_basis.x.length() / global_basis.x.length()
	bed = get_node_or_null(bed_path) as Node3D
	if bed != null: bed.set_meta("house", self)

## Preserve an existing world's chosen home; never change the saved dictionary here.
func configure_owner(homes: Dictionary) -> bool:
	var adopt := not homes.has(RESIDENT) or str(homes[RESIDENT]) == PLACE
	set_meta("reserved_for", RESIDENT if adopt else "")
	return adopt

func connects_to(other: Node3D) -> bool: return is_instance_valid(_bakery) and other == _bakery
func door() -> Node: return _bakery.door() if is_instance_valid(_bakery) else null
func inside() -> Vector3:
	if is_instance_valid(_bakery): return _bakery.inside()
	return to_global(stair_path[0]) if not stair_path.is_empty() else Vector3.INF
func outside() -> Vector3: return _bakery.outside() if is_instance_valid(_bakery) else to_global(approach)
func center() -> Vector3: return to_global(stair_path[-1]) if not stair_path.is_empty() else Vector3.INF
func slots() -> Array[Vector3]: return [center()]
func fits(profile: Resource) -> bool:
	return is_instance_valid(_bakery) and _bakery.fits(profile) \
		and stair_width > float(profile.radius) * 2.0 + .08 \
		and route_clearance > float(profile.clearance) + .1

func contains(at: Vector3, lighting := false) -> bool:
	var p := to_local(at)
	if p.y >= room_floor - .15 and p.y <= room_ceiling \
		and room_bounds.has_point(Vector2(p.x, p.z)): return true
	for i in stair_path.size() - 1:
		var a := stair_path[i]
		var b := stair_path[i + 1]
		# Ground-floor visitors belong to the commercial bakery, not this home.
		if maxf(a.y, b.y) <= floor_y + .15: continue
		var headroom := route_clearance if lighting else .6
		if p.y < minf(a.y, b.y) - .15 or p.y > maxf(a.y, b.y) + headroom: continue
		var flat := Geometry2D.get_closest_point_to_segment(Vector2(p.x, p.z), Vector2(a.x, a.z), Vector2(b.x, b.z))
		if flat.distance_squared_to(Vector2(p.x, p.z)) > stair_width * stair_width * .25: continue
		var span := Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
		var fraction := Vector2(a.x, a.z).distance_to(flat) / span if span > .001 else 0.0
		var surface_y := lerpf(a.y, b.y, fraction)
		if p.y >= surface_y - .15 and p.y <= surface_y + headroom: return true
	return false

func ensure_bed(_id: String = "") -> Node3D: return bed if is_instance_valid(bed) else null
func bed_shared(_id: String) -> bool: return false

func bed_side(_id: String = "") -> Vector3:
	if not is_instance_valid(bed): return Vector3.INF
	return BED_SLOT.side(bed, Vector3(0, 0, 1.6))

func bed_rest(_id: String = "") -> Transform3D:
	if not is_instance_valid(bed): return Transform3D(Basis.IDENTITY, Vector3.INF)
	var top := float(bed.get_meta("mattress_top", .6))
	var rest: Vector3 = bed.get_meta("rest_local", Vector3(0, top, .15))
	return BED_SLOT.rest(bed, rest)

func on_mattress(point: Vector3, _id: String = "") -> bool:
	if not is_instance_valid(bed): return false
	return BED_SLOT.on_mattress(bed, point, Vector3(1.4, 1.1, 2.1))

func local_waypoint(from: Vector3, to: Vector3) -> Vector3:
	if stair_path.size() < 2: return from
	var a := to_local(from)
	var b := to_local(to)
	# Distance in 3D distinguishes stacked windings at the same horizontal position.
	var segment := 0
	var distance := INF
	var closest := Vector3.ZERO
	for i in stair_path.size() - 1:
		var nearest := Geometry3D.get_closest_point_to_segment(a, stair_path[i], stair_path[i + 1])
		var candidate := a.distance_squared_to(nearest)
		if candidate < distance:
			distance = candidate
			segment = i
			closest = nearest
	# Join a route endpoint before ascending/descending; an off-path approach must
	# not aim at the far end of the first inclined segment through its support.
	if segment == 0 and closest.distance_squared_to(stair_path[0]) < .000001 and a.distance_to(stair_path[0]) > .12:
		return to_global(stair_path[0])
	if segment == stair_path.size() - 2 and closest.distance_squared_to(stair_path[-1]) < .000001 and a.distance_to(stair_path[-1]) > .12:
		return to_global(stair_path[-1])
	# Ground approach points are part of this path too: when descending, follow
	# them around the counter before handing the final shop leg back to the bakery.
	var target_segment := 0
	var target_distance := INF
	for i in stair_path.size() - 1:
		var nearest := Geometry3D.get_closest_point_to_segment(b, stair_path[i], stair_path[i + 1])
		var candidate := b.distance_squared_to(nearest)
		if candidate < target_distance:
			target_distance = candidate
			target_segment = i
	if target_segment == segment:
		if a.y <= floor_y + .15 and b.y <= floor_y + .15 and is_instance_valid(_bakery):
			return _bakery.local_waypoint(from, to)
		return to
	var upward := target_segment > segment
	var index := segment + 1 if upward else segment
	if a.distance_to(stair_path[index]) < .12:
		index = clampi(index + (1 if upward else -1), 0, stair_path.size() - 1)
	if index == 0 and a.distance_to(stair_path[0]) < .12:
		return _bakery.local_waypoint(from, to) if is_instance_valid(_bakery) else to
	if index == stair_path.size() - 1 and a.y >= room_floor - .04: return to
	return to_global(stair_path[index])

## Bakery ownership resumes at the stair foot; retain the authored counter detour.
## INF means both endpoints already lie on the ordinary entrance-side segment.
func ground_waypoint(from: Vector3, to: Vector3) -> Vector3:
	var count := mini(ground_path_count, stair_path.size())
	if count < 2: return Vector3.INF
	var a := to_local(from)
	var b := to_local(to)
	var segments: Array[int] = []
	for point: Vector3 in [a, b]:
		var best := INF
		var segment := 0
		for i in count - 1:
			var nearest := Geometry3D.get_closest_point_to_segment(point, stair_path[i], stair_path[i + 1])
			var distance := point.distance_squared_to(nearest)
			if distance < best:
				best = distance; segment = i
		segments.append(segment)
	if segments[0] == 0 and segments[1] == 0: return Vector3.INF
	if segments[0] == segments[1]: return to
	var forward := segments[1] > segments[0]
	var index := segments[0] + 1 if forward else segments[0]
	if a.distance_to(stair_path[index]) < .12:
		index = clampi(index + (1 if forward else -1), 0, count - 1)
	return to_global(stair_path[index])
