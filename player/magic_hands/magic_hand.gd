extends Node3D
## One VR magic hand (dev 2026-10-15: "your hands in vr as the pony are like, really tiny small
## magic aura elements where when you grab something it does the pony magic thing"). It rides a
## controller's palm (player/magic_hands/magic_hands.gd makes both) and shows as a wisp: the GMod
## magic aura (world/characters/magic/magic_aura.gd) a few centimetres across, silent, around a
## tiny bright core, in the player pony's magic colour. It brightens when something in reach would
## lift, and while it holds.
##
## Grip (xr_grounded_controller.gd's hysteresis, the same as the human hands) takes, in order:
## 1. a door handle at the wisp: the door swings with the wisp (hinged_door begin_grip/drag) and
##    the handle flares in her magic (hinged_door.magic_glow);
## 2. what a human hand would take there (world/inventory/grab_targets.gd: nearest at the palm,
##    else what the controller points at): loose items and food on the ground;
## 3. any pony or loose physics thing touching the wisp, else one the controller points at within
##    RANGE (the unicorn's telekinesis reach).
## Things are lifted with the shared magic hold (telekinesis_hold.gd): the thing glows in her
## magic (a unicorn's horn lights too), floats at the wisp and turns with it. Letting go drops it
## with the controller's velocity; a pony let go fast is thrown (pony_grabber.gd's numbers).
const HOLD := preload("res://player/magic_hands/telekinesis_hold.gd")
const GRAB_TARGETS := preload("res://world/inventory/grab_targets.gd")
const DOOR_GRIP := preload("res://player/door_grip.gd")
const MAGIC_AURA := preload("res://world/characters/magic/magic_aura.gd")
const UNICORN_MAGIC := preload("res://world/characters/magic/unicorn_magic.gd")
const INVENTORY := preload("res://player/magic_hands/magic_inventory.gd")
## The wisp: aura radius (about 5 cm across) and its core.
const WISP_RADIUS := 0.025
const CORE_RADIUS := 0.006
const IDLE_STRENGTH := 0.5
const HOVER_STRENGTH := 0.8
const HOLD_STRENGTH := 1.0
## Aura strength on the held thing: an arm's length away, between the far-away look (1.0) and
## her own mouth-held item (briefcase_magic.gd OWN_AURA 0.3).
const HELD_AURA := 0.6
## Touch reach around the wisp, and the pointing reach and cone.
const REACH := 0.2
const RANGE := 8.0
## A thing caught close keeps its place against the wisp up to this far; farther ones fly in.
const MAX_OFFSET := 0.12
## A held thing stuck this far from the wisp (behind a wall) is let go.
const LOSE_DISTANCE := 2.0
## A door handle farther than this from the wisp is let go (door_grip.gd).
const DOOR_LOSE := 0.8
## Pony throws: tracking-space hand speed, as pony_grabber.gd.
const PONY_THROW_THRESHOLD := 2.0
const PONY_THROW_GAIN := 1.7
const SAMPLE_SECONDS := 0.1
const HOVER_INTERVAL := 0.1

var side := "left"
## The MagicHands owner (form, rig, colour, inventory).
var hands: Node
var controller: XRController3D
## The held thing (an object or a pony), or null. Read by tests and hints.
var held: Node3D
## The door whose handle this wisp turns, or null.
var door: Node

var _hold := HOLD.new()
var _inventory := INVENTORY.new(self)
## One offer drives both the blue outline and the next grip. Invalidated on every ownership,
## tracking or input-state change; geometry is rechecked without selecting a different object.
var _offer: Dictionary = {}
var _offset := Transform3D.IDENTITY
## How far from the wisp the held thing may be before it counts as stuck: wide while a pointed
## thing flies in, LOSE_DISTANCE once it is close.
var _lose := LOSE_DISTANCE
var _aura: Node3D
var _core: MeshInstance3D
var _strength := IDLE_STRENGTH
var _hovering := false
var _hover_left := 0.0
var _last_pose := Transform3D.IDENTITY
var _has_pose := false
## [world position, origin-space position, seconds] over the last SAMPLE_SECONDS.
var _samples: Array = []
var _previous_world := Vector3.INF
var _previous_local := Vector3.INF
var _use_down := false


