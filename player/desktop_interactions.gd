extends Node
## Contextual desktop actions. One active hand, with a supporting hand for carries.
## This adapter supplies deliberate commands and presentation targets, never XR tracking.
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const OWNER := preload("res://player/desktop_action_owner.gd")
const TOUCH_REACH := 1.6
const CONTACT_SECONDS := .16
const STROKE_SECONDS := .7
var camera: Camera3D
var body: Node3D
var inventory: Node
var interactor: Node
var _action := ""
var _target: Node3D
var _offer: Dictionary = {}
var _point := Vector3.ZERO
var _normal := Vector3.UP
var _time := 0.0
var _used := false
var _pressed := false
var _hoof_anchor := Vector3.ZERO
var _slap_until := 0
var _avatar: Node
var _held_pose := false


func setup(view: Camera3D, movement: Node3D, items: Node, reach: Node) -> void:
	camera = view; body = movement; inventory = items; interactor = reach
	add_to_group("desktop_interactions")
	add_to_group("interaction_hint_sources")
	process_physics_priority = -30
	if is_instance_valid(interactor): interactor.desktop_actions = self
	call_deferred("_bind_presentation")


func _bind_presentation() -> void:
	if not is_instance_valid(inventory) or not "desktop_presentation" in inventory: return
	_avatar = inventory.desktop_presentation
	if is_instance_valid(_avatar) and _avatar.has_signal("action_contact") and not _avatar.action_contact.is_connected(_action_contact):
		_avatar.action_contact.connect(_action_contact)


func _present(kind: String, point: Vector3, normal: Vector3) -> bool:
	if not is_instance_valid(_avatar): _bind_presentation()
	if not is_instance_valid(_avatar): return false
	if kind in ["carry", "hoof_hold"]:
		var facing := camera.global_basis.orthonormalized()
		_avatar.set_hold_target("right", Transform3D(facing, point), "hold")
		if kind == "carry": _avatar.set_hold_target("left", Transform3D(facing, point-camera.global_basis.x*.18), "hold")
		_held_pose = true
		return true
	if kind == "pet" and _avatar.update_action_target(kind, point, normal): return true
	return _avatar.request_action(kind, point, normal)


func busy() -> bool:
	return not _action.is_empty() or (is_instance_valid(interactor) and is_instance_valid(interactor.held))


func _human() -> bool:
	return not PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree()))


func _available() -> bool:
	if not is_instance_valid(camera) or not is_instance_valid(body) or not is_instance_valid(inventory): return false
	if get_tree().paused or body.get("controls_locked") == true or body.get_meta("knocked_down", false): return false
	if body.get("flying") == true or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return false
	if not _human(): return false
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return false
	return true


func can_accept_world_action() -> bool:
	if not _available() or inventory.held.has("desktop") or inventory.holding_case == "desktop": return false
	var owner: Variant = inventory.get_meta("desktop_activity_owner") if inventory.has_meta("desktop_activity_owner") else null
	return not is_instance_valid(owner) or owner == self


func _social_free() -> bool:
	if not can_accept_world_action() or (is_instance_valid(interactor) and is_instance_valid(interactor.held)): return false
	var host: Node = inventory.get_parent()
	var kisser: Variant = host.get("kisser") if "kisser" in host else null
	if is_instance_valid(kisser) and is_instance_valid(kisser.get("_active")): return false
	var cuddle: Node = get_tree().get_first_node_in_group("cuddle_input")
	return not is_instance_valid(cuddle) or not is_instance_valid(cuddle.current)


func _ponies() -> Array:
	var host: Node = inventory.get_parent()
	var actors: Variant = host.get("mares") if "mares" in host else null
	return actors if actors is Array else []


