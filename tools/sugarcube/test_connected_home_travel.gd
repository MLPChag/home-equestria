extends SceneTree
## Actual HouseTravel.update and tower adapter; record motor dispatch only.
## Explicit fixture poses represent doorway handoffs, not physical walking proof.
const TOWER := preload("res://world/buildings/sugarcube/tower_home.gd")
class Trip extends "res://world/characters/navigation/house_travel.gd":
	var walked_home: Node3D
	var walked_goal := Vector3.INF
	func walk(_nav: Node, destination: Vector3, house: Node3D = null, _final := Vector3.INF, _line_from := Vector3.INF) -> void:
		walked_home = house; walked_goal = destination
class Profile extends Resource:
	var radius := .3
	var clearance := 1.0
class Pony extends Node3D:
	enum SimTier { HERO }
	var profile: Resource = Profile.new()
	func set_sim_tier(_tier: int) -> void: pass
class Door extends Node:
	var requests := 0
	func request_passage(_pony: Node) -> bool: requests += 1; return true
	func release_passage(_pony: Node) -> void: pass
class Bakery extends Node3D:
	var doorway := Vector3(0, 0, -5)
	var door_width := 2.0
	var entrance := Door.new()
	func _ready() -> void: add_child(entrance); add_to_group("house_interiors")
	func contains(point: Vector3, _lighting := false) -> bool:
		var p := to_local(point)
		return absf(p.y) < .2 and absf(p.x) < 5 and absf(p.z) < 5
	func _reach_squared() -> float: return 100.0
	func inside() -> Vector3: return to_global(Vector3(0,0,-4))
	func outside() -> Vector3: return to_global(Vector3(0,0,-6))
	func door() -> Node: return entrance
	func fits(_profile: Resource) -> bool: return true
	func local_waypoint(_from: Vector3, to: Vector3) -> Vector3: return to
class Nav extends Node:
	enum State { WAITING, MOVING, ARRIVED }
	signal arrived
	var pony: Node3D
	var _live_goal := Vector3.ZERO
	var _journey_goal := Vector3.INF
	var _moving_goal := false
	var command_target_speed := 0.0
	var arrival_distance := .25
	var _wandering := false
	var state := State.MOVING
	var reason := ""
	var target := Vector3.INF
	var _needs_path := false
	var _has_target := true
	var _journey_via: Array = []
	var _approaching_player := false
	var _stuck_time := 0.0
	var path := PackedVector3Array()
	func _halt() -> void: pass
	func _cancel_queries() -> void: pass
	func _reset_lookahead() -> void: pass
	func _fail(message: String) -> void: reason = message
var checks := 0
var failures := 0
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures += 1; print("CONNECTED_HOME_FAIL ", label)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var building := Node3D.new(); root.add_child(building)
	var bakery := Bakery.new(); bakery.name = "HouseInterior"; building.add_child(bakery)
	var tower := TOWER.new(); tower.name = "TowerHome"; tower.floor_y = 0
	tower.room_floor = 6; tower.room_ceiling = 9; tower.room_bounds = Rect2(-2,-2,4,4)
	tower.stair_path.assign([Vector3(2,0,0), Vector3(2,3,0), Vector3(0,6,0)])
	building.add_child(tower)
	var other := Bakery.new(); other.position.x = 20; root.add_child(other)
	var pony := Pony.new(); root.add_child(pony)
	var nav := Nav.new(); nav.pony = pony; root.add_child(nav)
	var trip := Trip.new()
	pony.global_position = Vector3.ZERO; nav._live_goal = tower.center()
	check(trip.update(nav), "bakery to tower handled")
	check(not trip.active() and trip.walked_home == tower, "bakery to tower uses internal stair route, not an exit")
	check(trip.walked_goal.is_equal_approx(tower.to_global(tower.stair_path[0])), "internal ascent starts with authored ground approach")
	trip.clear(pony); trip = Trip.new()
	pony.profile.radius = 1.0
	trip.update(nav)
	check(not trip.active() and trip.walked_home == null and nav.reason.contains("cannot fit"), "connected stairs retain actual profile fit restriction")
	pony.profile.radius = .3
	trip.clear(pony); trip = Trip.new()
	pony.global_position = bakery.outside(); nav._live_goal = tower.center()
	check(trip.update(nav) and trip.active() and trip.entering, "outside tower trip still owns real exterior doorway")
	check(trip.phase == trip.Phase.CROSS, "outside entry requests passage before crossing")
	pony.global_position = bakery.inside()
	trip.update(nav)
	check(not trip.active() and trip.walked_home == tower, "completed bakery doorway hands off to tower route without exiting again")
	trip.clear(pony); trip = Trip.new()
	pony.global_position = tower.center(); nav._live_goal = Vector3(1,0,1)
	trip.update(nav)
	check(not trip.active() and trip.walked_home == tower, "tower to bakery uses same internal descent")
	pony.global_position = Vector3(2,0,0); trip.update(nav)
	check(trip.walked_home == bakery, "ground-floor handoff resumes ordinary bakery route")
	trip.clear(pony); trip = Trip.new()
	pony.global_position = Vector3.ZERO; nav._live_goal = other.inside()
	trip.update(nav)
	check(trip.active() and not trip.entering and trip.home == bakery, "different building retains exterior exit protocol")
	trip.clear(pony)
	building.queue_free(); other.queue_free(); pony.queue_free(); nav.queue_free()
	await process_frame
	print("CONNECTED_HOME_", "PASS" if failures == 0 else "FAIL", " checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