func _ready() -> void:
	process_physics_priority = 950
	_core = MeshInstance3D.new()
	_core.name = "WispCore"
	var sphere := SphereMesh.new()
	sphere.radius = CORE_RADIUS; sphere.height = CORE_RADIUS * 2.0
	sphere.radial_segments = 8; sphere.rings = 4
	_core.mesh = sphere
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = UNICORN_MAGIC.vivid(_color()).lerp(Color.WHITE, 0.45)
	material.disable_fog = true
	_core.material_override = material
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_core)
	_aura = MAGIC_AURA.create(self, _color(), IDLE_STRENGTH, WISP_RADIUS, true)
	if _aura != null: _aura.name = "MagicWisp" + side.capitalize()
	_show(false)


func _exit_tree() -> void:
	release(false)
	if is_instance_valid(_aura): _aura.queue_free()


func _color() -> Color:
	return hands.get("color") if is_instance_valid(hands) else Color.MEDIUM_PURPLE


## The wisp is drawn: tracked and the player pony shown.
func shown() -> bool:
	return is_instance_valid(_core) and _core.visible


func holding() -> bool:
	return _hold.holding() or is_instance_valid(door)


## The palm pose this tick; the last finite one while tracking blinks (XR finite-pose guard).
func _pose() -> Transform3D:
	var pose := global_transform
	if pose.is_finite() and _tracked():
		_last_pose = pose; _has_pose = true
	return _last_pose


func _tracked() -> bool:
	if not is_instance_valid(controller) or not controller.get_has_tracking_data() or not controller.global_transform.is_finite(): return false
	var pose := controller.get_pose()
	return pose == null or pose.tracking_confidence != XRPose.XR_TRACKING_CONFIDENCE_NONE


func _head() -> Vector3:
	return hands.call("head") if is_instance_valid(hands) else global_position


func _physics_process(delta: float) -> void:
	var active: bool = is_instance_valid(hands) and hands.call("active") == true
	var tracked := _tracked()
	var pose := _pose()
	_show(active and tracked)
	_sample(delta, tracked)
	# Sample even while menus/tracking block use: reopening a menu or reacquiring
	# tracking with a squeezed trigger must not deploy an item without a new pull.
	var use_down: bool = is_instance_valid(controller) and controller.get_float("trigger") > (.3 if _use_down else .7)
	var use_pressed: bool = use_down and not _use_down
	_use_down = use_down
	if active and tracked and hands.call("can_grab") == true and use_pressed and _inventory.lay_out_blanket():
		_hold.end(Vector3.ZERO)
		held = null
		_offer.clear()
		hands.call("sync_horn")
	if _inventory.managed() and not _inventory.tick(delta, active and tracked and hands.call("can_grab") == true):
		_inventory.reconcile()
		_hold.end()
		held = null
		hands.call("sync_horn")
	if _hold.stale():
		# Eaten, stashed or freed while held: the glow and the horn go out with it.
		_hold.end()
		held = null
		hands.call("sync_horn")
	if not active:
		_offer.clear()
		release(false)
		return
	if is_instance_valid(door):
		var point := pose.origin
		if not door.is_inside_tree(): release(false)
		else:
			var contact: Vector3 = door.call("grip_point", point)
			if point.distance_to(contact) > DOOR_LOSE: release(false)
			elif tracked: door.call("drag", point)
	elif _hold.holding():
		# Untracked for a moment: the thing keeps floating at the last good pose.
		var goal: Variant = pose * _offset
		if _hold.target.has_method("update_grab"): goal = pose.origin
		if not _hold.follow(goal, _head(), _lose):
			release(false)
		elif _hold.holding():
			var at: Vector3 = (goal as Transform3D).origin if goal is Transform3D else goal
			_lose = maxf(LOSE_DISTANCE, minf(_lose, _hold.target.global_position.distance_to(at) * 1.5))
	elif tracked and _has_pose:
		_hover_left -= delta
		if _hover_left <= 0.0:
			_hover_left = HOVER_INTERVAL
			_offer = _choose(pose, controller.global_transform)
			_hovering = not _offer.is_empty()
	elif not tracked:
		_hovering = false
	if holding() or not tracked or hands.call("can_grab") != true:
		_offer.clear()
		_hovering = false
	held = _hold.target if _hold.holding() else null
	var want := HOLD_STRENGTH if holding() else (HOVER_STRENGTH if _hovering else IDLE_STRENGTH)
	_strength = move_toward(_strength, want, delta * 4.0)
	if is_instance_valid(_aura): _aura.set("strength", _strength)


