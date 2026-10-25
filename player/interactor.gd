extends Node3D
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
## Player-side reach: what you are looking at, and what you can do to it.
##
## Lives on the camera so both rigs share it. In VR this is the wrong shape --
## reach should come from the hand, not the gaze -- but the verbs and the pony
## API are identical either way, so M6 replaces the ray and keeps everything
## below it.

const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
const REACH := 3.0
## Where a carried pony sits relative to the camera: low and forward, roughly
## where your arms would be. Carrying something at eye level looks like
## levitation.
const HOLD_OFFSET := Vector3(0.0, -0.45, -0.85)
## AnonPony has no arms to lift or throw a pony with (docs/ANONPONY_DESIGN_2026_10_01.md section 10).
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")

@export var pet_cooldown := 0.6

var held: Node3D
var _ray: RayCast3D
var _hold: Node3D
var _cooldown := 0.0
var _following := false
## Desktop semantic/presentation owner; null in XR and isolated older fixtures.
var desktop_actions: Node
## Carrying a pony, G is a wind-up (dev 2026-10-14): a tap puts her down; held, a meter by the
## crosshair fills green, orange, red, and letting go throws her that hard. Shift+G still
## throws at full strength at once.
const CHARGE_TAP := 0.25
const CHARGE_FULL := 1.4
var _charge_from := -1.0
var _meter: Control
## Holding K while carrying lifts her face to his (dev 2026-10-14: K did nothing while she sat
## at his chest, out of kissing reach). Closed loop on her lips; kept while the kiss lasts.
var _kiss_lift := Vector3.ZERO
## The carry-turn key (B by default) while carrying turns her round to face him; she rides a little further out so her face
## is not in his. Eased (0 = facing away, 1 = facing him); cleared when she leaves his arms.
const FACING_EXTRA_REACH := 0.25
const FACING_TURN_SECONDS := 0.45
var facing_player := false
var _facing := 0.0


func _ready() -> void:
	_ray = RayCast3D.new()
	_ray.target_position = Vector3(0, 0, -REACH)
	_ray.collide_with_areas = false
	_ray.collide_with_bodies = true
	# World is layer 1, ponies (and the hybrid's snoot) layer 2.
	_ray.collision_mask = 3
	add_child(_ray)

	_hold = Node3D.new()
	_hold.name = "HoldPoint"
	_hold.position = HOLD_OFFSET
	add_child(_hold)


func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(delta)
	if started > 0: CPU_PROFILE.record("interactor", started)

func _physics_step(delta: float) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	_update_kiss_lift(delta)
	_update_meter()
	_update_facing(delta)
	if is_instance_valid(held) and held.has_method("update_grab"):
		held.update_grab(_hold.global_position + _kiss_lift, global_position)
		if held.has_method("set_hold_yaw"):
			held.set_hold_yaw(global_basis.get_euler().y + PI * smoothstep(0.0, 1.0, _facing))


## G released: a short tap sets her down, a wind-up throws her (a menu may eat the key-up, so
## this listens before the GUI).
func _input(event: InputEvent) -> void:
	if _charge_from < 0.0 or not (event is InputEventKey) or event.pressed or (event as InputEventKey).physical_keycode != KEY_G: return
	var held_for := Time.get_ticks_msec() / 1000.0 - _charge_from
	_charge_from = -1.0
	if not is_instance_valid(held): return
	if held_for < CHARGE_TAP: _drop()
	else: _throw(charge(held_for))
	get_viewport().set_input_as_handled()


## Throw strength 0..1 after holding G for `held_for` seconds.
static func charge(held_for: float) -> float:
	return clampf((held_for - CHARGE_TAP) / (CHARGE_FULL - CHARGE_TAP), 0.0, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	var body: Node = get_parent()
	while body != null:
		if FLIGHT_INPUT.reserves_mouse(event,body): return
		if "controls_locked" in body and body.controls_locked: return
		body = body.get_parent()
	# A left click interacts like E (dev 2026-09-30: "clicking should be interact/use"): sit,
	# open a door, pet. The inventory takes the click first when a held thing has a use.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and _interact():
			get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	# Turn a carried pony round (Settings: "Turn carried pony", B by default).
	if is_instance_valid(held) and InputMap.has_action("carry_turn") and event.is_action_pressed("carry_turn"):
		facing_player = not facing_player
		get_viewport().set_input_as_handled()
		return
	match (event as InputEventKey).physical_keycode:
		KEY_E:
			if _interact(): get_viewport().set_input_as_handled()
		KEY_G:
			if PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree())):
				return
			if is_instance_valid(held) and event.shift_pressed:
				if _throw(1.0): get_viewport().set_input_as_handled()
			elif is_instance_valid(held):
				_charge_from = Time.get_ticks_msec() / 1000.0
				get_viewport().set_input_as_handled()
			elif held != null:
				if _drop(): get_viewport().set_input_as_handled()
			elif not is_instance_valid(desktop_actions) or desktop_actions.can_accept_world_action():
				if _try_pick_up(): get_viewport().set_input_as_handled()
		KEY_R:
			_toggle_follow()


