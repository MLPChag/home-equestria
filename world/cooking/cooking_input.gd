extends RefCounted
## Shared offer for the physical pan/knob, used verbatim by input and blue outlines.
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
const INDEX := preload("res://world/cooking/cooking_index.gd")
const STATE := preload("res://world/cooking/cooking_state.gd")
const BANANAS := preload("res://world/food/banana_boxes.gd")

static func allowed(ui: Node) -> bool:
	if not BANANAS.allowed(ui) or ui.get_tree().paused: return false
	var owner: Variant = ui.get_meta("desktop_activity_owner") if ui.has_meta("desktop_activity_owner") else null
	if is_instance_valid(owner): return false
	if ui._desktop:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or FLIGHT_INPUT.mouse_banking(ui.player_body): return false
		var focus: Control = ui.get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit: return false
	return true

static func offer(ui: Node, side: String) -> Dictionary:
	if not allowed(ui): return {}
	if side == "desktop": return _aimed(ui)
	var sample: Dictionary = ui.hand_sample(side)
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	if not sample.get("active", false) or not pose.is_finite() or absf(pose.basis.determinant()) < .0001: return {}
	var palm: Vector3 = sample.get("grip_position", pose.origin)
	if not palm.is_finite(): return {}
	var item: RigidBody3D = ui.held.get(side)
	var best: Dictionary = {}
	var distance := INF
	for station: Node3D in INDEX.near(palm):
		if station.global_position.distance_squared_to(palm) > 4.0: continue
		if is_instance_valid(item) and station.can_accept(ui, item):
			var local: Vector3 = station.pan.to_local(item.global_position)
			if Vector2(local.x, local.z).length() <= .22 and local.y >= .02 and local.y <= .38:
				if _clear(ui, palm, item.global_position, [item.get_rid()]):
					return {"target": station.pan, "station": station, "role": "pan", "point": item.global_position}
		elif not ui.hand_busy(side) and station.can_heat(ui):
			var point: Vector3 = station.knob.global_position
			var gap := palm.distance_to(point)
			var visible_face: Vector3 = point + (palm - point).normalized() * .033
			if gap < .11 and gap < distance and _clear(ui, palm, visible_face, [station.knob.get_rid()]):
				distance = gap
				best = {"target": station.knob, "station": station, "role": "knob", "point": point}
	return best

static func _aimed(ui: Node) -> Dictionary:
	if not is_instance_valid(ui.camera): return {}
	var origin: Vector3 = ui.camera.global_position
	var exclude: Array[RID] = []
	if ui.player_body is CollisionObject3D: exclude.append(ui.player_body.get_rid())
	for item: Variant in ui.held.values():
		if is_instance_valid(item): exclude.append(item.get_rid())
	var query := PhysicsRayQueryParameters3D.create(origin, origin - ui.camera.global_basis.z * 2.5, 1 | (1 << 17), exclude)
	var hit: Dictionary = ui.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not hit.collider.has_meta("home_cooker"): return {}
	var station: Node3D = hit.collider.get_meta("home_cooker")
	var role := str(hit.collider.get_meta("cooker_role", ""))
	if role == "pan":
		var item: RigidBody3D = ui.held.get("desktop")
		if not station.can_accept(ui, item): return {}
	elif role == "knob":
		if ui.hand_busy("desktop") or not station.can_heat(ui): return {}
	else: return {}
	return {"target": hit.collider, "station": station, "role": role, "point": hit.position}

static func _clear(ui: Node, from: Vector3, to: Vector3, excluded: Array[RID]) -> bool:
	if not from.is_finite() or not to.is_finite(): return false
	return ui.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, 1 | (1 << 17), excluded)).is_empty()

static func activate(ui: Node, side: String) -> bool:
	var pick: Dictionary = offer(ui, side)
	if pick.is_empty(): return false
	if pick.role == "pan": return pick.station.deposit(ui, side)
	var success: bool = pick.station.toggle(ui)
	if success: ui._haptic(side)
	return success

static func hint(ui: Node) -> Dictionary:
	for side: String in (["desktop"] if ui._desktop else ["right", "left"]):
		var pick: Dictionary = offer(ui, side)
		if pick.is_empty(): continue
		var action: String
		if pick.role == "pan":
			action = "Add ingredient"
			if side != "desktop":
				var item: Node = ui.held[side]
				var token := str(item.get_meta("token", ""))
				action = "Grip · Add ingredient" if ui.inventory.loans.get(token, {}).get("equipped", false) else "Release grip · Add ingredient"
		else:
			action = "Heat off" if bool(STATE.mark(ui.inventory, pick.station.station_id).get("heat", false)) else "Heat on"
			if side != "desktop": action = "Grip · " + action
		return {"target": pick.target, "point": pick.point, "text": "[LMB/E] " + action if side == "desktop" else action, "visible_pick": true}
	return {}

## Called by the existing one-second loose-item stream, only when cooking loans exist.
static func restore(ui: Node) -> void:
	var keys: Dictionary = {}
	for loan: Dictionary in ui.inventory.loans.values():
		if loan.has("cooking"): keys[str(loan.cooking.station)] = true
	if keys.is_empty(): return
	for key: String in keys:
		var station: Node3D = INDEX.lookup(key)
		if is_instance_valid(station): station.bind(ui)