func _show(on: bool) -> void:
	if is_instance_valid(_core): _core.visible = on
	if is_instance_valid(_aura): _aura.visible = on


# ------------------------------------------------------------------ grab and release

## xr_grounded_controller.gd's grab signal (grip with hysteresis).
func _on_grab(down: bool) -> void:
	if down: grab()
	else: release(true)


## Takes the best thing at or pointed at by the wisp. True when something was taken.
func grab() -> bool:
	if holding() or not is_instance_valid(hands) or hands.call("can_grab") != true or not _tracked(): return false
	var pose := _pose()
	var aim := controller.global_transform
	if not pose.is_finite() or not aim.is_finite(): return false
	# Commit the displayed offer, or select once if no outline has been sampled yet.
	var pick := _offer.duplicate() if not _offer.is_empty() else _choose(pose, aim)
	if not _offer_valid(pick, pose, aim):
		_offer.clear()
		return false
	var handle: Node = pick.get("target") if str(pick.get("kind", "")) == "door" else null
	if handle != null and handle.call("begin_grip", self, pose.origin) == true:
		door = handle
		_offer.clear()
		if handle.has_method("magic_glow"): handle.call("magic_glow", _color(), 1.2, _head())
		var magic: Node = hands.call("magic")
		if is_instance_valid(magic) and magic.has_method("cast"): magic.call("cast", 1.2)
		_haptic()
		print("[magic hands] %s turns the handle of %s" % [side, handle.name])
		return true
	if handle != null: return false
	# 2. What a human hand would take here, then 3. anything liftable touching or pointed at.
	if pick.is_empty(): return false
	var thing: Node3D = _inventory.take(pick, pick.get("grab_pose", pose))
	if thing == null: return false
	var near := not bool(pick.get("pointed", false))
	_offset = pose.affine_inverse() * thing.global_transform
	if not near: _offset.origin = Vector3.ZERO
	elif _offset.origin.length() > MAX_OFFSET: _offset.origin = _offset.origin.normalized() * MAX_OFFSET
	var goal: Vector3 = pose.origin if thing.has_method("begin_grab") else (pose * _offset).origin
	if not _hold.begin(thing, goal, _head(), hands.call("magic"), _color(), HELD_AURA): return false
	_lose = maxf(LOSE_DISTANCE, thing.global_position.distance_to(goal) * 1.5)
	held = thing
	_offer.clear()
	hands.call("sync_horn")
	_haptic()
	print("[magic hands] %s lifts %s%s" % [side, thing.name, "" if near else " from afar"])
	return true


## Lets go. `throw`: with the controller's velocity (a fast pony is thrown); false sets it down
## as it is (lost tracking, a menu, the thing out of reach).
func release(throw := true) -> void:
	_offer.clear()
	_hover_left = 0.0
	if is_instance_valid(door):
		door.call("end_grip")
		print("[magic hands] %s lets go of the handle" % side)
	door = null
	if _hold.holding():
		if _inventory.managed() and not _inventory.release(throw and _tracked()): return
		var world := _velocity(0) if throw else Vector3.ZERO
		var pony_throw := Vector3.ZERO
		if throw and _hold.target.has_method("end_interaction"):
			var hand_speed := _velocity(1)
			if hand_speed.length() >= PONY_THROW_THRESHOLD: pony_throw = hand_speed * PONY_THROW_GAIN
		var velocity: Variant = null
		if throw: velocity = world
		var was: Node3D = _hold.end(velocity, pony_throw)
		held = null
		if was != null: print("[magic hands] %s lets go of %s (%.1f m/s)" % [side, was.name, world.length()])
		if is_instance_valid(hands): hands.call("sync_horn")
	held = null
	_inventory.forget()


