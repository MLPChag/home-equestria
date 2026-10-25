extends Node
## AnonPony unicorn telekinesis (dev 2026-10-01: "unicorns use magic"). G lifts what the view
## points at within RANGE: a loose physics object, or a pony (the same chest hold a human's hands
## use, pony_locomotion.begin_grab). It floats where it was caught, at that distance along the
## view, in the horn's glow. G again sets it down where it is; Shift+G throws an object (a pony is
## set down). For a human G is the interactor's pick-up; ponies used to ignore it.
## Added by player/pony_form.gd for unicorns only. The lift, follow and release are the shared
## magic hold (player/magic_hands/telekinesis_hold.gd), which the VR magic hands use too.
const HOLD := preload("res://player/magic_hands/telekinesis_hold.gd")
const RANGE := 8.0
const MIN_DISTANCE := 1.3
const THROW_SPEED := 10.0
var form: Node
var rig: Node3D
## The lifted thing, or null (read by tools/life/pony_powers_run.gd).
var target: Node3D
var distance := 2.0
var _hold := HOLD.new()

func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.physical_keycode != KEY_G: return
	if not is_instance_valid(rig) or bool(rig.get("controls_locked")): return
	get_viewport().set_input_as_handled()
	if is_instance_valid(target): _release(key.shift_pressed)
	else: _lift()

func _camera() -> Camera3D:
	return rig.get("camera") as Camera3D if is_instance_valid(rig) else null

func _lift() -> void:
	var camera := _camera()
	if camera == null: return
	var from := camera.global_position
	var to := from - camera.global_basis.z * RANGE
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var exclude: Array[RID] = []
	for body: Variant in [rig, form.get("avatar")]:
		if body is CollisionObject3D: exclude.append((body as CollisionObject3D).get_rid())
	query.exclude = exclude
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		print("[magic] nothing in reach to lift")
		return
	var thing: Object = hit.collider
	var liftable: Node3D = HOLD.liftable(thing, form.get("avatar"))
	if liftable == null:
		print("[magic] %s will not lift" % (thing as Node).name if thing is Node else "[magic] that will not lift")
		return
	distance = clampf(from.distance_to(hit.position), MIN_DISTANCE, RANGE)
	if not _hold.begin(liftable, from - camera.global_basis.z * distance, from, form.call("magic")): return
	target = liftable
	print("[magic] lifting ", target.name)

func _physics_process(_delta: float) -> void:
	if target == null: return
	if not is_instance_valid(target) or not is_instance_valid(rig):
		_release(false)
		return
	var camera := _camera()
	if camera == null: return
	if not _hold.follow(camera.global_position - camera.global_basis.z * distance, camera.global_position, RANGE * 1.5):
		_release(false)

func _release(throw: bool) -> void:
	var camera := _camera()
	var velocity: Variant = null
	if throw and camera != null: velocity = -camera.global_basis.z * THROW_SPEED
	if is_instance_valid(target):
		print("[magic] ", "threw " if throw and not target.has_method("end_interaction") else "set down ", target.name)
	_hold.end(velocity)
	target = null

func _exit_tree() -> void:
	if target != null: _release(false)
