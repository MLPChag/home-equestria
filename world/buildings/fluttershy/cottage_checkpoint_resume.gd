extends RefCounted
## The October 23 room fit moved 3.75 m inside the original exterior. Old checkpoint
## feet may stand in the remaining shell cavity, or above the displaced loft floor.
## Only a successfully restored, unmarked checkpoint can request this loading-only repair.
const REVISION := 1
const OLD_FIT := Transform3D(Basis(Vector3(0, 0, -.85), Vector3(0, .85, 0), Vector3(.85, 0, 0)), Vector3(-1.2781, .816, .7203))
const CURRENT_FIT := Transform3D(OLD_FIT.basis, Vector3(-1.2781, .816, 4.4703))
const FLOOR_DATA := "res://world/buildings/fluttershy/old_layout_floors.json"
const OLD_SOURCE_SHA256 := "06998b34a160ee8986275d026df61f69b5a22bad37bc30d7cc7902b68118b679"
# The same frozen room-scale capsule/head query used by the terrain resume repair.
const RESUME_CLEARANCE := preload("res://world/terrain/player_repair_resume.gd")
const FOOT_TOLERANCE := .08
static var _certificate: Dictionary = {}

## False is a safe no-op, not a cancelled load. No checkpoint file is edited.
static func repair_loaded_position(game: Node) -> bool:
	if game == null or not game.is_inside_tree(): return false
	var saves := game.get("saves") as Node
	if not is_instance_valid(saves): return false
	var saved: Vector3 = saves.get("pending_cottage_feet")
	if not saved.is_finite(): return false
	var player := game.get("player") as Node3D
	if player == null or not player.is_inside_tree(): return false
	var xr: bool = game.get("xr_active") == true
	var body := (player.get_node_or_null("Body") if xr else player) as CharacterBody3D
	if body == null or body.is_physics_processing() or not body.global_transform.is_finite(): return false
	if body.get("seat") != null or body.get("flying") == true: return false
	var wing: Variant = body.get("wing_flight")
	if wing != null and (wing.active or wing.resume_pending): return false
	var camera := game.call("_find_camera", player) as Camera3D
	if camera == null or not camera.global_transform.is_finite(): return false
	var driver := body.get("form_driver") as Node
	var motion := body
	if is_instance_valid(driver):
		motion = driver.get("avatar") as CharacterBody3D
		if motion == null or not motion.global_transform.is_finite(): return false
		var flight: Variant = motion.get("flight")
		if flight != null and flight.active(): return false
	var feet := body.global_position
	if xr or (driver == null and body.get("headset_view") != true):
		feet.x = camera.global_position.x; feet.z = camera.global_position.z
	# TitleVista visits a scenic pose first. Keep the request until Continue has
	# restored the saved feet; never repair or consume the scenic camera's position.
	if feet.distance_to(saved) > .001: return false
	var cottage := _loaded_cottage(game.get_tree())
	if cottage == null: return false
	var local := OLD_FIT.affine_inverse() * cottage.to_local(feet)
	if not _on_old_floor(local):
		saves.pending_cottage_feet = Vector3.INF
		return false
	var solid := cottage.get_node_or_null("InteriorSolid") as StaticBody3D
	var floor := cottage.get_node_or_null("FittedFloor/FloorSolid") as StaticBody3D
	if solid == null or floor == null: return false
	var space := body.get_world_3d().direct_space_state
	var exclude: Array[RID] = [body.get_rid()]
	if motion != body: exclude.append(motion.get_rid())
	var current := _support(feet, space, exclude)
	if not current.is_empty():
		# The generic fitted foundation also covers the confirmed inaccessible
		# cavity. Only the actual room/foyer boards establish a valid current room.
		if current.collider == solid and _clear(body, motion, camera, driver, xr, Vector3.ZERO, space, exclude):
			saves.pending_cottage_feet = Vector3.INF
			return false
		# Another real floor/prop/house is never evidence of this old-room defect.
		if current.collider != solid and current.collider != floor: return false
	var shifted := cottage.to_global(CURRENT_FIT * local)
	var support := _support(shifted, space, exclude)
	if support.is_empty() or support.collider != solid: return false
	var normal: Vector3 = support.normal
	if not normal.is_finite() or normal.dot(Vector3.UP) < cos(body.floor_max_angle): return false
	# Same small settled-floor clearance as ordinary restores; no escape search,
	# extra collision tolerance or change to body dimensions.
	var destination: Vector3 = support.position + Vector3.UP * .04
	var delta := destination - feet
	if not _clear(body, motion, camera, driver, xr, delta, space, exclude): return false
	body.global_position += delta
	body.velocity = Vector3.ZERO
	body.reset_physics_interpolation()
	if is_instance_valid(driver): driver.call("_reset_at_rig")
	saves.pending_cottage_feet = Vector3.INF
	print("[player] restored legacy cottage room at %s into current room %s" % [feet, destination])
	return true