func _clear_to(point: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(camera.global_position, point, 1 | 8 | (1 << 17))
	return camera.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _select(slap: bool = false) -> Dictionary:
	var origin := camera.global_position
	var reach := TOUCH_REACH
	if is_instance_valid(_avatar) and is_instance_valid(_avatar.avatar): reach = minf(reach, _avatar.MAX_REACH*float(_avatar.avatar.model_scale))
	var end := origin - camera.global_basis.z * reach
	var closest := reach + .001
	var best: Dictionary = {}
	for actor: Variant in _ponies():
		if not is_instance_valid(actor) or not actor.is_inside_tree() or not actor.is_visible_in_tree(): continue
		if actor.global_position.distance_squared_to(origin) > 9.0 or actor.is_held(): continue
		var touch: Node = actor.get("touch_body")
		if not is_instance_valid(touch): continue
		var hit: Dictionary = touch.desktop_offer(origin, end)
		if hit.is_empty(): continue
		var distance: float = origin.distance_to(hit.point)
		if distance >= closest: continue
		closest = distance; best = hit
	if best.is_empty(): return {}
	if slap:
		var identity: Resource = best.target.get("identity")
		if identity != null and bool(identity.get("filly")): return {}
		var flank: Node = best.target.get_node_or_null("FlankTouch")
		if flank == null:
			for child: Node in best.target.get_children():
				if child.has_method("desktop_impact"): flank = child; break
		if flank == null: return {}
		var hit: Dictionary = flank.desktop_offer(origin, end)
		if hit.is_empty() or not _clear_to(hit.point): return {}
		# A head/leg between the eye and rear patch remains an obstruction.
		if Vector3(best.point).distance_to(hit.point) > .16: return {}
		hit.flank = flank
		return hit
	var boop: Node = best.target.get("boop_node")
	if is_instance_valid(boop):
		var nose: Vector3 = boop.nose_world()
		if Vector3(best.point).distance_to(nose) < .065:
			best.kind = "boop"; best.point = nose
			return best
	best.kind = "pet"
	return best


func _claim() -> void:
	OWNER.claim(inventory, self)


func _unclaim() -> void:
	OWNER.release(inventory, self)


func cancel_desktop_activity() -> void:
	_finish()
	if is_instance_valid(interactor) and is_instance_valid(interactor.held): interactor._drop()


func _begin(action: String, offer: Dictionary) -> bool:
	if offer.is_empty() or not _action.is_empty() or not _social_free(): return false
	_action = action; _target = offer.target; _offer = offer
	_point = offer.point; _normal = offer.normal; _time = 0.0; _used = false
	_claim()
	if not _present(action, _point, _normal): _finish(); return false
	return true


func _begin_hoof(offer: Dictionary) -> bool:
	if offer.is_empty() or not _social_free(): return false
	var hoof: RefCounted = offer.target.get("hoof_hold")
	if hoof == null: return false
	var hit: Dictionary = hoof.candidate(offer.point, .12)
	if hit.is_empty() or not hoof.begin(hit, offer.point): return false
	if not _begin("hoof_hold", offer):
		hoof.release(); return false
	_hoof_anchor = camera.to_local(offer.point)
	_target.physical_reaction.emit("hoofhold")
	return true


func _input(event: InputEvent) -> void:
	# Releases must reach this owner even when a panel consumes the original button.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_pressed = false
		if _action == "pet": _finish()
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode in [KEY_H, KEY_K, KEY_C, KEY_G]:
		if _action in ["pet", "hoof_hold"]: _finish()


func _unhandled_input(event: InputEvent) -> void:
	if not _available() or FLIGHT_INPUT.reserves_mouse(event, body): return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E:
		if _action == "hoof_hold":
			_finish(); get_viewport().set_input_as_handled(); return
		if _social_free():
			var offer := _select()
			if _begin_hoof(offer): get_viewport().set_input_as_handled()
		return
	if not event is InputEventMouseButton or not event.pressed: return
	if not _social_free() or not _action.is_empty(): return
	if event.button_index == MOUSE_BUTTON_LEFT:
		var offer := _select()
		if not offer.is_empty() and _begin(offer.kind, offer):
			_pressed = true; get_viewport().set_input_as_handled()
	elif event.button_index == MOUSE_BUTTON_RIGHT and Time.get_ticks_msec() >= _slap_until:
		var offer := _select(true)
		if _begin("slap", offer):
			_slap_until = Time.get_ticks_msec() + 450
			get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if not _available():
		_finish()
		if is_instance_valid(interactor) and is_instance_valid(interactor.held): interactor._drop()
		return
	if is_instance_valid(interactor) and is_instance_valid(interactor.held):
		_claim()
		var grip: Transform3D = interactor.held.get_grip_transform("chest")
		_present("carry", grip.origin, -camera.global_basis.z)
		return
	if _action.is_empty():
		_clear_hold_pose(); _unclaim(); return
	if not is_instance_valid(_target) or not _target.is_inside_tree() or camera.global_position.distance_to(_point) > TOUCH_REACH + .3:
		_finish(); return
	_time += delta
	if _action == "boop": _watch_finger()
	if _action == "hoof_hold":
		var hoof: RefCounted = _target.get("hoof_hold")
		if hoof == null or not hoof.active(): _finish(); return
		var goal: Vector3 = camera.to_global(_hoof_anchor)
		if not _clear_to(goal): _finish(); return
		hoof.update(goal); _point = hoof.grip().origin
		_present("hoof_hold", _point, _normal)
		return
	if _action == "pet":
		var current := _select()
		if not _pressed or current.is_empty() or current.target != _target: _finish(); return
		_point = current.point; _normal = current.normal; _offer = current
		var pose: Dictionary = presentation()
		_present("pet", pose.point, _normal)
		if _used:
			var touch: Node = _target.get("touch_body")
			if is_instance_valid(touch): touch.desktop_pet(str(current.region))
		return
	if (_used and _time >= .4) or _time >= 1.0: _finish()


func _action_contact(kind: String, _at: Vector3, _side: String) -> void:
	if kind != _action or _used or not _available() or not is_instance_valid(_target): return
	# A desktop boop always lands (dev 2026-10-14): her head turns to watch the finger come in,
	# so a fresh pick at contact time often found her cheek or nothing and the boop was lost.
	if kind == "boop":
		_used = true
		_target.boop()
		return
	var current := _select(kind == "slap")
	if current.is_empty() or current.target != _target: return
	if is_instance_valid(_avatar) and _avatar.hand_frame(_side).origin.distance_to(current.point) > .16: return
	_used = true; _point = current.point; _normal = current.normal
	if kind == "boop" and str(current.get("kind", "")) == "boop": _target.boop()
	elif kind == "slap": current.flank.desktop_impact(current)


func pony_acquired() -> void:
	_claim()


func pony_released() -> void:
	_clear_hold_pose(); _unclaim()


func presentation() -> Dictionary:
	if is_instance_valid(interactor) and is_instance_valid(interactor.held):
		var pony: Node3D = interactor.held
		var grip: Transform3D = pony.get_grip_transform("chest")
		return {"action": "carry", "target": pony, "point": grip.origin, "normal": -camera.global_basis.z,
			"helper": true, "progress": 1.0, "held": pony}
	if _action.is_empty() or not is_instance_valid(_target): return {}
	var point := _point
	if _action == "pet":
		# A held click produces an ordinary small stroke along the selected surface.
		var tangent := camera.global_basis.x - _normal * camera.global_basis.x.dot(_normal)
		if tangent.length_squared() > .001:
			point += tangent.normalized() * sin(maxf(0.0, _time-CONTACT_SECONDS)*TAU/STROKE_SECONDS) * .025
	return {"action": _action, "target": _target, "point": point, "normal": _normal,
		"helper": false, "progress": clampf(_time/CONTACT_SECONDS, 0.0, 1.0), "held": null}


func interaction_hint() -> Dictionary:
	if not _available(): return {}
	if is_instance_valid(interactor) and is_instance_valid(interactor.held):
		return {"target": interactor.held, "point": interactor.held.global_position,
			"text": "Tap G · Put down   Hold G, let go · Throw   %s · Turn around   Hold K · Kiss" % Settings.key_label("carry_turn", "B"), "outline": null, "visible_pick": true}
	if _action == "hoof_hold":
		return {"target": _target, "point": _point, "text": "E · Release hoof", "outline": null, "visible_pick": true}
	if not _social_free(): return {}
	var offer := _select()
	if offer.is_empty(): return {}
	var text := "Click · Boop" if offer.kind == "boop" else "Hold click · Stroke " + str(offer.region)
	var hoof: RefCounted = offer.target.get("hoof_hold")
	if hoof != null and not hoof.candidate(offer.point, .12).is_empty(): text += "   E · Hold hoof"
	if not _select(true).is_empty(): text += "   Right click · Smack"
	text += "   G · Carry"
	offer.text = text; offer.outline = null
	return offer


## While a boop comes in, her eyes follow his fingertip to her nose (dev 2026-10-14). Her own
## attention does the looking (action gaze), so near her nose her eyes cross onto the finger.
var _finger: Node3D

func _watch_finger() -> void:
	if not is_instance_valid(_avatar) or not is_instance_valid(_target) or not _target.has_method("set_action_gaze"): return
	var tip: Vector3 = _avatar.fingertip(str(_avatar.get("active_side")))
	if not tip.is_finite(): return
	if not is_instance_valid(_finger):
		_finger = Node3D.new(); _finger.name = "BoopFinger"; _finger.set_meta("boop_finger", true); add_child(_finger)
	_finger.global_position = tip
	if _target.get("action_gaze_target") != _finger: _target.set_action_gaze(_finger)

func _finish() -> void:
	if is_instance_valid(_target) and is_instance_valid(_finger) and _target.get("action_gaze_target") == _finger:
		_target.set_action_gaze(null)
	if is_instance_valid(_target):
		var touch: Node = _target.get("touch_body")
		if is_instance_valid(touch): touch.desktop_pet_end()
		if _action == "hoof_hold" and _target.get("hoof_hold") != null: _target.hoof_hold.release()
	if not _action.is_empty() and is_instance_valid(_avatar): _avatar.cancel_action()
	_clear_hold_pose()
	_action = ""; _target = null; _offer = {}; _pressed = false
	_unclaim()


func _clear_hold_pose() -> void:
	if _held_pose and is_instance_valid(_avatar):
		_avatar.clear_hold_target("right"); _avatar.clear_hold_target("left")
	_held_pose = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT: cancel_desktop_activity()


func _exit_tree() -> void:
	cancel_desktop_activity()
