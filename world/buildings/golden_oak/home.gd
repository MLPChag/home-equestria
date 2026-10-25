extends "res://world/buildings/authored_home.gd"
const STAIRS := preload("res://world/buildings/stair_path_follower.gd")
const ROUTE_GRAPH := preload("res://world/buildings/indoor_route_graph.gd")
## Metre-scale, two-storey home adapter for the authored library.
const PLACE := "house:golden_oak_library"
var furniture: Node3D
var leaf: Node3D
var radius := 5.0
var loft_y := 3.4
var doorway_height := 6.75
var entry_point := Vector3(.16, 0, 4.5)
var stair_path: Array[Vector3] = []
var _route_cache: Array[Dictionary] = []
var _actor_routes: Array[Dictionary] = []

func _init() -> void:
	home_kind = "golden_oak"
	set_meta("reserved_for", "")

func configure(layout: Dictionary, interior: Node3D, door_leaf: Node3D) -> void:
	furniture = interior
	leaf = door_leaf
	radius = float(layout.get("radius", 5.0))
	loft_y = float(layout.get("loft_y", 3.4))
	_ceiling_y = float(layout.get("ceiling_y", 7.2))
	doorway = layout.get("door_position", Vector3(.16, 0, 9.04))
	door_width = float(layout.get("door_width", 3.56))
	doorway_height = float(layout.get("door_height", 6.75))
	approach = layout.get("door_approach", doorway + Vector3(0, 0, 1.4))
	entry_point = layout.get("door_inside", Vector3(.16, 0, 4.5))
	floors = [Rect2(-radius, -radius, radius * 2, radius * 2), Rect2(doorway.x - door_width * .5, 4.0, door_width, doorway.z - 4.0)]
	stair_path.assign(interior.get_meta("stair_path", []))
	bed = interior.ensure_bed("twilight_sparkle")
	for target: Node in interior.find_children("*", "Node3D", true, false):
		if target.has_meta("bed_size"):
			target.set_meta("house", self)

## Existing saves keep their chosen home. New-world Twilight gets her library.
func configure_owner(homes: Dictionary) -> bool:
	var adopt := not homes.has("twilight_sparkle") or str(homes.twilight_sparkle) == PLACE
	set_meta("reserved_for", "twilight_sparkle" if adopt else "")
	return adopt

func set_sleepers(ids: Array) -> void:
	_sleepers = ids.duplicate()

func door() -> Node: return leaf
func inside() -> Vector3: return to_global(entry_point)
func outside() -> Vector3: return to_global(approach)
func contains(at: Vector3, _lighting: bool = false) -> bool:
	var p := to_local(at)
	if p.y < -.15 or p.y > _ceiling_y: return false
	if Vector2(p.x, p.z).length_squared() <= radius * radius: return true
	return p.z >= 4.0 and p.z < doorway.z and absf(p.x - doorway.x) < door_width * .5 and p.y < doorway_height

func fits(profile: Resource) -> bool:
	return door_width > profile.radius * 2.0 + .08 and doorway_height > profile.clearance + .1

func ensure_bed(id: String = "") -> Node3D: return furniture.ensure_bed(id) if is_instance_valid(furniture) else null
func bed_shared(_id: String) -> bool: return false
func bed_side(id: String = "") -> Vector3: return furniture.bed_side(id)
func bed_rest(id: String = "") -> Transform3D: return furniture.bed_rest(id)
func on_mattress(point: Vector3, id: String = "") -> bool: return furniture.on_mattress(point, id)

func local_waypoint(from: Vector3, to: Vector3) -> Vector3:
	return _local_waypoint(from,to,null)

func local_waypoint_for(actor:CharacterBody3D, from:Vector3, to:Vector3) -> Vector3:
	return _local_waypoint(from,to,actor)

