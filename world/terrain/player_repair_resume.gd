extends RefCounted
## October 23's two published ground repairs can cover feet saved on the old surface.
## Called only under the loading cover, after collision arrives and before body physics resumes.
## The ordinary 30 m under-world rescue remains separate and unchanged.
const HOUSE := preload("res://world/buildings/house_interior.gd")
const DATA := "res://world/terrain/repair_20261023/"
const OLD_SURFACE_TOLERANCE := 0.35
const CURRENT_SURFACE_TOLERANCE := 0.04
static var _patches: Array = []
static var _loaded := false
static var _samples: Dictionary = {}

## True only when an eligible frozen rig was moved. False is a normal no-op, not cancellation.
## No save file is changed. Repeated loading/title-Continue calls are harmless after placement.
static func repair_loaded_position(game: Node) -> bool:
	if game == null or not game.is_inside_tree() or not is_instance_valid(WorldTerrain.instance): return false
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
	# Saves use the head's X/Z for human rigs and the rig's X/Z for pony/seated rigs.
	if xr or (driver == null and body.get("headset_view") != true):
		feet.x = camera.global_position.x; feet.z = camera.global_position.z
	var heights := _certified_heights(feet, WorldTerrain.instance.half_res)
	if not heights.is_finite() or feet.y >= heights.z - 0.3: return false
	var covered := heights.z-heights.x > 0.3 and absf(feet.y-heights.x) <= OLD_SURFACE_TOLERANCE
	if not covered:
		# Checkpoints do not store the terrain tier. A save made on the other
		# original grid still qualifies only where that published repair raised
		# its surface and the currently loaded final grid actually covers it.
		var other := _certified_heights(feet, not WorldTerrain.instance.half_res)
		covered = other.is_finite() and other.z-other.x > 0.3 and heights.z-other.x > 0.3 \
			and absf(feet.y-other.x) <= OLD_SURFACE_TOLERANCE
	if not covered: return false
	var current: float = WorldTerrain.instance.height_at(feet)
	if not is_finite(current) or absf(current - heights.y) > CURRENT_SURFACE_TOLERANCE: return false
	if HOUSE.at(game.get_tree(), feet) != null: return false
	var space := body.get_world_3d().direct_space_state
	var exclude: Array[RID] = [body.get_rid()]
	if motion != body: exclude.append(motion.get_rid())
	# A real cellar/bridge floor under the saved feet wins over the repair certificate.
	var old_floor := PhysicsRayQueryParameters3D.create(feet + Vector3.UP * 0.1, feet - Vector3.UP * 0.25, 1, exclude)
	if not space.intersect_ray(old_floor).is_empty(): return false
	var original := _terrain_support(feet, space, exclude)
	if original.is_empty(): return false
	var candidates: Array[Vector3] = [feet]
	var original_normal: Vector3 = original.normal
	if original_normal.dot(Vector3.UP) < cos(body.floor_max_angle):
		# A repaired steep bank can cover an old walkable floor. Only this case
		# may move sideways: at most two metres within the certified raised patch.
		# A blocked or missing vertical destination never starts an escape search.
		candidates.clear()
		for radius: float in [0.5, 1.0, 1.5, 2.0]:
			for direction in 8:
				var angle := TAU * float(direction) / 8.0
				candidates.append(feet + Vector3(sin(angle), 0, cos(angle)) * radius)
	for candidate: Vector3 in candidates:
		var hit := original if candidate == feet else _terrain_support(candidate, space, exclude)
		if hit.is_empty(): continue
		var support: Vector3 = hit.position
		var normal: Vector3 = hit.normal
		if normal.dot(Vector3.UP) < cos(body.floor_max_angle): continue
		if candidate != feet:
			var nearby := _certified_heights(candidate, WorldTerrain.instance.half_res)
			if not nearby.is_finite() or nearby.z - nearby.x <= 0.3: continue
			if HOUSE.at(game.get_tree(), support) != null: continue
		for clearance: float in [0.08, 0.16, 0.24, 0.32, 0.4]:
			var shift := support + Vector3.UP * clearance - feet
			var target := motion.global_transform
			# A parked pony can lag a title/save teleport until its first drive tick.
			target.origin = body.global_position + shift
			if motion != body: target.basis = Basis(Vector3.UP, body.global_rotation.y)
			if xr:
				if not _xr_clear(body, camera, shift, space, exclude): continue
			elif motion.test_move(target, Vector3.ZERO, null, 0.001, true):
				continue
			if candidate != feet:
				# Sweep at the clear destination height; never jump through a fence
				# or wall while using the small bank-only lateral correction.
				var from := target
				var sideways := Vector3(shift.x, 0, shift.z)
				from.origin -= sideways
				if xr:
					if not _xr_clear(body, camera, shift-sideways, space, exclude, sideways): continue
				elif motion.test_move(from, sideways, null, 0.001, true): continue
			body.global_position += shift
			body.velocity = Vector3.ZERO
			body.reset_physics_interpolation()
			if is_instance_valid(driver): driver.call("_reset_at_rig")
			print("[player] restored old terrain surface at %s onto repaired ground %s" % [feet, support])
			return true
	return false


