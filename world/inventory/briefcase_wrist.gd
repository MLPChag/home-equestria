extends RefCounted
## Wrist buttons and the quick strip: palm-up and hand-flip gestures, placement on the forearm, and the desktop Tab panel.
## Split out of briefcase_inventory.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning briefcase_inventory node; shared state stays there.


var host: Node3D
var _gesture_time := 0.
var _gesture_armed := true
var _gesture_reset := 0.
var _quick_gesture_time := 0.0
var _quick_gesture_reset := 0.0
var _quick_gesture_armed := true


func _init(owner_node: Node3D) -> void:
	host = owner_node


func _wrist_input(side: String, sample: Dictionary) -> bool:
	if not host.wrist.visible:return false
	if side!="right":return false
	var normal_scale: float = host.wrist.global_basis.z.length()
	if not is_finite(normal_scale) or normal_scale<.0001:
		host._wrist_armed=false;host._wrist_tip=null;return true
	var p: Vector3 = host.wrist.to_local(sample.tip)
	if not p.is_finite():
		host._wrist_armed=false;host._wrist_tip=null;return true
	# Normal contact/rearm distances are metres, independent of forearm fitting.
	# XY stays in display coordinates so targets follow the physical buttons.
	var depth:=p.z*normal_scale
	# Arm from nearby clear space as well as a straight-on approach. The old
	# 3.5 cm front-only gate missed short pokes and fingers entering from the side.
	# Wider release bounds prevent hand jitter or sliding between icons retriggering.
	var clear_of_buttons := true
	var activated := false
	for i in 3:
		if absf(p.x-(i-.5)*host.WRIST_BUTTON_SPACING)<host.WRIST_TOUCH_HALF.x+host.WRIST_RELEASE_MARGIN and absf(p.y)<host.WRIST_TOUCH_HALF.y+host.WRIST_RELEASE_MARGIN:
			clear_of_buttons=false;break
	if depth>.023 or (depth>=-host.WRIST_TOUCH_HALF.z and clear_of_buttons):host._wrist_armed=true
	var hit:=p
	var crossed:=false
	if host._wrist_tip!=null:
		var previous:Vector3=host.wrist.to_local(host._wrist_tip)
		if previous.distance_to(p)>.5:
			host._wrist_armed=false;host._wrist_tip=sample.tip;return true
		var previous_depth:=previous.z*normal_scale
		if previous_depth>host.WRIST_TOUCH_HALF.z and depth<=host.WRIST_TOUCH_HALF.z:
			hit=previous.lerp(p,(previous_depth-host.WRIST_TOUCH_HALF.z)/(previous_depth-depth));crossed=true
	host._wrist_tip=sample.tip
	# Index extension depends on trigger, not on the other fingers' grip.
	if float(sample.trigger)<.3 and host._wrist_armed and (crossed or absf(depth)<=host.WRIST_TOUCH_HALF.z) and absf(hit.y)<host.WRIST_TOUCH_HALF.y:
		for i in 3:
			if absf(hit.x-(i-.5)*host.WRIST_BUTTON_SPACING)>=host.WRIST_TOUCH_HALF.x:continue
			if i==2 and host.inspector==null:break
			activated=true
			host._wrist_armed=false
			match i:
				0:host.summon(true)
				1:host._open_clothes()
				2:host.inspector.toggle()
			host._haptic(side)
			break
	return activated


func _gesture(sample: Dictionary, delta: float):
	if host._desktop:
		_gesture_time=0.
		if not host._desktop_wrist:_hide_wrist_mount()
		return
	if host.hud_hidden or not sample.get("active",false) or (host.hand_busy("left") and not host.held.has("left")) or host._map_open() or host.customizer.opened:
		_gesture_time=0.;_hide_wrist_mount();return
	var pose:Transform3D=sample.pose
	var to_face:Vector3=host.camera.global_position-pose.origin
	var distance:=to_face.length()
	var facing := _gesture_side(sample, pose)
	var intentional: bool = distance>.18 and distance<.65 and pose.origin.y>host.camera.global_position.y-.48 \
		and facing.dot(Vector3.UP)>.35 \
		and facing.dot(to_face.normalized())>.55 \
		and (-host.camera.global_basis.z).dot(-to_face.normalized())>.55 \
		and float(sample.grip)<.25 and float(sample.trigger)<.25
	if intentional:
		_gesture_reset=0.;_gesture_time+=delta
		if _gesture_armed and _gesture_time>=.35:
			_gesture_armed=false
			host.wrist.visible=_place_wrist(pose);host._wrist_armed=false;host._wrist_tip=null;host._haptic("left")
	else:
		_gesture_time=0.;_gesture_reset+=delta
		if _gesture_reset>.4:_gesture_armed=true;host.wrist.hide()
	if host.wrist.visible:_place_wrist(pose)