func _local_waypoint(from:Vector3,to:Vector3,actor:CharacterBody3D) -> Vector3:
	return STAIRS.waypoint(self, from, to, stair_path, loft_y, 0.0, .04, _flat_waypoint.bind(actor))

func _clear(a: Vector3, b: Vector3, actor:CharacterBody3D=null, peers:=true) -> bool:
	# Floor changes must use the staircase, never a direct diagonal through the loft.
	if absf(a.y - b.y) > .3: return false
	var shape := CapsuleShape3D.new()
	shape.radius = float(actor.profile.radius) if actor != null else .34
	shape.height = float(actor.profile.clearance) if actor != null else 1.45
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 3 if actor != null and peers else 1
	if actor != null: query.exclude = [actor.get_rid()]
	query.margin = .005
	query.transform.origin = a + Vector3.UP * (shape.height * .5 + .055)
	query.motion = b - a
	var space := get_world_3d().direct_space_state
	return ROUTE_GRAPH.sweep(space, query)

func _flat_waypoint(from: Vector3, to: Vector3, actor:CharacterBody3D=null) -> Vector3:
	if actor != null: return _actor_waypoint(actor,from,to)
	# Reuse routes while traversing a clear leg rather than rebuilding per physics tick.
	var now := Time.get_ticks_msec()
	for item in _route_cache:
		if now - int(item.time) < 2000 and to.distance_squared_to(item.goal) < .01 and from.distance_squared_to(item.start) < .36 and from.distance_squared_to(item.next) > .04:
			return item.next
	var next := _find_flat_waypoint(from, to)
	# Replace the completed leg. Keeping older entries can reactivate one after
	# walking 20 cm beyond it, repeatedly reversing the moving character.
	_route_cache.assign([{"time": now, "goal": to, "start": from, "next": next}])
	return next

func _find_flat_waypoint(from: Vector3, to: Vector3, actor:CharacterBody3D=null, peers:=true) -> Vector3:
	if _clear(from, to, actor, peers): return to
	var upper := to_local(from).y >= loft_y - .25
	var key := "loft_walk_points" if upper else "ground_walk_points"
	var points: Array[Vector3] = [from, to]
	for p: Vector3 in furniture.get_meta(key, []): points.append(to_global(p))
	return ROUTE_GRAPH.next(points, _clear.bind(actor, peers))

## Per-actor, short-lived leg cache. Live sweeps prevent cached paths crossing a pony
## who just entered a leg; the source point graph still owns all route alternatives.
func _actor_waypoint(actor:CharacterBody3D,from:Vector3,to:Vector3) -> Vector3:
	var now:=Time.get_ticks_msec()
	var id:=actor.get_instance_id()
	for item:Dictionary in _actor_routes:
		if int(item.actor)!=id or now-int(item.time)>=500 or to.distance_squared_to(item.goal)>=.01:continue
		if from.distance_squared_to(item.start)<.0001 and (item.next as Vector3).distance_squared_to(item.start)<.0001:return from
		if from.distance_squared_to(item.start)<.36 and from.distance_squared_to(item.next)>.04 and _clear(from,item.next,actor,not bool(item.get("peer_wait",false))):return item.next
	var next:=_find_flat_waypoint(from,to,actor)
	var peer_wait:=next.distance_squared_to(from)<.0001
	# A temporary peer can occupy the only aisle. Keep the physical static route;
	# native neighbour avoidance stops short and HouseTravel requests a courtesy move.
	if peer_wait:next=_find_flat_waypoint(from,to,actor,false)
	for i in range(_actor_routes.size()-1,-1,-1):
		var old:Dictionary=_actor_routes[i]
		if now-int(old.time)>=500 or (int(old.actor)==id and from.distance_squared_to(old.start)<.01):_actor_routes.remove_at(i)
	_actor_routes.append({"actor":id,"time":now,"goal":to,"start":from,"next":next,"peer_wait":peer_wait})
	if _actor_routes.size()>24:_actor_routes.pop_front()
	return next
