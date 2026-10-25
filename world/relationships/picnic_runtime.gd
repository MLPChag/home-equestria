extends Node
## Owned blanket deployment and actual shared-meal evidence; no free servings or idle rewards.
const SFX := preload("res://world/audio/interaction_sounds.gd")
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
const BANANAS := preload("res://world/food/banana_boxes.gd")
const BLANKET := preload("res://world/relationships/picnic_blanket.gd")
const WATER := preload("res://world/water/water_contact.gd")
const ITEM_ID := "goods:folded-blanket"
const MEAL_COMPANY_SECONDS := 30.0
var game: Node
var blankets: Dictionary = {}
var company: Dictionary = {}
var _scan := 0.0

func setup(host: Node) -> void:
	game = host
	add_to_group("picnic_runtime")
	add_to_group("interaction_hint_sources")
	add_to_group("picnic_consumption")

static func supported_surface(hit: Dictionary) -> bool:
	var node: Variant = hit.get("collider")
	if not is_instance_valid(node) or float((hit.get("normal", Vector3.ZERO) as Vector3).y) < .90: return false
	if node.is_in_group("navigation_water"): return false
	return node is Terrain3D or node is StaticBody3D

## Full footprint samples include its edges; every point must be dry, stable and supported.
static func deployment_pose(body: Node3D, at: Vector3, forward: Vector3, exclude: Array[RID] = [], check_clearance: bool = true) -> Dictionary:
	if not is_instance_valid(body) or not body.is_inside_tree() or not at.is_finite() or not forward.is_finite(): return {}
	forward.y = 0.0
	if forward.length_squared() < .01: forward = Vector3.FORWARD
	var basis: Basis = Basis.looking_at(forward.normalized(), Vector3.UP)
	var space: PhysicsDirectSpaceState3D = body.get_world_3d().direct_space_state
	var origin: Vector3 = at
	var samples: Array = []
	var highest := -INF
	var lowest := INF
	for z in range(BLANKET.GRID.y + 1):
		for x in range(BLANKET.GRID.x + 1):
			var offset := Vector3((float(x) / BLANKET.GRID.x - .5) * BLANKET.SIZE.x, 0, (float(z) / BLANKET.GRID.y - .5) * BLANKET.SIZE.y)
			var point: Vector3 = at + basis * offset
			var ray := PhysicsRayQueryParameters3D.create(point + Vector3.UP * .7, point - Vector3.UP * .9, 1, exclude)
			var hit: Dictionary = space.intersect_ray(ray)
			if not supported_surface(hit): return {}
			var surface: Vector3 = hit.position
			if is_finite(WATER.surface_above(space, surface + Vector3.UP * .01)): return {}
			highest = maxf(highest, surface.y); lowest = minf(lowest, surface.y)
			if highest - lowest > .5: return {}
			if x > 0 and absf(surface.y - float(samples.back())) > BLANKET.SIZE.x / BLANKET.GRID.x * .55: return {}
			if z > 0 and absf(surface.y - float(samples[(z - 1) * (BLANKET.GRID.x + 1) + x])) > BLANKET.SIZE.y / BLANKET.GRID.y * .55: return {}
			samples.append(surface.y)
	origin.y = float(samples[(BLANKET.GRID.y / 2) * (BLANKET.GRID.x + 1) + BLANKET.GRID.x / 2]) + .022
	var clearance := BoxShape3D.new(); clearance.size = Vector3(.17, .65, .17)
	var query := PhysicsShapeQueryParameters3D.new(); query.shape = clearance; query.collision_mask = 1 | 2 | (1 << 17)
	query.exclude = exclude
	for z in range(BLANKET.GRID.y + 1):
		for x in range(BLANKET.GRID.x + 1):
			var index: int = z * (BLANKET.GRID.x + 1) + x
			var offset := Vector3((float(x) / BLANKET.GRID.x - .5) * BLANKET.SIZE.x, 0, (float(z) / BLANKET.GRID.y - .5) * BLANKET.SIZE.y)
			var center: Vector3 = at + basis * offset
			center.y = float(samples[index]) + .36
			query.transform = Transform3D(basis, center)
			if check_clearance and not space.intersect_shape(query, 1).is_empty(): return {}
			samples[index] = float(samples[index]) + .022 - origin.y
	return {"pose": Transform3D(basis, origin), "heights": samples}

