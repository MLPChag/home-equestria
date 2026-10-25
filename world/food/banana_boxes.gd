extends RefCounted
## An authored opening gives bananas through the existing food ownership transaction.
## The crate itself remains scenery; no hover-created food or second inventory exists.
const SPAWN := preload("res://world/food/food_spawn.gd")
const FOOD := preload("res://world/food/food_interaction.gd")

static func allowed(inventory: Node) -> bool:
	if inventory.hud_hidden or inventory._map_open(): return false
	if is_instance_valid(inventory.player_body) and "controls_locked" in inventory.player_body and inventory.player_body.controls_locked: return false
	if is_instance_valid(inventory.customizer) and inventory.customizer.opened: return false
	if is_instance_valid(inventory.case) and inventory.case.visible: return false
	if is_instance_valid(inventory.inspector) and inventory.inspector.active: return false
	return true

static func opening(box: Node3D) -> AABB:
	if not is_instance_valid(box) or not box.has_meta("banana_opening"): return AABB()
	var value: Variant = box.get_meta("banana_opening")
	if value is AABB and value.position.is_finite() and value.size.is_finite(): return value
	return AABB()

static func point(box: Node3D) -> Vector3:
	var bounds := opening(box)
	return box.to_global(bounds.get_center())

static func containing(tree: SceneTree, palm: Vector3, margin := 0.0) -> Node3D:
	if not palm.is_finite(): return null
	for box: Node3D in tree.get_nodes_in_group("banana_boxes"):
		if not box.is_visible_in_tree() or not box.global_transform.is_finite() or absf(box.global_basis.determinant()) < .0001: continue
		var bounds := opening(box)
		if not bounds.has_volume(): continue
		# Margin is only the withdrawal hysteresis; eligibility uses the authored opening.
		if bounds.grow(margin).has_point(box.to_local(palm)): return box
	return null

static func clear_path(box: Node3D, from: Vector3, to: Vector3) -> bool:
	if not from.is_finite() or not to.is_finite(): return false
	if from.distance_squared_to(to) < .00000001: return true
	var query := PhysicsRayQueryParameters3D.create(from, to, 1 | (1 << 17))
	query.hit_from_inside = true; query.hit_back_faces = true
	return box.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

static func root_for(collider: Node) -> Node3D:
	var node := collider
	while node != null:
		if node is Node3D and node.is_in_group("banana_boxes") and node.is_visible_in_tree() and opening(node).has_volume(): return node
		node = node.get_parent()
	return null

static func take(inventory: Node, side: String, box: Node3D, pose: Transform3D, at: Vector3) -> bool:
	if not allowed(inventory) or not is_instance_valid(box) or not box.is_in_group("banana_boxes") or not pose.is_finite() or not at.is_finite(): return false
	if inventory.hand_busy(side) or inventory.held.has(side): return false
	if side != "desktop" and containing(inventory.get_tree(), at) != box: return false
	# Only this action allocates a physical portion; failure leaves no displayed/free duplicate.
	var item := SPAWN.spawn(box, "food:banana", Transform3D(pose.basis.orthonormalized(), at), false)
	if item == null: return false
	item.global_position = at
	if not FOOD.take_world(inventory, side, item, Transform3D(pose.basis, at) if side != "desktop" else pose):
		item.free(); return false
	if side != "desktop": item.set_meta("ray_hold", true)
	return true