## Sit or stand, open or close the door in view, else pet the pony in view. True when handled.
func _interact() -> bool:
	# An easel's canvas, tray or hooks: start painting (world/painting/easel_wake.gd).
	if _ray.is_colliding() and _ray.get_collider() != null and _ray.get_collider().has_meta("painting_easel"):
		var easel: Variant = _ray.get_collider().get_meta("painting_easel")
		if is_instance_valid(easel): return bool((easel as Node).call("desktop_begin"))
	if is_instance_valid(desktop_actions) and desktop_actions.busy(): return false
	if _try_seat(): return true
	if _ray.is_colliding() and _ray.get_collider().has_method("toggle_door"):
		_ray.get_collider().toggle_door()
		return true
	return _try_pet()

## E while seated stands up; E looking at a seat (within 1 m of where you look) sits down.
func _try_seat() -> bool:
	var body: Node = get_parent()
	while body != null and not body.has_method("sit_on"): body = body.get_parent()
	if body == null: return false
	if is_instance_valid(body.get("seat")):
		body.stand_up()
		return true
	if not _ray.is_colliding() or _ray.get_collider() is CharacterBody3D: return false
	var seating := get_tree().get_first_node_in_group("pony_seating")
	if seating == null or not seating.has_method("player_seat_near"): return false
	var seat: Node3D = seating.player_seat_near(_ray.get_collision_point(), 1.0, body, _ray.get_collider())
	return seat != null and body.sit_on(seat)

func _looking_at_pony() -> Node3D:
	if not _ray.is_colliding():
		return null
	var hit := _ray.get_collider()
	if hit == null:
		return null
	# The pony script lives on the CharacterBody3D itself.
	if hit.has_method("pet"):
		return hit
	var parent = hit.get_parent()
	return parent if parent != null and parent.has_method("pet") else null


## Body part is inferred from where the ray lands relative to her, so petting
## her head reads differently from petting her back without needing a separate
## collider per body part.
func _part_from_hit(pony: Node3D) -> String:
	var point := _ray.get_collision_point()
	var local: Vector3 = pony.global_transform.affine_inverse() * point
	if local.z < -0.25:
		return "head"
	if local.z > 0.3:
		return "flank"
	if local.y > 0.55:
		return "back"
	return "side"


func _try_pet() -> bool:
	# The contextual desktop owner selects actual nose/coat surfaces and owns its click.
	if is_instance_valid(desktop_actions): return false
	if _cooldown > 0.0:
		return false
	var pony := _looking_at_pony()
	if pony == null:
		return false
	var part := _part_from_hit(pony)
	pony.pet(part)
	_cooldown = pet_cooldown
	print("[interact] petted %s on the %s" % [pony.name, part])
	return true


func _try_pick_up() -> bool:
	var pony := _looking_at_pony()
	if pony == null:
		return false
	if pony.has_method("begin_grab"):
		pony.begin_grab("chest", _hold.global_position, global_position)
	else:
		pony.pick_up(_hold)
		pony.position = Vector3.ZERO
		pony.rotation = Vector3.ZERO
	held = pony
	# She keeps the way she faced him: facing him when lifted, she is held facing him (B turns her).
	var ahead := -pony.global_basis.z
	var to_him := global_position - pony.global_position
	ahead.y = 0.0; to_him.y = 0.0
	facing_player = ahead.dot(to_him) > 0.0
	_facing = 1.0 if facing_player else 0.0
	if is_instance_valid(desktop_actions): desktop_actions.pony_acquired()
	SOUNDS.play_at(pony, "prop_contact_cloth")
	print("[interact] picked up %s" % pony.name)
	return true


func _drop() -> bool:
	if held == null:
		return false
	if held.has_method("end_interaction"):
		held.end_interaction()
		held = null
		if is_instance_valid(desktop_actions): desktop_actions.pony_released()
		return true
	# Drop at her feet in front of the player rather than at the hold point, so
	# she lands on the ground instead of hovering where your hands were.
	var world := get_tree().current_scene
	var front := global_position + (-global_transform.basis.z * 1.2)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(front + Vector3.UP * 2.0,
		front + Vector3.DOWN * 6.0)
	q.exclude = [held.get_rid()]
	var hit := space.intersect_ray(q)
	var at: Vector3 = hit["position"] if hit.has("position") else front

	held.drop(at, world)
	print("[interact] dropped %s" % held.name)
	held = null
	if is_instance_valid(desktop_actions): desktop_actions.pony_released()
	return true