func lay_out(side: String, item: RigidBody3D, pose_hint: Variant = null) -> bool:
	if not is_instance_valid(game) or not is_instance_valid(item) or item.get_meta("item_id", "") != ITEM_ID: return false
	var inventory: Node = game.inventory
	var token: String = str(item.get_meta("token", ""))
	if inventory.held.get(side) != item or not inventory.inventory.loans.has(token): return false
	var camera: Camera3D = game._find_camera(game.player)
	if camera == null: return false
	var forward: Vector3 = -camera.global_basis.z; forward.y = 0.0
	if forward.length_squared() < .01: forward = Vector3.FORWARD
	var start: Vector3 = camera.global_position + forward.normalized() * 1.6
	if side != "desktop": start = item.global_position
	if inventory.player_body is Node3D: start.y = inventory.player_body.global_position.y + .15
	if pose_hint is Transform3D: start = pose_hint.origin
	var excludes: Array[RID] = [item.get_rid()]
	if inventory.player_body is CollisionObject3D: excludes.append(inventory.player_body.get_rid())
	var placement: Dictionary = deployment_pose(item, start, -camera.global_basis.z, excludes)
	if placement.is_empty():
		inventory.inventory.last_error = "Find a clear, dry, supported surface for the blanket."; inventory._error(); return false
	# Save one owned unit before releasing grip, freezing or replacing any geometry.
	if not inventory.inventory.set_picnic_deployed(token, placement.pose, placement.heights): inventory._error(); return false
	inventory._unglow(item); inventory.held.erase(side); inventory._track.erase(side); inventory._eat_time.erase(side); inventory._claim(side, false)
	item.global_transform = placement.pose; item.freeze = true; item.linear_velocity = Vector3.ZERO; item.angular_velocity = Vector3.ZERO
	for key: String in ["hold_offset", "hold_blend", "world_pick"]:
		if item.has_meta(key): item.remove_meta(key)
	configure(item, token)
	inventory._refresh_holding(); inventory._haptic(side)
	SFX.play_event(item, "prop_blanket", {"intensity": .65})
	return true

func configure(item: RigidBody3D, token: String) -> void:
	if not is_instance_valid(item) or item.has_meta("picnic_surface"): return
	var surface: Node3D = BLANKET.new(); surface.name = "PicnicBlanket"; surface.loan_token = token; surface.inventory = game.inventory
	var saved: Dictionary = game.inventory.inventory.loans.get(token, {})
	surface.heights = (saved.get("picnic_heights", []) as Array).duplicate()
	if surface.heights.is_empty():
		var sample: Dictionary = deployment_pose(item, item.global_position, -item.global_basis.z, [item.get_rid()], false)
		if not sample.is_empty():
			# Old deployed saves did not store shape. Preserve their pose and all items,
			# sampling relative heights around that saved origin when support is available.
			var offset: float = sample.pose.origin.y - item.global_position.y
			surface.heights = sample.heights
			for i in surface.heights.size(): surface.heights[i] = float(surface.heights[i]) + offset
	item.add_child(surface)
	var old_visual: Node3D = item.get_child(1) as Node3D
	old_visual.hide()
	var collision: CollisionShape3D = item.get_child(0) as CollisionShape3D
	var unfolded: ConvexPolygonShape3D = surface.pick_shape()
	collision.shape = unfolded; collision.position = Vector3.ZERO; collision.disabled = false
	item.freeze = true; item.set_meta("picnic_surface", surface)
	blankets[token] = weakref(item)
	get_tree().call_group("grass_footprints", "add_exclusion", "picnic:" + token, item.global_transform, BLANKET.SIZE * .5)

func can_pack(item: RigidBody3D) -> bool:
	var surface: Node3D = item.get_meta("picnic_surface") if item.has_meta("picnic_surface") else null
	if not is_instance_valid(surface): return false
	if surface.occupied(): return false
	for loose: Variant in game.inventory.loose.values():
		if is_instance_valid(loose) and loose != item and surface.contains(loose.global_position): return false
	for actor: Variant in game.relationship_runtime.actors.values():
		if is_instance_valid(actor) and surface.contains(actor.global_position, 2.0): return false
	var camera: Camera3D = game._find_camera(game.player)
	if camera != null and surface.contains(camera.global_position, 2.5): return false
	# World food still belongs to its display/world until deliberately stored.
	for food: Node3D in get_tree().get_nodes_in_group("world_food"):
		if is_instance_valid(food) and surface.contains(food.global_position): return false
	return true

## A replacement loaded from the same saved token may already be registered when
## the old body exits. Its cleanup must not erase the replacement's grass/meal owner.
func forget_blanket(item: Node, surface: Node) -> void:
	if not is_instance_valid(item): return
	var token: String = str(item.get_meta("token", ""))
	if not blankets.has(token) or blankets[token].get_ref() != item or not item.has_meta("picnic_surface") or item.get_meta("picnic_surface") != surface: return
	get_tree().call_group("grass_footprints", "remove_exclusion", "picnic:" + token)
	blankets.erase(token); company.erase(token)

## Called after the atomic pick_up has erased the deployment flag.
func fold_visual(item: RigidBody3D) -> void:
	var token: String = str(item.get_meta("token", ""))
	var surface: Node = item.get_meta("picnic_surface") if item.has_meta("picnic_surface") else null
	if is_instance_valid(surface): surface.queue_free()
	item.remove_meta("picnic_surface")
	var visual: Node3D = item.get_child(1) as Node3D
	visual.show()
	var folded := BoxShape3D.new(); folded.size = (visual.bounds as AABB).size.max(Vector3.ONE * .02)
	var collision: CollisionShape3D = item.get_child(0) as CollisionShape3D
	collision.shape = folded; collision.position = (visual.bounds as AABB).get_center(); collision.disabled = false
	get_tree().call_group("grass_footprints", "remove_exclusion", "picnic:" + token)
	blankets.erase(token); company.erase(token)
	SFX.play_event(item, "prop_blanket", {"intensity": .55})