static func _terrain_support(at: Vector3, space: PhysicsDirectSpaceState3D, exclude: Array[RID]) -> Dictionary:
	var terrain := WorldTerrain.instance
	var heights := _certified_heights(at, terrain.half_res)
	if not heights.is_finite(): return {}
	var current: float = terrain.height_at(at)
	if not is_finite(current) or absf(current-heights.y) > CURRENT_SURFACE_TOLERANCE: return {}
	var point := Vector3(at.x, heights.z, at.z)
	var ray := PhysicsRayQueryParameters3D.create(point+Vector3.UP*0.6, point-Vector3.UP*0.6, 1, exclude)
	var hit := space.intersect_ray(ray)
	if hit.is_empty() or hit.rid != terrain.terrain.get_collision().get_rid(): return {}
	var support: Vector3 = hit.position
	var normal: Vector3 = hit.normal
	if not support.is_finite() or not normal.is_finite() or absf(support.y-heights.z) > CURRENT_SURFACE_TOLERANCE: return {}
	return hit


## The frozen XR collider has not yet followed the current room-scale head pose. Query the
## same capsule/head shapes the first live body step will use, without touching tracked poses.
static func _xr_clear(body: CharacterBody3D, camera: Camera3D, shift: Vector3, space: PhysicsDirectSpaceState3D, exclude: Array[RID], travel := Vector3.ZERO) -> bool:
	if body == null or camera == null or not shift.is_finite() or not travel.is_finite(): return false
	if not body.global_transform.is_finite() or not camera.global_transform.is_finite(): return false
	var collider := body.get_node_or_null("BodyCollider") as CollisionShape3D
	var head := body.get_node_or_null("HeadCollider") as CollisionShape3D
	if collider == null or head == null or not collider.shape is CapsuleShape3D or head.shape == null: return false
	var capsule := collider.shape.duplicate() as CapsuleShape3D
	var local_head := body.to_local(camera.global_position)
	if not local_head.is_finite(): return false
	capsule.height = clampf(local_head.y, 0.6, 2.2)
	var transform := body.global_transform
	transform.origin += shift
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = body.collision_mask
	query.exclude = exclude
	query.margin = 0.001
	query.motion = travel
	query.shape = capsule
	query.transform = transform * Transform3D(Basis.IDENTITY, Vector3(local_head.x, capsule.height * 0.5, local_head.z))
	if not space.intersect_shape(query, 1).is_empty(): return false
	if travel != Vector3.ZERO and space.cast_motion(query)[0] < 1.0: return false
	query.shape = head.shape
	query.transform = camera.global_transform
	query.transform.origin += shift
	if not space.intersect_shape(query, 1).is_empty(): return false
	return travel == Vector3.ZERO or space.cast_motion(query)[0] >= 1.0


## Old physical floor, current Terrain3D height lookup, current physical floor.
static func _certified_heights(at: Vector3, half: bool) -> Vector3:
	if not at.is_finite(): return Vector3.INF
	if not _loaded:
		_loaded = true
		var document: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA + "certificate.json"))
		if document is Dictionary and document.get("version") == 1 and document.get("patches") is Array:
			_patches = document.patches
	var spacing := 2 if half else 1
	for patch: Dictionary in _patches:
		if int(patch.spacing) != spacing: continue
		var origin := Vector2(float(patch.origin[0]), float(patch.origin[1]))
		var size := Vector2i(int(patch.size[0]), int(patch.size[1]))
		var local := (Vector2(at.x, at.z) - origin) / float(spacing)
		if local.x < 0.0 or local.y < 0.0 or local.x >= size.x - 1 or local.y >= size.y - 1: continue
		var old := _height(str(patch.old), local, size, spacing, true)
		var current := _height(str(patch.new), local, size, spacing)
		var floor_height := _height(str(patch.new), local, size, spacing, true)
		return Vector3(old, current, floor_height)
	return Vector3.INF


## Same bilinear height lookup and near-vertex shortcut as the shipped Terrain3D 1.0.2.
static func _height(file: String, at: Vector2, size: Vector2i, spacing: int, physical := false) -> float:
	if not _samples.has(file):
		var bytes := FileAccess.get_file_as_bytes(DATA + file)
		_samples[file] = bytes.to_float32_array() if bytes.size() == size.x * size.y * 4 else PackedFloat32Array()
	var values: PackedFloat32Array = _samples[file]
	if values.size() != size.x * size.y: return NAN
	var x := floori(at.x); var z := floori(at.y)
	var fx := at.x - x; var fz := at.y - z
	var h00 := values[z * size.x + x]; var h10 := values[z * size.x + x + 1]
	var h01 := values[(z + 1) * size.x + x]; var h11 := values[(z + 1) * size.x + x + 1]
	if physical:
		# Measured against the actual shipped Terrain3D/Jolt heightfield: its
		# world-space diagonal joins (0,0) to (1,1). Saved feet stand on these
		# triangles, not on the bilinear height API's surface between vertices.
		return h00 + (h10-h00)*fx + (h11-h10)*fz if fx > fz else h00 + (h11-h01)*fx + (h01-h00)*fz
	var rounded := at.round()
	if (at - rounded).length_squared() * spacing * spacing < 0.0001:
		# Terrain3D's shortcut passes the original position to get_pixel(), which
		# truncates the region-local pixel even immediately below the rounded vertex.
		return values[floori(at.y) * size.x + floori(at.x)]
	return lerpf(lerpf(h00,h10,fx),lerpf(h01,h11,fx),fz)
