extends RefCounted
## One answer to "what would this hand pick up right now" (dev 2026-09-30: grabbing "needs to
## be WAY more functional and WAY more ... reliable!"). The briefcase's grip and the blue
## highlight both ask this, so the thing that glows is exactly the thing a squeeze takes.
##
## Distance is measured to the object's surface (its collision shapes, else its meshes), not
## its centre: before, a loose item needed the palm within 13 cm of its middle, so a long book
## or a loaf had to be grabbed in the centre while an apple could be taken from 16 cm away.
const FOOD := preload("res://world/food/food_interaction.gd")
## Palm to surface, metres. Tracking noise plus a relaxed hand fits inside this; 0.15 since dev
## found small things fiddly to grab (2026-10-01; was 0.11).
const REACH := 0.15

## Nearest point on `node`'s solid shape to `point` (oriented boxes of its collision shapes,
## falling back to its meshes). Returns INF when it has neither.
static func surface_point(node: Node3D, point: Vector3) -> Vector3:
	var best := Vector3.INF
	var best_gap := INF
	for shape_node: Node in [node] + node.find_children("*", "CollisionShape3D", true, false):
		if not shape_node is CollisionShape3D: continue
		var collision: CollisionShape3D = shape_node
		if collision.disabled or collision.shape == null: continue
		var candidate := _box_point(collision.global_transform, collision.shape.get_debug_mesh().get_aabb(), point)
		var gap := candidate.distance_to(point)
		if gap < best_gap: best = candidate; best_gap = gap
	if best_gap < INF: return best
	for mesh_node: Node in [node] + node.find_children("*", "MeshInstance3D", true, false):
		if not mesh_node is MeshInstance3D or (mesh_node as MeshInstance3D).mesh == null: continue
		var mesh: MeshInstance3D = mesh_node
		var candidate := _box_point(mesh.global_transform, mesh.get_aabb(), point)
		var gap := candidate.distance_to(point)
		if gap < best_gap: best = candidate; best_gap = gap
	return best

static func _box_point(xf: Transform3D, box: AABB, point: Vector3) -> Vector3:
	var local := xf.affine_inverse() * point
	return xf * local.clamp(box.position, box.end)

static func surface_distance(node: Node3D, point: Vector3) -> float:
	var at := surface_point(node, point)
	return at.distance_to(point) if at.is_finite() else INF

## {"target": Node3D, "kind": "loose"|"food"|"shop"|"book", "distance": float} or {} for a free hand at
## `point`. `inventory` is the BriefcaseInventory (loose items, held items).
static func nearest(inventory: Node, point: Vector3) -> Dictionary:
	if not point.is_finite(): return {}
	var best := {}
	var best_gap := REACH
	var held: Array = inventory.held.values()
	for item: Variant in inventory.loose.values():
		if not is_instance_valid(item) or item in held or not (item as Node3D).is_visible_in_tree(): continue
		var gap := surface_distance(item, point)
		if gap < best_gap: best = {"target": item, "kind": "loose", "distance": gap}; best_gap = gap
	for food: Node in inventory.get_tree().get_nodes_in_group("world_food"):
		if not food is RigidBody3D or bool(food.get_meta("food_claiming", false)): continue
		if (food as Node3D).global_position.distance_to(point) > 1.0: continue
		var gap := surface_distance(food, point)
		# Food on a counter behind glass or a wall is not reachable from this side.
		if gap < best_gap and FOOD.clear_reach(food, point, REACH + 0.02):
			best = {"target": food, "kind": "food", "distance": gap}; best_gap = gap
	for good: Node in inventory.get_tree().get_nodes_in_group("shop_items"):
		if not good is RigidBody3D or bool(good.get_meta("shop_claiming", false)): continue
		if (good as Node3D).global_position.distance_to(point) > 1.5: continue
		var gap := surface_distance(good, point)
		if gap < best_gap: best = {"target": good, "kind": "shop", "distance": gap}; best_gap = gap
	for book: Node in inventory.get_tree().get_nodes_in_group("shelf_books"):
		if not book is Node3D or (book as Node3D).global_position.distance_to(point) > 1.0: continue
		var gap := surface_distance(book, point)
		if gap < best_gap: best = {"target": book, "kind": "book", "distance": gap}; best_gap = gap
	return best

## Pointing grab (dev 2026-10-01: "pick up shit magnetically by pointing my hand at it ... like
## how other vr games do it"): with nothing in reach of the palm, the hand's aim picks a loose
## thing, food or a good within POINT_REACH and POINT_DEGREES of the aim, in plain sight. The
## grip then pulls it into the hand. Shelf books stay hand-only: they stand packed together.
const POINT_REACH := 5.0
const POINT_DEGREES := 12.0

## What a grip takes now: the nearest thing at the palm, else the one the hand points at
## ("pointed": true).
static func pick(inventory: Node, pose: Transform3D, aim: Transform3D) -> Dictionary:
	var near := nearest(inventory, pose.origin)
	if not near.is_empty() or not aim.origin.is_finite(): return near
	return pointed(inventory, aim.origin, -aim.basis.z.normalized())

static func pointed(inventory: Node, origin: Vector3, direction: Vector3) -> Dictionary:
	if not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.5: return {}
	var held: Array = inventory.held.values()
	var candidates: Array = []
	for item: Variant in inventory.loose.values():
		if is_instance_valid(item) and not item in held: candidates.append([item, "loose"])
	for food: Node in inventory.get_tree().get_nodes_in_group("world_food"):
		if food is RigidBody3D and not bool(food.get_meta("food_claiming", false)) and not bool(food.get_meta("food_for_sale", false)):
			candidates.append([food, "food"])
	var best := {}
	var best_score := INF
	var space: PhysicsDirectSpaceState3D = inventory.get_world_3d().direct_space_state
	for row: Array in candidates:
		var node := row[0] as Node3D
		if node == null or not node.is_inside_tree() or not node.is_visible_in_tree(): continue
		var to := node.global_position - origin
		var distance := to.length()
		if distance > POINT_REACH or distance < 0.05: continue
		var angle := rad_to_deg(direction.angle_to(to))
		if angle > POINT_DEGREES: continue
		var score := angle + distance * 1.5
		if score >= best_score: continue
		var skip: Array[RID] = []
		if node is CollisionObject3D: skip.append((node as CollisionObject3D).get_rid())
		var body: Variant = inventory.get("player_body")
		if body is CollisionObject3D: skip.append((body as CollisionObject3D).get_rid())
		var sight := space.intersect_ray(PhysicsRayQueryParameters3D.create(origin, node.global_position, 1, skip))
		if not sight.is_empty(): continue
		best = {"target": node, "kind": row[1], "distance": distance, "pointed": true}
		best_score = score
	return best