## A nearby idle pony must not satisfy the generic needs/shared-meal path on a picnic.
func contains_player(at: Vector3) -> bool:
	for token: String in blankets:
		var item: Variant = blankets[token].get_ref()
		if not is_instance_valid(item): continue
		var surface: Node3D = item.get_meta("picnic_surface")
		if is_instance_valid(surface) and surface.contains(at, 2.5): return true
	return false

func food_consumed(item: Node3D, _id: String, receipt: String) -> void:
	if not is_instance_valid(item) or receipt.is_empty(): return
	var camera: Camera3D = game._find_camera(game.player)
	if camera == null: return
	for token: String in blankets:
		var blanket: Variant = blankets[token].get_ref()
		if not is_instance_valid(blanket): continue
		var surface: Node3D = blanket.get_meta("picnic_surface")
		# The player and the actual consumed body must both be here, not simply visible nearby.
		if not surface.contains(item.global_position, 2.2) or not surface.contains(camera.global_position, 2.5): continue
		var companions: Dictionary = company.get(token, {})
		for pony_id: String in companions:
			var entry: Dictionary = companions[pony_id]
			var plan: Dictionary = game.relationship_runtime.bonds.record_for(pony_id).plan
			var actor: Node3D = game.relationship_runtime._actor(pony_id)
			if actor == null or actor.get("sleeping") == true or not surface.contains(actor.global_position, 2.0): continue
			if plan.get("id") != entry.plan or plan.get("activity") != "meal" or float(plan.get("deadline", 0.0)) < game.relationship_runtime.bonds.now() or float(entry.seconds) < MEAL_COMPANY_SECONDS: continue
			if game.relationship_runtime.bonds.experience(pony_id, "meal", "picnic-eaten:" + receipt): surface.complete_meal(actor, str(entry.plan))

func _physics_process(delta: float) -> void:
	if not is_instance_valid(game) or not is_instance_valid(game.inventory) or not is_instance_valid(game.relationship_runtime): return
	_scan -= delta
	if _scan > 0.0: return
	var elapsed: float = .5
	_scan = elapsed
	var camera: Camera3D = game._find_camera(game.player)
	for token: String in blankets.keys():
		var blanket: Variant = blankets[token].get_ref()
		if not is_instance_valid(blanket): blankets.erase(token); company.erase(token); continue
		var surface: Node3D = blanket.get_meta("picnic_surface")
		var present: Dictionary = company.get(token, {})
		var active_plans: Dictionary = {}
		var player_here: bool = camera != null and surface.contains(camera.global_position, 2.5)
		for pony_id: String in game.relationship_runtime.actors:
			var actor: Node3D = game.relationship_runtime._actor(pony_id)
			var plan: Dictionary = game.relationship_runtime.bonds.record_for(pony_id).plan
			if plan.get("activity") == "meal" and float(plan.get("deadline", 0.0)) >= game.relationship_runtime.bonds.now(): active_plans[pony_id] = str(plan.id)
			var here: bool = actor != null and camera != null and surface.contains(actor.global_position, 2.0) and surface.contains(camera.global_position, 2.5) and actor.get("sleeping") != true
			if actor != null and camera != null and plan.get("activity") == "meal" and float(plan.get("deadline", 0.0)) >= game.relationship_runtime.bonds.now() and surface.contains(camera.global_position, 2.5) and actor.global_position.distance_to(surface.global_position) < 3.5 and not actor.has_meta("seating"):
				surface.accept_meal(actor, str(plan.id))
			if not here or plan.get("activity") != "meal" or float(plan.get("deadline", 0.0)) < game.relationship_runtime.bonds.now(): present.erase(pony_id); continue
			var row: Dictionary = present.get(pony_id, {"plan": plan.id, "seconds": 0.0})
			if row.plan != plan.id: row = {"plan": plan.id, "seconds": 0.0}
			row.seconds += elapsed; present[pony_id] = row
		surface.maintain_meals(active_plans, player_here)
		company[token] = present

func interaction_hint() -> Dictionary:
	if not is_instance_valid(game) or not is_instance_valid(game.inventory) or not BANANAS.allowed(game.inventory): return {}
	if game.inventory._desktop:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or FLIGHT_INPUT.mouse_banking(game.inventory.player_body): return {}
		var focus: Control = get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit: return {}
	for side: String in game.inventory.held:
		var item: Node3D = game.inventory.held[side]
		if item.get_meta("item_id", "") == ITEM_ID:
			return {"target": item, "point": item.global_position + Vector3.UP * .15, "text": "Click · Lay out on a clear surface" if side == "desktop" else "Trigger · Lay out on a clear surface"}
	return {}

func _exit_tree() -> void:
	if not is_inside_tree(): return
	for token: String in blankets:
		get_tree().call_group("grass_footprints", "remove_exclusion", "picnic:" + token)