## Re-place after the skeleton modifiers, in the same frame as the visible sleeve.
func _sync_arm_panels()->void:
	if host._desktop or not host.is_inside_tree() or host.is_queued_for_deletion() or host.hotbar==null:return
	_place_hotbar()
	if host.wrist.visible and not _head_hud():
		var sample: Dictionary = host.hand_sample("left")
		if sample.get("active",false):_place_wrist(sample.pose)
		else:_hide_wrist_mount()


func _hide_wrist_mount()->void:
	host.wrist.hide();host._wrist_armed=false;host._wrist_tip=null


func _place_wrist(pose:Transform3D)->bool:
	if not pose.is_finite() or absf(pose.basis.determinant())<.0001 or not is_instance_valid(host.camera):
		_hide_wrist_mount();return false
	# Restore the original floating popup: above the hand, facing the viewer with
	# world-up, independent of forearm roll, sleeve thickness and avatar proportions.
	var at: Vector3 = pose.origin+Vector3.UP*host.WRIST_HAND_CLEARANCE
	var direction: Vector3 = host.camera.global_position-at
	if not direction.is_finite() or direction.length_squared()<.0001 or Vector2(direction.x,direction.z).length_squared()<.000001:
		_hide_wrist_mount();return false
	var target:=Transform3D(Basis.looking_at(direction.normalized(),Vector3.UP,true),at)
	if host.wrist.global_position.distance_to(target.origin)>.5:
		host._wrist_armed=false;host._wrist_tip=null
	host.wrist.global_transform=target
	return true


## Inventory now belongs to hand-summoned world panels, never the head HUD.
func _head_hud() -> bool:
	return false


func _quick_blocked() -> bool:
	return host.hud_hidden or host._map_open() or host.customizer.opened or host.case.visible or (host.inspector != null and host.inspector.active)


## The hand side the wrist gestures look for. The sampled "palm" was reversed until 2026-10-15
## (it pointed out of the back of the hand) and these gestures were tuned on it; dev keeps that
## feel, so they still use the back of the visible hand. The physics-hand fallback is unchanged.
func _gesture_side(sample: Dictionary, pose: Transform3D) -> Vector3:
	if sample.has("palm"): return -Vector3(sample.palm).normalized()
	return -pose.basis.y


func _flip_up(sample: Dictionary) -> bool:
	if not sample.get("active", false) or not is_instance_valid(host.camera): return false
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	var palm := _gesture_side(sample, pose)
	if not pose.is_finite() or not palm.is_finite() or absf(pose.basis.determinant()) < .0001: return false
	var to_face: Vector3 = host.camera.global_position - pose.origin
	var distance := to_face.length()
	return distance > .18 and distance < .85 and pose.origin.y > host.camera.global_position.y - .6 and palm.normalized().dot(Vector3.UP) > .35 and palm.normalized().dot(to_face.normalized()) > .45 and (-host.camera.global_basis.z).dot(-to_face.normalized()) > .35


func _quick_gesture(sample: Dictionary, delta: float) -> void:
	if host._desktop: return
	var intentional := _flip_up(sample)
	if not intentional:
		_quick_gesture_time = 0.0
		_quick_gesture_reset += delta
		if _quick_gesture_reset > .3:
			_quick_gesture_armed = true; _dismiss_quick_strip()
		return
	_quick_gesture_reset = 0.0
	if _quick_blocked() or host.hand_busy("right") or float(sample.get("grip", 0.0)) >= .25 or float(sample.get("trigger", 0.0)) >= .25:
		_quick_gesture_time = 0.0
		return
	_quick_gesture_time += delta
	if _quick_gesture_armed and _quick_gesture_time >= .25:
		_quick_gesture_armed = false
		if not host._quick_open: host._summon_quick_strip(sample.pose)


