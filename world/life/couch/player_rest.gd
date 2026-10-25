extends Node
## Translate the rig during a deliberate recline; tracked camera/hands keep their local poses.
## The same scalar animation drives Anon's ordinary IK targets, never bone lengths.
const SETTLE = preload("res://world/life/couch/settle.tres")
var couch: Node3D
var player: Node3D
var seat: Node3D
var camera: Camera3D
var avatar: Node3D
var amount := 0.0
var _seconds := 0.0
var _applied := Vector3.ZERO
var _offset := Vector3.ZERO
var _temporary_avatar := false
var _left: Node3D
var _right: Node3D
var _finished := false
var _exiting := false
var _desktop := false
var _waking := false
## Sleep may end while the tracked head is still outside the mattress. Rearm
## automatic get-up only after it returns, so waking cannot defer a rig jump.
var _roomscale_exit_suspended := false
## VR: lying down for real must not sink the view into the mattress; the rig lifts instead.
var _lift := 0.0

func configure(owner_couch: Node3D, body: Node3D, spot: Node3D, eye: Camera3D, visible_body: Node3D) -> void:
	couch = owner_couch
	player = body
	seat = spot
	camera = eye
	avatar = visible_body
	_desktop = not camera is XRCamera3D

func _ready() -> void:
	if _desktop:
		# Desktop normally has no body. Supply the same accepted avatar for this physical rest.
		_left = Node3D.new(); _left.name = "RestLeftHand"; add_child(_left)
		_right = Node3D.new(); _right.name = "RestRightHand"; add_child(_right)
		if avatar == null:
			avatar = load("res://player/anon_body.tscn").instantiate()
			avatar.name = "CouchAnonBody"
			avatar.calibration_path = ""
			player.add_child(avatar)
			avatar.setup(camera, _left, _right)
			_temporary_avatar = true
	if avatar != null:
		avatar.couch_rest_frame = couch.rest_frame(seat)
		avatar.couch_rest_amount = 0.0
		if _desktop and is_instance_valid(avatar.get("desktop_pose_driver")):
			avatar.desktop_pose_driver.set_rest_hand_targets(_left, _right)
	_offset = couch.sleep_eye(seat) - camera.global_position
	_update_hands()

func _physics_process(delta: float) -> void:
	if _finished: return
	if not is_instance_valid(couch) or not is_instance_valid(seat):
		player.stand_up()
		return
	if couch.extension < 0.99: return
	_seconds = clampf(_seconds + (-delta * 1.5 if _waking else delta), 0.0, SETTLE.length)
	amount = float(SETTLE.value_track_interpolate(0, _seconds))
	var offset := _offset * amount + Vector3.UP * _lift
	player.global_position += offset - _applied
	_applied = offset
	if not _desktop:
		var below: float = float(couch.rest_floor(seat)) - camera.global_position.y
		if is_finite(below) and below > 0.0:
			_lift += below
			_applied.y += below
			player.global_position.y += below
	if avatar != null:
		avatar.couch_rest_amount = amount
	_update_hands()
	if _waking and _seconds <= 0.0:
		finish()
		return
	# Tracked head/hands stay live during sleep, but physical movement must not
	# invoke stand_up(), whose exit placement rebases the entire room-scale rig.
	if not _desktop and amount >= 1.0:
		if bool(player.get("controls_locked")) or player.get_meta("shared_rest_sleeping", false):
			_roomscale_exit_suspended = true
			return
		var inside: bool = couch.rest_contains(seat, camera.global_position)
		if _roomscale_exit_suspended:
			if inside: _roomscale_exit_suspended = false
			return
		# Ordinary awake room-scale walking off the cushion still ends the rest.
		if not inside: player.stand_up()

func wake() -> void:
	_waking = true
	player.remove_meta("couch_sleeping")

## Shift the lying body along the furniture (dev 2026-09-29: "move around with my stick while
## laid down ... shift and adjust my position to actually get proper close to her"). `input` is
## the move stick/WASD: up toward the foot end, right to your right, in the rest frame so a head
## looking at the ceiling still steers. The head stays inside the furniture's shift bounds.
const SHIFT_SPEED := 0.3

func shift(input: Vector2, delta: float) -> bool:
	if _finished or _waking or amount < 0.99 or input.length_squared() < 0.02: return false
	var facing: Basis = couch.rest_frame(seat).global_basis.orthonormalized()
	var move: Vector3 = (facing.x * input.x - facing.z * input.y)
	move.y = 0.0
	if move.length_squared() < 0.0001: return false
	move = move.limit_length(1.0) * SHIFT_SPEED * delta
	var head := camera.global_position + move
	var allowed: bool = couch.shift_contains(seat, head) if couch.has_method("shift_contains") else couch.rest_contains(seat, head)
	if not allowed: return false
	player.global_position += move
	return true

func _update_hands() -> void:
	if not _desktop: return
	var facing:Basis = couch.rest_frame(seat).global_basis.orthonormalized()
	var forward := -facing.z
	var head := camera.global_position
	var centre := head + forward * lerpf(0.18, 0.42, amount) - Vector3.UP * lerpf(0.4, 0.16, amount)
	_left.global_transform = Transform3D(facing, centre - facing.x * 0.22)
	_right.global_transform = Transform3D(facing, centre + facing.x * 0.22)
	var companion: Node3D = couch.partner(seat)
	if is_instance_valid(companion) and companion.has_meta("shared_nap_closeness"):
		# Keep the untracked hands beside the torso. A head-on-shoulder rest must not
		# inherit the old hand-on-companion target and fold an arm through her face.
		return
	if is_instance_valid(companion) and companion.has_method("listen_point"):
		var contact:Vector3 = companion.listen_point() + companion.global_basis.z.normalized() * 0.17 - Vector3.UP * 0.1
		var hand := _left if _left.global_position.distance_to(contact) < _right.global_position.distance_to(contact) else _right
		# Desktop's untracked hand rests on the companion's shoulder. XR endpoints stay tracked.
		var blend := amount * float(avatar.get("_couch_company")) if is_instance_valid(avatar) else 0.0
		hand.global_position = hand.global_position.lerp(contact, blend)

## Called before standing, teleporting, or waking. Does not touch a camera's local transform.
func finish() -> void:
	if _finished: return
	_finished = true
	if is_instance_valid(player):
		player.global_position -= _applied
		player.remove_meta("couch_sleeping")
		player.set("_couch_rest", null)
	if is_instance_valid(avatar):
		if _desktop and is_instance_valid(avatar.get("desktop_pose_driver")):
			avatar.desktop_pose_driver.clear_rest_hand_targets(_left, _right)
		avatar.couch_rest_frame = null
		avatar.couch_rest_amount = 0.0
		if _temporary_avatar:
			# Another recline can begin before the deferred deletion runs. Release
			# the public body name now, so contact finds the new supported avatar.
			# During parent teardown Godot already owns child removal. An active
			# finish still detaches now to release the name for same-frame reuse.
			if not _exiting and avatar.get_parent() != null: avatar.get_parent().remove_child(avatar)
			avatar.queue_free()
	queue_free()

func _exit_tree() -> void:
	_exiting = true
	if not _finished:
		finish()