func _haptic() -> void:
	if is_instance_valid(controller) and controller.get_is_active():
		controller.trigger_haptic_pulse("haptic", 0.0, 0.22, 0.035, 0.0)


# ------------------------------------------------------------------ choosing

## {"target", "pointed"} for the thing a grip takes now, or {}.
func _pick(pose: Transform3D, aim: Transform3D) -> Dictionary:
	var own: Node = hands.call("avatar")
	var inventory: Node = hands.call("inventory")
	if is_instance_valid(inventory) and "held" in inventory and "loose" in inventory:
		var offer: Dictionary = GRAB_TARGETS.pick(inventory, pose, aim)
		var shared: Node3D = _usable(offer.get("target"), own)
		if shared != null: return offer
	var touching := _touching(pose.origin, own)
	if touching != null: return _classify(touching, false)
	var pointed := _pointed(pose.origin, -aim.basis.z.normalized(), own)
	if pointed != null: return _classify(pointed, true)
	return {}


func _choose(pose: Transform3D, aim: Transform3D) -> Dictionary:
	if not is_instance_valid(hands) or hands.call("can_grab") != true: return {}
	var handle: Node3D = DOOR_GRIP.reachable_in(get_tree(), pose.origin) as Node3D
	if handle != null:
		var outline: Node3D = handle.get_node_or_null("OutsidePullCollision") as Node3D
		return {"target": handle, "kind": "door", "outline": outline, "text": "Grip · Open", "point": handle.call("grip_point", pose.origin)}
	var pick := _pick(pose, aim)
	if not pick.is_empty():
		pick["text"] = "Grip · Take book" if str(pick.get("kind", "")) == "book" else "Grip · Pick up"
		pick["grab_pose"] = pose
		pick["grab_aim"] = aim
	return pick


func grab_offer() -> Dictionary:
	if holding() or not _tracked() or not is_instance_valid(hands) or hands.call("can_grab") != true: return {}
	return _offer if _offer_valid(_offer, _pose(), controller.global_transform) else {}


func _classify(thing: Node3D, pointed: bool) -> Dictionary:
	var pick := {"target": thing, "pointed": pointed}
	if thing.is_in_group("world_food"): pick["kind"] = "food"
	elif thing.is_in_group("shelf_books"): pick["kind"] = "book"
	elif thing.has_meta("token"):
		var bag: Node = hands.call("inventory")
		if not is_instance_valid(bag) or bag.loose.get(str(thing.get_meta("token"))) != thing: return {}
		pick["kind"] = "loose"
	return pick


func _offer_valid(pick: Dictionary, pose: Transform3D, aim: Transform3D) -> bool:
	var target: Node3D = pick.get("target") as Node3D
	if not is_instance_valid(target) or target.is_queued_for_deletion() or not target.is_inside_tree(): return false
	if str(pick.get("kind", "")) == "door": return target.call("can_grip", pose.origin) == true
	if _usable(target, hands.call("avatar")) == null: return false
	# As with the shared human router, commit the palm/aim that produced the displayed
	# offer. A small motion within its tenth-second sample must not invalidate its glow.
	# Tracking loss, menu state and ownership changes still clear the offer immediately.
	pose = pick.get("grab_pose", pose)
	aim = pick.get("grab_aim", aim)
	if not bool(pick.get("pointed", false)):
		if str(pick.get("kind", "")) == "food": return GRAB_TARGETS.FOOD.clear_reach(target, pose.origin, GRAB_TARGETS.FOOD.GRASP_REACH)
		return GRAB_TARGETS.surface_distance(target, pose.origin) <= REACH
	if pose.origin.distance_to(target.global_position) > RANGE: return false
	if _pointed(pose.origin, -aim.basis.z.normalized(), hands.call("avatar")) == target: return true
	var bag: Node = hands.call("inventory")
	return is_instance_valid(bag) and GRAB_TARGETS.pointed(bag, aim.origin, -aim.basis.z.normalized()).get("target") == target