func _grab_snapshot() -> Dictionary:
	var result := {}
	for side: String in host.SIDES:
		if host.held.has(side): result[side + "_item"] = host.held[side].get_instance_id()
		if host.holding_case == side: result[side + "_case"] = host.case.get_instance_id()
		var hand: Node = host.hands.get(side)
		if is_instance_valid(hand) and "held_object" in hand and is_instance_valid(hand.held_object):
			result[side + "_physics"] = hand.held_object.get_instance_id()
		if is_instance_valid(host.pony_grabber) and host.pony_grabber.is_holding(side): result[side + "_pony"] = true
	return result


func _dismiss_quick_strip() -> void:
	host._quick_open = false
	if host.hotbar != null:
		host.hotbar.hide(); host.hotbar.hover(-1)


func _place_hotbar():
	if host._desktop:
		host.hotbar.set_hud_visible(not host.hud_hidden and not host._map_open() and not host.customizer.opened)
		return
	if not host._quick_open:
		host.hotbar.hide(); return
	var moved := Vector2(host.camera.global_position.x - host._quick_origin.x, host.camera.global_position.z - host._quick_origin.z).length()
	var grabbed := false
	var current := _grab_snapshot()
	for key: String in current:
		if current[key] != host._quick_grabs.get(key): grabbed = true; break
	if _quick_blocked() or moved > host.QUICK_WALK_AWAY or grabbed: _dismiss_quick_strip()


func _toggle_desktop_wrist(open: bool) -> void:
	if open and not host._release_desktop_activity():return
	if not host._desktop or open == host._desktop_wrist or host.wrist == null: return
	if open:
		if not is_instance_valid(host.camera): return
		if host.case.visible or host.customizer.opened or (host.inspector != null and host.inspector.active) or host._map_open(): return
		if is_instance_valid(host.player_body) and "controls_locked" in host.player_body and host.player_body.controls_locked: return
		host._desktop_wrist = true
		var view: Transform3D = host.camera.global_transform
		var at := view.origin - view.basis.z * 0.42 - view.basis.y * 0.03
		host.wrist.global_transform = Transform3D(view.basis.orthonormalized(), at - view.basis.x * host.WRIST_BUTTON_SPACING * 0.5)
		host.wrist.show()

		host._wrist_mouse_before = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if is_instance_valid(host.player_body) and "controls_locked" in host.player_body:
			host._wrist_lock_owned = true; host.player_body.controls_locked = true
		host._play_select()
		return
	host._desktop_wrist = false
	host.wrist.hide()
	if host._wrist_lock_owned and is_instance_valid(host.player_body): host.player_body.controls_locked = false
	host._wrist_lock_owned = false
	Input.mouse_mode = host._wrist_mouse_before


func _desktop_wrist_click(pixel: Vector2) -> void:
	var origin: Vector3 = host.camera.project_ray_origin(pixel)
	var direction: Vector3 = host.camera.project_ray_normal(pixel)
	var normal: Vector3 = host.wrist.global_basis.z.normalized()
	var facing := normal.dot(direction)
	if absf(facing) < 0.0001: return
	var t := normal.dot(host.wrist.global_position - origin) / facing
	if t < 0.0: return
	var p: Vector3 = host.wrist.to_local(origin + direction * t)
	for i in 3:
		if absf(p.x - (i - .5) * host.WRIST_BUTTON_SPACING) >= host.WRIST_TOUCH_HALF.x or absf(p.y) >= host.WRIST_TOUCH_HALF.y: continue
		if i == 2 and host.inspector == null: return
		_toggle_desktop_wrist(false)
		match i:
			0: host.summon(true)
			1: host._open_clothes()
			2: host.inspector.toggle()
		return
