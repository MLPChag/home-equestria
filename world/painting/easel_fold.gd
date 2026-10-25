extends RefCounted
## The owned folding easel ("goods:easel", docs/PAINTING_STATION_2026_10_22.md section 7), in the
## pattern of the picnic blanket (world/relationships/picnic_runtime.gd lay_out, configure,
## fold_visual). Held, trigger or a click unfolds it on flat dry ground facing the player; the
## inventory saves it as one loose "easel_open" unit before the hand lets go. Gripping or E on the
## mast takes it again, which folds it (the work in progress stays in the registry and comes back
## on the next unfold, also after a trip through the briefcase).
const BUILD := preload("res://world/painting/easel_build.gd")
const REGISTRY := preload("res://world/painting/painting_registry.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const WATER := preload("res://world/water/water_contact.gd")
const ITEM_ID := "goods:easel"
## Feet in easel space (front legs, mast, back leg) and the centre.
const FEET := [Vector3(-0.375, 0, 0), Vector3(0.375, 0, 0), Vector3(0, 0, 0), Vector3(0, 0, -0.62), Vector3(0, 0, -0.25)]
const CLEARANCE := Vector3(0.8, 1.85, 0.8)
const ERROR := "Find flat, dry ground for the easel."

static func unfold(inventory: Node, side: String) -> bool:
	var item: RigidBody3D = inventory.held.get(side) as RigidBody3D
	if not is_instance_valid(item) or str(item.get_meta("item_id", "")) != ITEM_ID: return false
	var token := str(item.get_meta("token", ""))
	var camera: Camera3D = inventory.camera
	if not inventory.inventory.loans.has(token) or camera == null: return false
	var forward := -camera.global_basis.z; forward.y = 0.0
	if forward.length_squared() < 0.01: forward = Vector3.FORWARD
	forward = forward.normalized()
	var at: Vector3 = camera.global_position + forward * 1.0 if side == "desktop" else item.global_position
	# Rays start from just above the player's feet, wherever the stick is held.
	if inventory.player_body is Node3D: at.y = (inventory.player_body as Node3D).global_position.y + 0.15
	var facing: Vector3 = camera.global_position - at; facing.y = 0.0
	if facing.length_squared() < 0.01: facing = -forward
	var z := facing.normalized()
	var basis := Basis(Vector3.UP.cross(z), Vector3.UP, z)
	var exclude: Array[RID] = [item.get_rid()]
	if inventory.player_body is CollisionObject3D: exclude.append((inventory.player_body as CollisionObject3D).get_rid())
	var placed: Variant = ground_pose(item, Transform3D(basis, at), exclude)
	if not placed is Transform3D:
		inventory.inventory.last_error = ERROR; inventory._error(); return false
	var pose: Transform3D = placed
	if not inventory.inventory.set_easel_open(token, pose): inventory._error(); return false
	inventory._unglow(item); inventory.held.erase(side); inventory._track.erase(side); inventory._eat_time.erase(side); inventory._claim(side, false)
	item.global_transform = pose; item.freeze = true; item.linear_velocity = Vector3.ZERO; item.angular_velocity = Vector3.ZERO
	for meta: String in ["hold_offset", "hold_blend", "hold_from", "world_pick"]:
		if item.has_meta(meta): item.remove_meta(meta)
	# Out of the briefcase it has a new token: its unfinished picture comes back with it.
	REGISTRY.adopt_carried_wip(token, inventory.inventory.loans)
	configure(item, token)
	inventory._refresh_holding(); inventory._haptic(side)
	SFX.play_event(item, "prop_blanket", {"intensity": .6})
	return true

## Every foot and the centre on supported ground (normal.y >= 0.9), not in water, within 12 cm
## of each other, and nothing in the standing easel's space. Null when it does not fit.
static func ground_pose(body: Node3D, hint: Transform3D, exclude: Array[RID]) -> Variant:
	var space := body.get_world_3d().direct_space_state
	var lowest := INF
	var highest := -INF
	var centre_y := NAN
	for foot: Vector3 in FEET:
		var point: Vector3 = hint * foot
		var ray := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 0.9, point - Vector3.UP * 1.2, 1, exclude)
		var hit := space.intersect_ray(ray)
		if hit.is_empty() or (hit.normal as Vector3).y < 0.9: return null
		var collider: Variant = hit.get("collider")
		if collider is Node and (collider as Node).is_in_group("navigation_water"): return null
		var surface: Vector3 = hit.position
		if is_finite(WATER.surface_above(space, surface + Vector3.UP * 0.01)): return null
		lowest = minf(lowest, surface.y); highest = maxf(highest, surface.y)
		if foot == Vector3(0, 0, -0.25): centre_y = surface.y
	if highest - lowest > 0.12 or is_nan(centre_y): return null
	var pose := Transform3D(hint.basis, Vector3(hint.origin.x, centre_y, hint.origin.z))
	var clearance := BoxShape3D.new(); clearance.size = CLEARANCE
	var query := PhysicsShapeQueryParameters3D.new(); query.shape = clearance
	query.collision_mask = 1 | 2 | (1 << 17); query.exclude = exclude
	query.transform = Transform3D(pose.basis, pose * Vector3(0, CLEARANCE.y * 0.5 + 0.06, -0.25))
	if not space.intersect_shape(query, 1).is_empty(): return null
	return pose

## The standing easel on an item (after unfold, or when a saved open easel streams in).
static func configure(item: RigidBody3D, token: String) -> void:
	if not is_instance_valid(item) or item.has_meta("painting_easel_root"): return
	var visual := item.get_child(1) as Node3D
	var easel := BUILD.build(item, "easel:" + token, true)
	if easel == null: return
	if visual != null: visual.hide()
	item.set_meta("painting_easel_root", easel)
	var box := BUILD.frame_box(easel)
	var shape := BoxShape3D.new(); shape.size = box.size
	var collision := item.get_child(0) as CollisionShape3D
	collision.shape = shape; collision.position = box.get_center(); collision.disabled = false
	item.freeze = true

## After the atomic pick_up erased easel_open: bake and free the session, show the stick again.
static func fold_visual(item: RigidBody3D) -> void:
	if not is_instance_valid(item): return
	var easel: Variant = item.get_meta("painting_easel_root") if item.has_meta("painting_easel_root") else null
	if easel is Node3D and is_instance_valid(easel):
		var wake := (easel as Node3D).get_node_or_null("Wake")
		if wake != null: wake.call("shutdown_now")
		(easel as Node3D).name = "EaselFolded"
		(easel as Node3D).queue_free()
	if item.has_meta("painting_easel_root"): item.remove_meta("painting_easel_root")
	var visual := item.get_child(1) as Node3D
	if visual == null: return
	visual.show()
	if "bounds" in visual:
		var folded := BoxShape3D.new(); folded.size = (visual.bounds as AABB).size.max(Vector3.ONE * .02)
		var collision := item.get_child(0) as CollisionShape3D
		collision.shape = folded; collision.position = (visual.bounds as AABB).get_center(); collision.disabled = false
	SFX.play_event(item, "prop_blanket", {"intensity": .5})
