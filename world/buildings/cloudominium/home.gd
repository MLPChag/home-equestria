extends "res://world/buildings/authored_home.gd"
const BED_SLOT := preload("res://world/buildings/bed_slot.gd")
const STAIRS := preload("res://world/buildings/stair_path_follower.gd")
const ROUTE_GRAPH := preload("res://world/buildings/indoor_route_graph.gd")
## Rainbow Dash's Cloudominium as her real home (dev 2026-09-28): the house, door and bed
## interface over the two-storey room in layout.gd's frame. Hall and lounge downstairs, her
## bedroom upstairs, joined by the curved stair (architecture meta "stair_path"). The front door
## opens onto the cloud, which only flyers reach: house_travel.gd flies them to outside() first.
const PLACE := "house:cloudominium"
## The move-in address stored before the walk-in interior (relationship_runtime.gd fallback).
const LEGACY_PLACE := "cloudominium_01"
const OWNER := "rainbow_dash"
const GUEST_REST := preload("res://world/relationships/shared_bed.gd")
const OPEN_DOORWAY := preload("res://world/buildings/open_doorway.gd")
var layout: Dictionary = {}
var architecture: Node3D
var furniture: Node3D
var leaf: Node
var radius := 4.2
var upper_y := 4.8
var doorway_height := 3.6
var entry_point := Vector3(0, 0, 3.0)
var stair_path: Array[Vector3] = []
var _walk_cache: Dictionary = {}   # "ground"/"upper" -> Array[Vector3] clear local points
var _route_cache: Array[Dictionary] = []
var _bond_check_at := 0

func _init() -> void:
	home_kind = "cloudominium"
	set_meta("reserved_for", OWNER)
	_ceiling_y = 9.6

func configure(room: Dictionary, built: Node3D, furnishing: Node3D, door_leaf: Node3D) -> void:
	layout = room
	architecture = built
	furniture = furnishing
	leaf = door_leaf
	radius = float(room.get("radius", 4.2))
	floor_y = float(room.get("ground_y", 0.0))
	upper_y = float(room.get("upper_y", 4.8))
	_ceiling_y = float(room.get("ceiling_y", 9.6))
	var door_at: Vector3 = room.get("door_position", Vector3(0, floor_y, radius))
	doorway = door_at
	door_width = float(room.get("door_width", 1.9))
	doorway_height = float(room.get("door_height", 3.6))
	var outside_at: Vector3 = room.get("door_approach", doorway + Vector3(0, 0, 1.8))
	approach = outside_at
	var inside_at: Vector3 = room.get("door_inside", doorway - Vector3(0, 0, 1.2))
	entry_point = inside_at
	floors = [Rect2(-radius, -radius, radius * 2.0, radius * 2.0), Rect2(doorway.x - door_width * .5, radius - .6, door_width, maxf(.6, doorway.z - radius + .6))]
	stair_path.clear()
	if is_instance_valid(built) and built.has_meta("stair_path"):
		for p: Vector3 in built.get_meta("stair_path"): stair_path.append(p)
	_walk_cache.clear()
	_route_cache.clear()
	bed = ensure_bed(OWNER)
	for target: Node3D in [bed, _guest_bed()]:
		if target != null: target.set_meta("house", self)
	_install_guest_rest()

## Anon's existing physical bed rest (shared_bed.gd, no relationship needed), as in Golden Oak.
func _install_guest_rest() -> void:
	var rest: Node = furniture.find_child("GuestBedRest", true, false) if is_instance_valid(furniture) else null
	if rest == null: rest = get_node_or_null("GuestBedRest")
	if rest == null:
		rest = GUEST_REST.new()
		rest.name = "GuestBedRest"
		add_child(rest)
	# One bed interface: guest bed, lanes and the partner's shared bed all come from here.
	rest.set("house", self)

## The old sky rule kept her out of homes.json, so every save's Rainbow Dash lives here.
func configure_owner(_homes: Dictionary) -> bool:
	_adopt_legacy_move_in()
	return true

