extends RefCounted
## Physical placement shares inventory loans: one purchased unit, one saved pose.
## No independent save file or process loop. Input asks for an offer; streaming restores it.
const RULES := preload("res://world/housing/furnishing_rules.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const LAMP := preload("res://world/props/lamps/kit_lamp.gd")
const ITEM_LAYER := 1 << 17
const REACH := 2.5

static func eligible(item: Node) -> bool:
	return is_instance_valid(item) and RULES.has(str(item.get_meta("item_id", "")))

static func home(tree: SceneTree, id: String = "") -> Node3D:
	for candidate: Node in tree.get_nodes_in_group("house_interiors"):
		if not candidate is Node3D or not candidate.has_method("place_id"): continue
		if not id.is_empty():
			if str(candidate.place_id()) == id: return candidate
		elif str(candidate.get_meta("reserved_for", "")) == "player": return candidate
	return null

static func shape(item: Node) -> CollisionShape3D:
	for child: Node in item.get_children():
		if child is CollisionShape3D and child.shape != null and not child.disabled: return child
	return null

static func offer(ui: Node3D, side: String) -> Dictionary:
	var item: RigidBody3D = ui.held.get(side)
	if not eligible(item) or ui.get_tree().paused: return {}
	if not is_instance_valid(ui.camera) or not ui.camera.global_transform.is_finite(): return {}
	var owned_home := home(ui.get_tree())
	if owned_home == null or item.global_position.distance_to(owned_home.global_position) > 35.0: return {}
	var holder := shape(item)
	if holder == null: return {}
	var id := str(item.get_meta("item_id", ""))
	var excluded: Array[RID] = [item.get_rid()]
	if ui.player_body is CollisionObject3D: excluded.append(ui.player_body.get_rid())
	for other: Variant in ui.held.values():
		if is_instance_valid(other) and other is CollisionObject3D: excluded.append(other.get_rid())
	var space := ui.get_world_3d().direct_space_state
	var hit: Dictionary = {}
	if side == "desktop":
		hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(ui.camera.global_position, ui.camera.global_position - ui.camera.global_basis.z * REACH, 1, excluded))
	elif RULES.wall(id):
		# A held frame faces into the room (+Z); bring its back within 35 cm of a wall.
		var center: Vector3 = item.global_transform * holder.transform * holder.shape.get_debug_mesh().get_aabb().get_center()
		var back: Vector3 = -item.global_basis.z.normalized()
		hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(center, center + back * .55, 1, excluded))
	else:
		hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(item.global_position + Vector3.UP * .12, item.global_position + Vector3.DOWN * .3, 1, excluded))
	if hit.is_empty(): return {}
	return surface_offer(ui, item, owned_home, hit, side, excluded)

static func surface_offer(ui: Node3D, item: RigidBody3D, owned_home: Node3D, hit: Dictionary, side: String, excluded: Array[RID]) -> Dictionary:
	var holder := shape(item)
	if holder == null or not eligible(item) or not is_instance_valid(owned_home): return {}
	var id := str(item.get_meta("item_id", ""))
	var normal: Vector3 = hit.get("normal", Vector3.ZERO)
	var point: Vector3 = hit.get("position", Vector3.INF)
	if not point.is_finite() or not normal.is_finite(): return {}
	var pose := Transform3D.IDENTITY
	var local_box: AABB = holder.transform * holder.shape.get_debug_mesh().get_aabb()
	if RULES.wall(id):
		if absf(normal.y) > .2: return {}
		normal.y = 0.0; normal = normal.normalized()
		pose.basis = Basis(Vector3.UP.cross(normal), Vector3.UP, normal)
		pose.origin = point + normal * (-local_box.position.z + .012) - Vector3.UP * local_box.get_center().y
	else:
		if normal.y < .9: return {}
		var heading: Basis = ui.camera.global_basis if side == "desktop" else item.global_basis
		pose.basis = Basis(Vector3.UP, heading.get_euler().y)
		var turned: AABB = Transform3D(pose.basis, Vector3.ZERO) * local_box
		pose.origin = point + Vector3.UP * (-turned.position.y + .008)
	if not fits_home(owned_home, pose, local_box): return {}
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = holder.shape; query.transform = pose * holder.transform
	query.collision_mask = 1 | ITEM_LAYER; query.exclude = excluded
	if not ui.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty(): return {}
	return {"target": item, "point": point, "pose": pose, "home": str(owned_home.place_id()), "wall": RULES.wall(id)}

