extends "res://world/buildings/authored_home.gd"
const MAX_GUESTS := 3
const SEAT := preload("res://world/life/seat.gd")
var _visits: Dictionary = {}
var _occupants: Dictionary = {}
var _occupants_until := 0
var _tower_home: Node3D

func _staff(pony: Node) -> bool:
	var identity: Resource = pony.get("identity")
	return identity != null and str(identity.get("id")) in ["pinkie_pie", "mr_cake", "mrs_cake", "carrot_cake", "cup_cake"]

## Count inbound reservations as well as bodies: a full shop never attracts a porch crowd.
## Short leases refresh while travelling; interruption/despawn cannot reserve a place forever.
func request_visit(pony: Node3D) -> bool:
	if not is_instance_valid(pony): return false
	var now := Time.get_ticks_msec()
	for key: int in _visits.keys():
		var entry: Dictionary = _visits[key]
		var actor: Node3D = entry.actor.get_ref()
		if actor == null or (int(entry.until) < now and not contains(actor.global_position)): _visits.erase(key)
	if _staff(pony): return true
	if now >= _occupants_until:
		_occupants.clear(); _occupants_until = now + 500
		for actor: Node3D in get_tree().get_nodes_in_group("ai_characters"):
			if contains(actor.global_position) and not _staff(actor): _occupants[actor.get_instance_id()] = true
	var guests: Dictionary = _occupants.duplicate()
	for key: int in _visits: guests[key] = true
	var key := pony.get_instance_id()
	if not guests.has(key) and guests.size() >= MAX_GUESTS: return false
	var slot := int(_visits.get(key, {}).get("slot", -1))
	if slot < 0:
		var occupied: Array = _visits.values().map(func(entry: Dictionary) -> int: return int(entry.slot))
		for candidate in MAX_GUESTS:
			if candidate not in occupied: slot = candidate; break
	_visits[key] = {"actor": weakref(pony), "until": now + 5000, "slot": maxi(0, slot)}
	return true

func release_visit(pony: Node) -> void:
	if is_instance_valid(pony) and not contains(pony.global_position): _visits.erase(pony.get_instance_id())
	_occupants_until = 0

## Guest standing spots flank the entrance aisle; never idle at the crossing destination.
func visit_point(pony: Node3D) -> Vector3:
	var index := int(_visits.get(pony.get_instance_id(), {}).get("slot", 0))
	# The old middle spot (.2, .7) overlapped the doorway's inside endpoint.
	# A guest parked there prevented the next guest from completing the crossing.
	return to_global([Vector3(-1.5, .9, .8), Vector3(-1.5, .9, 2.3), Vector3(1.6, .9, .8)][index] / 14.0)

## Commercial room uses the existing doorway and indoor movement contract, without
## residential furnishing or assignment. Geometry and furniture are baked offline.
func _ready() -> void:
	super._ready()
	_setup_bakery_range.call_deferred()
	_floor_seating.call_deferred()
	_keep_far_shell.call_deferred()
	_counter_top.call_deferred()

## The landmark's outside had a hard 250 m cutoff with no far stand-in, so from across town
## Sugarcube Corner simply vanished (dev 2026-10-17). The shell, foundation and ramp now always
## draw (one mesh each); small door and stair pieces stop at SMALL_PARTS_RANGE.
const SMALL_PARTS_RANGE := 450.0
func _keep_far_shell() -> void:
	var site := get_parent()
	if site == null: return
	for node: Node in site.find_children("*", "GeometryInstance3D", true, false):
		var mesh := node as GeometryInstance3D
		if not is_equal_approx(mesh.visibility_range_end, 250.0): continue
		var shell: bool = mesh.name in ["Exterior", "InsetBakeryFoundation", "StoneRamp"]
		mesh.visibility_range_end = 0.0 if shell else SMALL_PARTS_RANGE