static func _clear(body: CharacterBody3D, motion: CharacterBody3D, camera: Camera3D, driver: Node, xr: bool, delta: Vector3, space: PhysicsDirectSpaceState3D, exclude: Array[RID]) -> bool:
	if xr: return RESUME_CLEARANCE._xr_clear(body, camera, delta, space, exclude)
	var target := motion.global_transform
	# The frozen pony avatar can still be at the scenic title pose.
	target.origin = body.global_position + delta
	if is_instance_valid(driver): target.basis = Basis(Vector3.UP, body.global_rotation.y)
	return not motion.test_move(target, Vector3.ZERO, null, .001, true)

static func _support(feet: Vector3, space: PhysicsDirectSpaceState3D, exclude: Array[RID]) -> Dictionary:
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(feet + Vector3.UP * .12, feet - Vector3.UP * .16, 1, exclude))

## Save restore can discard positions outside the immutable old footprint even when
## the cottage is not streamed. This never reads current geometry or changes a player.
static func is_legacy_floor(at: Vector3) -> bool:
	if not at.is_finite() or not _load_certificate(): return false
	return _on_old_floor(OLD_FIT.affine_inverse() * (_expected_transform().affine_inverse() * at))

static func _load_certificate() -> bool:
	if _certificate.is_empty():
		var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(FLOOR_DATA))
		if not value is Dictionary or value.get("source_sha256") != OLD_SOURCE_SHA256 or value.get("revision") != 0: return false
		_certificate = value
	return true

static func _expected_transform() -> Transform3D:
	var origin: Array = _certificate.position
	return Transform3D(Basis(Vector3.UP, float(_certificate.yaw)), Vector3(origin[0], origin[1], origin[2]))

static func _loaded_cottage(tree: SceneTree) -> Node3D:
	if not _load_certificate(): return null
	var expected := _expected_transform()
	for home: Node in tree.get_nodes_in_group("house_interiors"):
		if home.get_script() == null or home.get_script().resource_path != "res://world/buildings/fluttershy/cottage_home.gd": continue
		var cottage := home.get_parent().get_parent() as Node3D
		if cottage == null or cottage.get("complete") != true or not cottage.global_transform.is_equal_approx(expected): return null
		var room := cottage.get_node_or_null("ShowInterior") as Node3D
		if room == null or room.scene_file_path != "res://world/buildings/fluttershy/interior/cottage_interior.glb" or not room.transform.is_equal_approx(CURRENT_FIT): return null
		return cottage
	return null

static func _on_old_floor(local: Vector3) -> bool:
	if not local.is_finite(): return false
	for floor: Dictionary in _certificate.floors:
		if absf(local.y - float(floor.height)) * .85 > FOOT_TOLERANCE: continue
		for triangle: Array in floor.triangles:
			var polygon := PackedVector2Array()
			for vertex: Array in triangle: polygon.append(Vector2(vertex[0], vertex[2]))
			if Geometry2D.is_point_in_polygon(Vector2(local.x, local.z), polygon): return true
	return false
