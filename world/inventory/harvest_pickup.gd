extends Node
## Player adapter for the orchard's real loose fruit. The orchard remains the sole
## ledger/persistence owner; carrying a fruit never mints an inventory loan.
const FLIGHT := preload("res://player/wing_flight.gd")
const TARGETS := preload("res://world/inventory/grab_targets.gd")
const HOLD := Transform3D(Basis.IDENTITY, Vector3(.19, -.18, -.42))
var activity: Node3D
var inventory: Node
var held: Dictionary = {}
var _deposit_time := -1.0
var _deposit_from := Transform3D.IDENTITY
var _deposit_target := Vector3.ZERO
var _deposit_basket: Node3D
const DEPOSIT_SECONDS := .35

func setup(orchard: Node3D, ui: Node) -> void:
	activity = orchard; inventory = ui
	process_physics_priority = -60
	add_to_group("grab_providers")
	add_to_group("interaction_hint_sources")
	add_to_group("desktop_item_presentations")
	activity.claim_lost.connect(_claim_lost)

func _available() -> bool:
	if not is_instance_valid(activity) or not is_instance_valid(inventory) or not is_instance_valid(inventory.camera): return false
	if not is_instance_valid(inventory.player_body) or inventory.player_body.controls_locked: return false
	return not inventory._quick_blocked()

func _clear(from: Vector3, to: Vector3, fruit: RigidBody3D) -> bool:
	var excluded: Array[RID] = [fruit.get_rid()]
	if inventory.player_body is CollisionObject3D: excluded.append(inventory.player_body.get_rid())
	return activity.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, 1, excluded)).is_empty()

func desktop_offer() -> Dictionary:
	if not _available() or inventory.hand_busy("desktop"): return {}
	var camera: Camera3D = inventory.camera
	var excluded: Array[RID] = []
	if inventory.player_body is CollisionObject3D: excluded.append(inventory.player_body.get_rid())
	var hit: Dictionary = activity.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(camera.global_position, camera.global_position-camera.global_basis.z*2.5, 1 | 8, excluded))
	var fruit: RigidBody3D = hit.get("collider") as RigidBody3D
	if fruit == null or not activity.apple_available(fruit): return {}
	return {"target":fruit,"point":hit.position,"text":"Click / E · Pick up harvest apple","visible_pick":true}

func grab_offer(side: String, sample: Dictionary) -> Dictionary:
	if not _available() or held.has(side): return {}
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	var from: Vector3 = sample.get("grip_position", pose.origin)
	if not sample.get("active", false) or not pose.is_finite() or not from.is_finite(): return {}
	var best: Dictionary = {}; var gap := TARGETS.REACH
	for fruit: RigidBody3D in activity.loose.values():
		if not is_instance_valid(fruit) or not activity.apple_available(fruit): continue
		if fruit.global_position.distance_squared_to(from) > 1.0: continue
		var point: Vector3 = TARGETS.surface_point(fruit, from)
		var distance: float = from.distance_to(point)
		if distance < gap and _clear(from, point, fruit):
			gap = distance
			best = {"target":fruit,"point":point,"distance":gap,"text":side.capitalize()+" grip · Pick up harvest apple"}
	return best

func grab_take(side: String, offer: Dictionary, _sample: Dictionary) -> bool:
	return take(side, offer.get("target") as RigidBody3D)

func take(side: String, fruit: RigidBody3D) -> bool:
	if not _available() or held.has(side) or inventory.hand_busy(side): return false
	if not activity.claim_apple(fruit, self): return false
	held[side] = fruit
	if side == "desktop": inventory.set_meta("desktop_activity_owner", self)
	var hand:Node=inventory.hands.get(side)
	if is_instance_valid(hand):hand.set_meta("harvest_owner",self)
	inventory._claim(side, true); inventory._haptic(side)
	return true

func _claim_lost(fruit: RigidBody3D, owner: Node) -> void:
	if owner != self: return
	for side: String in held.keys():
		if held[side] == fruit: _clear_hand(side)

func _clear_hand(side: String) -> void:
	held.erase(side)
	if not is_instance_valid(inventory):return
	if side == "desktop":
		_deposit_time = -1.0; _deposit_basket = null
		var owns:bool=inventory.has_meta("desktop_activity_owner") and inventory.get_meta("desktop_activity_owner")==self
		if owns:
			if is_instance_valid(inventory.desktop_presentation):inventory.desktop_presentation.clear_hold_target("right")
			inventory.remove_meta("desktop_activity_owner")
			inventory._claim(side,false)
	else:
		var hand:Node=inventory.hands.get(side)
		if not is_instance_valid(hand):inventory._claim(side,false)
		elif hand.has_meta("harvest_owner") and hand.get_meta("harvest_owner")==self:
			hand.remove_meta("harvest_owner");inventory._claim(side,false)

func release(side: String, velocity: Vector3 = Vector3.ZERO) -> bool:
	var fruit: RigidBody3D = held.get(side)
	if not is_instance_valid(fruit): _clear_hand(side); return false
	if not activity.release_apple(fruit, self, velocity): return false
	_clear_hand(side)
	return true