## `candidate` as magic would lift it, or null: not the caster, not held by the other hand or her
## horn, and not a good for sale (buying goes through the shop, which these hands cannot reach).
func _usable(candidate: Variant, own: Node) -> Node3D:
	if not candidate is Object or not is_instance_valid(candidate): return null
	var thing: Node3D = candidate as Node3D if candidate is Node3D and candidate.is_in_group("shelf_books") else HOLD.liftable(candidate as Object, own)
	if thing == null or not thing.is_inside_tree(): return null
	if thing.is_in_group("shop_items") or bool(thing.get_meta("food_for_sale", false)) \
			or bool(thing.get_meta("shop_claiming", false)) or bool(thing.get_meta("food_claiming", false)):
		return null
	if hands.call("taken", thing, self) == true: return null
	return thing


func _excluded() -> Array[RID]:
	var rids: Array[RID] = []
	var list: Array = hands.call("excluded")
	for rid: Variant in list:
		if rid is RID: rids.append(rid)
	return rids


func _touching(point: Vector3, own: Node) -> Node3D:
	if not point.is_finite() or not is_inside_tree(): return null
	var sphere := SphereShape3D.new()
	sphere.radius = REACH
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, point)
	query.exclude = _excluded()
	query.collide_with_areas = false
	var best: Node3D = null
	var best_gap := INF
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query, 16):
		var thing := _usable(hit.get("collider"), own)
		if thing == null: continue
		var gap := thing.global_position.distance_to(point)
		if gap < best_gap: best = thing; best_gap = gap
	return best


func _pointed(origin: Vector3, direction: Vector3, own: Node) -> Node3D:
	if not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.5 or not is_inside_tree(): return null
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * RANGE)
	query.exclude = _excluded()
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty(): return null
	return _usable(hit.get("collider"), own)


# ------------------------------------------------------------------ velocity

## World and origin-space positions of the wisp over the last SAMPLE_SECONDS. A tracking jump
## (over 25 m/s) starts again rather than becoming a throw.
func _sample(delta: float, tracked: bool) -> void:
	if not tracked or delta <= 0.0 or delta > 0.1:
		_samples.clear(); _previous_world = Vector3.INF; return
	var world := global_position
	var origin := controller.get_parent() as Node3D
	var local := controller.position if origin != null else world
	if _previous_world.is_finite():
		var step_world := world - _previous_world
		var step_local := local - _previous_local
		if step_world.length() / delta > 25.0 or step_local.length() / delta > 25.0:
			_samples.clear()
		else:
			_samples.append([step_world, step_local, delta])
			var span := 0.0
			for row: Array in _samples: span += float(row[2])
			while _samples.size() > 1 and span > SAMPLE_SECONDS:
				span -= float(_samples[0][2]); _samples.pop_front()
	_previous_world = world; _previous_local = local


## Average velocity: 0 the wisp in the world (walking and turning carry a dropped thing along),
## 1 the controller against the tracking origin turned to the world (only the arm's swing).
func _velocity(kind: int) -> Vector3:
	var motion := Vector3.ZERO
	var span := 0.0
	for row: Array in _samples:
		motion += row[kind]; span += float(row[2])
	if span < 0.03: return Vector3.ZERO
	var velocity := motion / span
	if kind == 1:
		var origin := controller.get_parent() as Node3D if is_instance_valid(controller) else null
		if origin != null: velocity = origin.global_basis.orthonormalized() * velocity
	return velocity if velocity.is_finite() else Vector3.ZERO