static func fits_home(owned_home: Node3D, pose: Transform3D, box: AABB) -> bool:
	if not pose.is_finite() or not "floors" in owned_home or not "floor_y" in owned_home: return false
	# Every footprint corner must remain inside this house, including rotated pieces.
	for x: float in [box.position.x, box.end.x]:
		for z: float in [box.position.z, box.end.z]:
			var local: Vector3 = owned_home.to_local(pose * Vector3(x, box.position.y, z))
			var inside := false
			for rect: Rect2 in owned_home.floors:
				if rect.has_point(Vector2(local.x, local.z)): inside = true; break
			if not inside: return false
	var bottom := pose.origin.y + box.position.y
	var floor_world: float = owned_home.to_global(Vector3(0, owned_home.floor_y, 0)).y
	if bottom < floor_world - .03 or pose.origin.y + box.end.y > floor_world + 3.2: return false
	# Flat rugs can cover the route; standing furniture must leave the entrance and
	# the home's existing room-centre travel lanes clear for players and residents.
	if box.size.y <= .055 or bottom >= floor_world + 1.9: return true
	var world_box: AABB = pose * box
	var footprint := Rect2(Vector2(world_box.position.x, world_box.position.z), Vector2(world_box.size.x, world_box.size.z)).grow(.38)
	if "doorway" in owned_home and owned_home.has_method("inside"):
		var door: Vector3 = owned_home.to_global(owned_home.doorway)
		var inside: Vector3 = owned_home.inside()
		if _crosses(footprint, door, inside): return false
		for room: Rect2 in owned_home.floors:
			var center: Vector3 = owned_home.to_global(Vector3(room.get_center().x, owned_home.floor_y, room.get_center().y))
			var route: Array = owned_home._lane_route(inside, center) if owned_home.has_method("_lane_route") else [center]
			var previous := inside
			for next: Vector3 in route:
				if _crosses(footprint, previous, next): return false
				previous = next
	return true

static func _crosses(rect: Rect2, from: Vector3, to: Vector3) -> bool:
	var start := Vector2(from.x, from.z)
	var end := Vector2(to.x, to.z)
	if rect.has_point(start) or rect.has_point(end): return true
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	for index: int in 4:
		if Geometry2D.segment_intersects_segment(start, end, corners[index], corners[(index + 1) % 4]) != null: return true
	return false

## True consumes this release, including a failed write; failure keeps the hand owner.
static func place(ui: Node3D, side: String) -> bool:
	var pick := offer(ui, side)
	if pick.is_empty(): return false
	var item: RigidBody3D = ui.held[side]
	var token := str(item.get_meta("token", ""))
	if not ui.inventory.set_furnishing(token, pick.pose, pick.home): ui._error(); return true
	item.global_transform = pick.pose
	ui._unglow(item)
	configure(item, true)
	for key: String in ["hold_offset", "hold_blend", "hold_from", "ray_hold"]:
		if item.has_meta(key): item.remove_meta(key)
	ui.held.erase(side); ui._track.erase(side); ui._eat_time.erase(side)
	ui._claim(side, false); ui._refresh_holding(); ui._haptic(side)
	SFX.play_event(item, "prop_place", {"material": "wood"})
	return true

static func configure(item: RigidBody3D, placed: bool) -> void:
	if not eligible(item): return
	item.collision_layer = (1 | ITEM_LAYER) if placed else ITEM_LAYER
	if placed:
		item.freeze = true; item.linear_velocity = Vector3.ZERO; item.angular_velocity = Vector3.ZERO
	# Lamps use the existing switch/night-light owner and the existing authored model.
	if str(item.get_meta("item_id", "")) != "goods:table-lamp": return
	for visual: Node in item.get_children():
		if not visual is Node3D or not "bounds" in visual: continue
		var current: Node = visual.find_child("FurnishingLamp", true, false)
		if placed and current == null and visual.get_child_count() > 0:
			var model := visual.get_child(0) as Node3D
			if model == null: continue
			var lamp: Node3D = LAMP.attach(model, "table_lamp")
			lamp.name = "FurnishingLamp"
		elif not placed and current != null:
			current.get_parent().remove_child(current); current.queue_free()

static func hint(ui: Node3D) -> Dictionary:
	for side: String in (["desktop"] if ui._desktop else ["right", "left"]):
		var pick := offer(ui, side)
		if pick.is_empty(): continue
		var item: RigidBody3D = ui.held[side]
		var action := "Hang in your home" if pick.wall else "Place in your home"
		var control := "Shift+Q" if side == "desktop" else "Grip" if ui.inventory.loans.get(str(item.get_meta("token", "")), {}).get("equipped", false) else "Release grip"
		return {"target": item, "point": pick.point, "text": control + " · " + action, "outline": null, "visible_pick": true}
	return {}