## Anon moved in with her before this interior existed: that shared home was the scenery name.
## Point it at this house so relationship_runtime.gd finds it and lays out the shared bed.
func _adopt_legacy_move_in() -> void:
	var now := Time.get_ticks_msec()
	if now < _bond_check_at or not is_inside_tree(): return
	_bond_check_at = now + 5000
	var runtime: Node = get_tree().get_first_node_in_group("player_relationships")
	if runtime == null or not ("bonds" in runtime) or not is_instance_valid(runtime.bonds): return
	var row: Dictionary = runtime.bonds.record_for(OWNER)
	if str(row.get("shared_home_id", "")) != LEGACY_PLACE: return
	row.shared_home_id = PLACE
	runtime.bonds._save(OWNER, row)

func set_sleepers(ids: Array) -> void:
	_sleepers = ids.duplicate()

## Stands on a cloud: nopony walks up to it (house_travel.gd sky_trip / fly_off).
func sky_home() -> bool: return true
func door() -> Node:
	if is_instance_valid(leaf) and leaf.has_method("request_passage"): return leaf
	var open := get_node_or_null("OpenDoorway")
	if open == null:
		open = OPEN_DOORWAY.new()
		open.name = "OpenDoorway"
		add_child(open)
	return open
## A clear hall point on the door path, between the entrance and the middle of the room.
func center() -> Vector3: return to_global(Vector3(entry_point.x, floor_y, entry_point.z * .6))
func inside() -> Vector3: return to_global(entry_point)
func outside() -> Vector3: return to_global(approach)

func _reach_squared() -> float:
	var reach := maxf(radius, doorway.z) + 1.0
	return reach * reach + _ceiling_y * _ceiling_y

## Both storeys: anywhere inside the round wall from the hall floor to the upper ceiling, plus
## the entrance passage up to the door.
func contains(at: Vector3, _lighting: bool = false) -> bool:
	var p := to_local(at)
	if p.y < floor_y - .15 or p.y > _ceiling_y: return false
	if Vector2(p.x, p.z).length_squared() <= radius * radius: return true
	return p.y < floor_y + doorway_height and p.z >= radius - .6 and p.z < doorway.z + .05 and absf(p.x - doorway.x) < door_width * .5

func fits(profile: Resource) -> bool:
	return door_width > profile.radius * 2.0 + .08 and doorway_height > profile.clearance + .1

func slots() -> Array[Vector3]:
	var middle := Vector3(entry_point.x, floor_y, entry_point.z * .6)
	return [center(), inside(), to_global(middle + Vector3(.9, 0, .25)), to_global(middle + Vector3(-.9, 0, .25))]

## Dash's own bed upstairs. Anon rests in the guest bed, or beside her once he lives here.
func ensure_bed(id: String = "") -> Node3D:
	if not is_instance_valid(furniture) or not furniture.has_method("ensure_bed"): return null
	if id == "player" and not _player_shares(): return _guest_bed()
	return furniture.ensure_bed(OWNER if id.is_empty() or id == "player" else id)

func _guest_bed() -> Node3D:
	if not is_instance_valid(furniture) or not furniture.has_meta("guest_bed"): return null
	var guest: Variant = furniture.get_meta("guest_bed")
	if not is_instance_valid(guest): return null
	return guest as Node3D

## Anon shares her bed once he moved in with her (or when there is no guest bed at all).
func _player_shares() -> bool:
	return str(get_meta("player_partner", "")) == OWNER or _guest_bed() == null

## Sharing: Anon on one half of her mattress, Dash on the other, close enough to cuddle.
func bed_shared(id: String) -> bool:
	return (id == OWNER or id == "player") and _player_shares()

func bed_side(id: String = "") -> Vector3:
	var target := ensure_bed(id)
	if target == null: return Vector3.INF
	var size: Vector3 = target.get_meta("bed_size", BED_SIZE)
	return BED_SLOT.side(target, Vector3(0, 0, size.z * .5 + .6))

## Where she lies: on the mattress, head toward the pillows. Lying there, pony_posture.gd's soft
## bedding lets her settle into the drawn cloud and press into it (dev 2026-09-28: "make sure the
## mares TOUCH the bed not float off of it"), so the rest starts on the physics top.
func bed_rest(id: String = "") -> Transform3D:
	var target := ensure_bed(id)
	if target == null: return Transform3D(Basis.IDENTITY, Vector3.INF)
	var top := float(target.get_meta("mattress_top", .6))
	var size: Vector3 = target.get_meta("bed_size", BED_SIZE)
	var lane := 0.0
	if bed_shared(id): lane = minf(.48, size.x * .24) * (-1.0 if id == "player" else 1.0)
	return BED_SLOT.rest(target, Vector3(lane, top, .15))