func _arm_reach() -> float:
	var driver:Node=inventory.desktop_presentation
	if is_instance_valid(driver) and "avatar" in driver and is_instance_valid(driver.avatar):
		return 1.05 * float(driver.avatar.model_scale)
	return 1.05

func basket_offer() -> Dictionary:
	if not held.has("desktop") or not _available(): return {}
	var fruit: RigidBody3D = held.desktop
	var id: String = str(fruit.get_meta("tree_id", ""))
	var basket: Node3D = activity.baskets.get(id)
	if not is_instance_valid(basket): return {}
	var camera: Camera3D = inventory.camera
	if camera.global_position.distance_to(activity.basket_for(id)) > _arm_reach():return {}
	var excluded: Array[RID] = [fruit.get_rid()]
	if inventory.player_body is CollisionObject3D: excluded.append(inventory.player_body.get_rid())
	var hit: Dictionary = activity.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(camera.global_position, camera.global_position-camera.global_basis.z*2.5, 1, excluded))
	if hit.get("collider") != basket: return {}
	return {"target":basket,"point":activity.basket_for(id),"text":"Click / E / Shift+Q · Put apple in basket","visible_pick":true}

func deposit_desktop() -> bool:
	if _deposit_time >= 0.0:return true
	var offer := basket_offer()
	if offer.is_empty(): return false
	var fruit: RigidBody3D = held.desktop
	_deposit_from = fruit.global_transform
	_deposit_target = offer.point
	_deposit_basket = offer.target
	_deposit_time = 0.0
	return true

func _physics_process(delta: float) -> void:
	if not is_instance_valid(activity): return
	for side: String in held.keys():
		var fruit: RigidBody3D = held[side]
		if not is_instance_valid(fruit) or activity.claim_owner(fruit) != self: _clear_hand(side); continue
		if not _available(): release(side); continue
		if side == "desktop":
			if _deposit_time >= 0.0:
				if not is_instance_valid(_deposit_basket) or inventory.camera.global_position.distance_to(_deposit_target) > _arm_reach():
					_deposit_time = -1.0; continue
				_deposit_time += delta
				var target := Transform3D(_deposit_from.basis,_deposit_target)
				fruit.global_transform = _deposit_from.interpolate_with(target,smoothstep(0.0,1.0,minf(1.0,_deposit_time/DEPOSIT_SECONDS)))
				if _deposit_time >= DEPOSIT_SECONDS:
					if activity.deposit(fruit,self):
						_clear_hand("desktop");inventory._haptic("desktop");continue
					else:_deposit_time = -1.0
			else:fruit.global_transform = inventory.camera.global_transform * HOLD
			if is_instance_valid(inventory.desktop_presentation):inventory.desktop_presentation.set_hold_target("right",fruit.global_transform,"hold")
		else:
			var sample: Dictionary = inventory.hand_sample(side)
			var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
			if not sample.get("active", false) or not pose.is_finite(): release(side); continue
			fruit.global_transform = pose
			fruit.global_position = sample.get("grip_position", pose.origin)
			if float(sample.get("grip", 0.0)) < .25:
				if activity.deposit(fruit, self): _clear_hand(side)
				else: release(side)

func _input(event: InputEvent) -> void:
	if not is_instance_valid(inventory) or not inventory._desktop or not held.has("desktop"): return
	if not _available() or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or FLIGHT.reserves_mouse(event, inventory.player_body): return
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_Q:
			if event.shift_pressed:
				if not deposit_desktop(): release("desktop")
			else: release("desktop", -inventory.camera.global_basis.z * 7.0 + Vector3.UP * 1.8)
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_E:
			deposit_desktop(); get_viewport().set_input_as_handled()
		elif event.physical_keycode in [KEY_I, KEY_U, KEY_TAB, KEY_J]:
			cancel_desktop_activity()
		elif event.physical_keycode == KEY_G or event.physical_keycode >= KEY_1 and event.physical_keycode <= KEY_5:
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed: deposit_desktop()
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if not is_instance_valid(inventory) or not inventory._desktop or not _available(): return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or FLIGHT.reserves_mouse(event, inventory.player_body): return
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return
	var pressed: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	pressed = pressed or (event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E)
	if not pressed: return
	var offer := desktop_offer()
	if not offer.is_empty() and take("desktop", offer.target): get_viewport().set_input_as_handled()

func interaction_hint() -> Dictionary:
	if not is_instance_valid(inventory) or not inventory._desktop: return {}
	if held.has("desktop"):
		var offer := basket_offer()
		if not offer.is_empty(): return offer
		var fruit: Node3D = held.desktop
		return {"target":fruit,"point":fruit.global_position,"text":"Aim at its basket · Put apple in\nQ · Throw   Shift+Q · Set down","outline":null}
	return desktop_offer()

func item_presentation() -> Dictionary:
	var fruit: Node3D = held.get("desktop")
	return {"action":"place" if _deposit_time >= 0.0 else "hold","held":fruit,"target":fruit,"point":fruit.global_position,"helper":false,"progress":0.0} if is_instance_valid(fruit) else {}

func cancel_desktop_activity() -> void:
	if held.has("desktop"):release("desktop")

func _exit_tree() -> void:
	for side: String in held.keys():
		if is_instance_valid(activity): release(side)
		else: _clear_hand(side)