func _throw(power := 1.0) -> bool:
	if not is_instance_valid(held) or not held.has_method("throw_pony"): return false
	_charge_from = -1.0
	var momentum := -global_basis.z.normalized() * lerpf(3.0, 12.0, power) + Vector3.UP * lerpf(1.0, 3.0, power)
	if held.throw_pony(momentum):
		print("[interact] threw %s" % held.name)
		held = null
		if is_instance_valid(desktop_actions): desktop_actions.pony_released()
		return true
	return false


func _toggle_follow() -> void:
	var pony := _looking_at_pony()
	if pony == null:
		return
	# Hybrid/background ponies route through their Navigator child; the old native
	# mare and OpenPony actors answer follow()/stay() themselves.
	var mover: Node = pony if pony.has_method("follow") else pony.get_node_or_null("Navigator")
	if mover == null or not mover.has_method("follow"):
		print("[interact] %s cannot follow (no navigator)" % pony.name)
		return
	if mover == pony.get_node_or_null("Navigator"):
		mover.command_owner = "player:desktop-follow:%d" % Time.get_ticks_usec()
	_following = not _following
	if _following:
		mover.follow(get_parent().get_parent())
		print("[interact] %s is following" % pony.name)
	else:
		mover.stay()
		print("[interact] %s will stay" % pony.name)


func _update_kiss_lift(delta: float) -> void:
	if not is_instance_valid(held) or held.get_node_or_null("Affection") == null:
		_kiss_lift = Vector3.ZERO
		return
	var affection: Node = held.get_node("Affection")
	if affection.get("kind") == "kiss": return
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_physical_key_pressed(KEY_K):
		var mouth := global_position + global_basis.orthonormalized() * Vector3(0.0, -0.07, -0.02)
		var lips: Vector3 = affection.mouth_point()
		if lips.is_finite():
			_kiss_lift = (_kiss_lift + (mouth - lips) * minf(1.0, delta * 4.0)).limit_length(0.9)
		return
	_kiss_lift = _kiss_lift.move_toward(Vector3.ZERO, delta * 1.5)


## Eases her round toward (or away from) him and moves the hold point out to match.
func _update_facing(delta: float) -> void:
	if not is_instance_valid(held):
		facing_player = false
		_facing = 0.0
	else:
		_facing = move_toward(_facing, 1.0 if facing_player else 0.0, delta / FACING_TURN_SECONDS)
	_hold.position = HOLD_OFFSET + Vector3(0.0, 0.0, -FACING_EXTRA_REACH * smoothstep(0.0, 1.0, _facing))


## The throw meter by the crosshair while G winds up.
func _update_meter() -> void:
	var charging := _charge_from >= 0.0 and is_instance_valid(held)
	if not charging:
		if is_instance_valid(_meter): _meter.visible = false
		return
	var held_for := Time.get_ticks_msec() / 1000.0 - _charge_from
	if held_for < CHARGE_TAP:
		if is_instance_valid(_meter): _meter.visible = false
		return
	if not is_instance_valid(_meter):
		var layer := CanvasLayer.new(); layer.name = "ThrowMeter"; layer.layer = 20
		add_child(layer)
		_meter = ThrowMeter.new()
		layer.add_child(_meter)
	_meter.visible = true
	(_meter as ThrowMeter).value = charge(held_for)
	_meter.queue_redraw()


## A ring below the crosshair, filling clockwise, green to orange to red (Zelda's stamina wheel).
class ThrowMeter extends Control:
	var value := 0.0
	func _ready() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var centre := size * 0.5 + Vector2(0.0, 64.0)
		var radius := 22.0
		draw_arc(centre, radius, 0.0, TAU, 48, Color(0.0, 0.0, 0.0, 0.45), 9.0, true)
		var green := Color(0.35, 0.85, 0.3)
		var orange := Color(1.0, 0.62, 0.12)
		var red := Color(0.95, 0.22, 0.16)
		var colour := green.lerp(orange, value * 2.0) if value < 0.5 else orange.lerp(red, value * 2.0 - 1.0)
		if value > 0.001:
			draw_arc(centre, radius, -PI * 0.5, -PI * 0.5 + TAU * value, 48, colour, 6.0, true)