## dev 2026-10-18: "remove the gray slab on the counter at sugarcube corner and put the food
## directly on the actual table". The baked room laid one flat board (CreamDisplayTop) over both
## bakery counters, a little above their own tops; it goes, and each counter's collision rises
## from 0.94 m to its real top, COUNTER_TOP over the shop floor, so the stock (food_world.gd
## PLACEMENTS) stands on the counters themselves.
const ROOM_FLOOR := 0.90   # bakery_room.gd FLOOR
const COUNTER_TOP := 1.05
## The baked room keeps these as BakeryRoom children (the build's DisplayComposition is flattened
## and the second counter's body lost its name): the board by name, the counters by their box.
const COUNTER_BOX := Vector3(3.12, 0.94, 1.24)
func _counter_top() -> void:
	var room := get_parent().get_node_or_null("BakeryRoom")
	if room == null: return
	for child: Node in room.get_children():
		if str(child.name).begins_with("CreamDisplayTop"):
			room.remove_child(child); child.queue_free()
			continue
		var body := child as StaticBody3D
		if body == null: continue
		for shape_node: Node in body.get_children():
			var holder := shape_node as CollisionShape3D
			if holder == null or not holder.shape is BoxShape3D: continue
			var size := (holder.shape as BoxShape3D).size
			if not size.is_equal_approx(COUNTER_BOX): continue
			var bottom := body.position.y + holder.position.y - size.y * 0.5
			var box := (holder.shape as BoxShape3D).duplicate() as BoxShape3D
			box.size.y = ROOM_FLOOR + COUNTER_TOP - bottom
			holder.shape = box
			holder.position.y = bottom + box.size.y * 0.5 - body.position.y

## Keep one existing chair at each table; removed chairs become reserved floor places.
## Apply to the installed room, so the pending tower candidate is not needed.
func _floor_seating() -> void:
	var room := get_parent().get_node_or_null("BakeryRoom")
	if room == null: return
	for index in 8:
		if index % 4 == 0: continue
		var chair := room.get_node_or_null("CafeChair%d" % index) as Node3D
		if chair == null: continue
		var seat := SEAT.new()
		seat.name = "PonyFloorSeat%d" % index
		seat.transform = chair.transform
		seat.for_player = false
		seat.floor_sit = true
		room.add_child(seat)
		room.remove_child(chair)
		chair.queue_free()
## Keep the named destination in the entrance aisle, clear of counter and chairs.
func _setup_bakery_range() -> void:
	# Both authored interiors share the existing quality/door range policy.
	for room_name: String in ["BakeryRoom","TowerRoom"]:
		var room := get_parent().get_node_or_null(room_name)
		if room == null: continue
		for node: GeometryInstance3D in room.find_children("*", "GeometryInstance3D", true, false):
			if node.name != "InsetBakeryFoundation": _range_originals[node] = node.visibility_range_end
	var quality := get_node_or_null("/root/Quality")
	if quality != null and not quality.preset_changed.is_connected(_refresh_bakery_range): quality.preset_changed.connect(_refresh_bakery_range)
	_refresh_bakery_range()
	var timer := get_node_or_null("BakeryRangeTimer") as Timer
	if timer == null:
		timer = Timer.new(); timer.name = "BakeryRangeTimer"; timer.wait_time = 0.5; timer.autostart = true; add_child(timer)
	if not timer.timeout.is_connected(_tend_interior_range): timer.timeout.connect(_tend_interior_range)
func _refresh_bakery_range(_index: int = -1) -> void:
	var quality := get_node_or_null("/root/Quality")
	_range_cap = float(quality.get_value("interior_range", 0.0)) if quality != null else 0.0
	_apply_bakery_range()
func _apply_bakery_range(force := true) -> void:
	var leaf := door()
	var open := _range_cap <= 0.0 or (leaf != null and leaf.has_method("opening_angle") and absf(float(leaf.opening_angle())) > 0.3)
	if force or open != _range_door_open: _set_interior_range(open)
func _tend_interior_range() -> void: _apply_bakery_range(false)

## The base local-height allowance scales with the 14x shell. Keep actual rising
## tower travel owned by its stair adapter, while the shop floor remains commercial.
func contains(at: Vector3, lighting := false) -> bool:
	if not super.contains(at,lighting): return false
	if lighting or (to_local(at).y-floor_y)*global_basis.y.length() <= .15: return true
	if not is_instance_valid(_tower_home): _tower_home = get_parent().get_node_or_null("TowerHome") as Node3D
	return not (is_instance_valid(_tower_home) and _tower_home.contains(at))

## The commercial floor remains one room, including the staff side of the counter.
func local_waypoint(from: Vector3, to: Vector3) -> Vector3:
	if not is_instance_valid(_tower_home): _tower_home = get_parent().get_node_or_null("TowerHome") as Node3D
	if is_instance_valid(_tower_home):
		var next: Vector3 = _tower_home.ground_waypoint(from, to)
		if next.is_finite(): return next
	return super.local_waypoint(from, to)

func _init() -> void:
	home_kind = "sugarcube_bakery"