func on_mattress(point: Vector3, id: String = "") -> bool:
	var target := ensure_bed(id)
	if target == null: return false
	return BED_SLOT.on_mattress(target, point, BED_SIZE)

## Between storeys: to the stair foot or landing around the furniture, then its centre line.
func local_waypoint(from: Vector3, to: Vector3) -> Vector3:
	return STAIRS.waypoint(self, from, to, stair_path, upper_y, floor_y, .06, _flat_waypoint)

func _clear(a: Vector3, b: Vector3) -> bool:
	# Floor changes use the stair, never a diagonal through the upper floor.
	if absf(a.y - b.y) > .3: return false
	var shape := CapsuleShape3D.new()
	shape.radius = .34
	shape.height = 1.45
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1
	query.margin = .005
	query.transform.origin = a + Vector3.UP * .78
	query.motion = b - a
	var space := get_world_3d().direct_space_state
	return ROUTE_GRAPH.sweep(space, query)

func _flat_waypoint(from: Vector3, to: Vector3) -> Vector3:
	# Reuse routes while walking a clear leg rather than rebuilding per physics tick.
	var now := Time.get_ticks_msec()
	for item in _route_cache:
		if now - int(item.time) < 2000 and to.distance_squared_to(item.goal) < .01 and from.distance_squared_to(item.start) < .36 and from.distance_squared_to(item.next) > .04:
			return item.next
	var next := _find_flat_waypoint(from, to)
	# Replace the completed leg. Keeping older entries can reactivate one after
	# walking 20 cm beyond it, repeatedly reversing the moving character.
	_route_cache.assign([{"time": now, "goal": to, "start": from, "next": next}])
	return next

func _find_flat_waypoint(from: Vector3, to: Vector3) -> Vector3:
	if _clear(from, to): return to
	var points: Array[Vector3] = [from, to]
	for p: Vector3 in _walk_points(to_local(from).y >= upper_y - .25): points.append(to_global(p))
	return ROUTE_GRAPH.next(points, _clear)

## Clear standing points on one storey (local): the furniture's own walk points when it has them,
## else two rings, kept where a floor is under them and a pony-sized capsule fits. Measured on
## first use, when the furniture bodies are in the physics space.
func _walk_points(upper: bool) -> Array[Vector3]:
	var key := "upper" if upper else "ground"
	if _walk_cache.has(key): return _walk_cache[key]
	var level := upper_y if upper else floor_y
	var candidates: Array[Vector3] = []
	for source: Node in [furniture, architecture]:
		if not is_instance_valid(source): continue
		for meta: String in (["upper_walk_points", "loft_walk_points"] if upper else ["ground_walk_points"]):
			if not source.has_meta(meta): continue
			for p: Vector3 in source.get_meta(meta): candidates.append(p)
	if candidates.is_empty():
		for k in 6:
			for ring: float in [radius * .45, radius * .74]:
				var angle := deg_to_rad(60.0 * k + (30.0 if ring > radius * .5 else 0.0))
				candidates.append(Vector3(sin(angle) * ring, level, cos(angle) * ring))
	var result: Array[Vector3] = []
	if stair_path.size() >= 2: result.append(stair_path[-1] if upper else stair_path[0])
	if not upper: result.append(entry_point)
	var space := get_world_3d().direct_space_state
	var shape := CapsuleShape3D.new()
	shape.radius = .34
	shape.height = 1.45
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1
	query.margin = .005
	for p: Vector3 in candidates:
		var at := to_global(p)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3.UP * .5, at - Vector3.UP * .5, 1))
		if hit.is_empty() or absf(to_local(hit.position).y - level) > .25: continue
		query.transform = Transform3D(Basis.IDENTITY, at + Vector3.UP * .78)
		if space.intersect_shape(query, 1).is_empty(): result.append(p)
	_walk_cache[key] = result
	return result
