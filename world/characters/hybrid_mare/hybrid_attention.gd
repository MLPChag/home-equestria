extends RefCounted
## Where the hybrid mare puts her head and eyes when nothing else claims them.
##
## Two layers on top of PonySecondaryMotion's rare random glances:
## - Player attention: when the player is close and roughly in front, she turns her head and
##   eyes to them in sessions (look, hold, look away, look back), closer = more of the time.
## - Idle head life: when resting with nobody to watch, small looks, tilts and nods every few
##   seconds so the head is never parked; occasionally a look at the ground.
## Only `secondary.look_toward` is driven (the native neck joint limits still apply through
## apply_pose), so the OpenPony head follows through HybridNeckLink like any other gaze.

## Farther than this the player is scenery; nearer than `close_distance` she nearly never
## looks away.
var notice_distance := 5.0
var close_distance := 1.8
var field_of_view := deg_to_rad(80.0)
## Head-frame pitch/yaw limits (radians); native joint limits clamp again inside the pose.
var pitch_limits := Vector2(deg_to_rad(-25.0), deg_to_rad(40.0))
var yaw_limit := deg_to_rad(50.0)

## Outputs for the caller (eyes and expressions).
var engaged := false
var interest := 0.0            # 0..1, eased; how much she is "with" the player right now
## Nearer than this to her listen point a target is ignored. A booping finger at her muzzle sets
## it lower (hybrid_mare.gd) so her eyes stay on it.
var min_distance := 0.05
var eye_target := Vector3.ZERO # world point for OpenPonyEyeMotion.target_world
var last_angles := Vector3.ZERO
var idle_looks := 0            # counter for tests

var rng := RandomNumberGenerator.new()
var _session := 0.0   # >0: seconds left in a look; <0: seconds left in a look-away
var _idle_wait := 2.0
var _idle_angles := Vector3.ZERO
var _idle_time := 0.0
var _idle_duration := 0.0
## Last player-look turn (radians), kept through the close dead zone and behind her.
var _yaw := 0.0
## Horizontal distance from her listen point under which the turn toward him holds still.
const FLAT_DEAD_ZONE := 0.25


func _init() -> void:
	# From the global generator: random in game, repeatable in a test that calls seed().
	rng.seed = randi()
	_idle_wait = rng.randf_range(1.5, 4.0)


## `mare` is the locomotion body (for its frame and profile), `target` the player's head
## (camera) or null, `resting` whether she is standing still and quiet.
func advance(delta: float, mare: Node3D, target: Node3D, resting: bool, conversation := false) -> void:
	var visible := false
	var angles := Vector3.ZERO
	var closeness := 0.0
	if target != null and is_instance_valid(target):
		var hip: float = float(mare.get("profile").hip_height) if mare.get("profile") != null else 0.6
		var head_height: Vector3 = mare.global_position + Vector3.UP * hip * 1.4
		if mare.has_method("listen_point"): head_height = mare.listen_point()
		var to_target: Vector3 = target.global_position - head_height
		var distance := to_target.length()
		if (conversation or distance < notice_distance) and distance > min_distance:
			var local: Vector3 = mare.global_basis.inverse() * to_target
			var yaw := atan2(-local.x, -local.z)
			var seen := absf(yaw) < field_of_view
			# Right over or beside her head the direction flips with every small move, and behind
			# her the clamp jumped from one limit to the other: her head spun in circles as he
			# came close (dev 2026-10-14). Up close keep the last turn; behind her keep its side.
			var flat := Vector2(local.x, local.z).length()
			if flat < FLAT_DEAD_ZONE:
				yaw = _yaw
			elif absf(yaw) > yaw_limit and absf(_yaw) > yaw_limit * .5 and signf(yaw) != signf(_yaw):
				yaw = signf(_yaw) * yaw_limit
			_yaw = clampf(yaw, -yaw_limit, yaw_limit)
			if conversation or seen:
				var pitch := atan2(local.y, Vector2(local.x, local.z).length())
				angles = Vector3(clampf(pitch, pitch_limits.x, pitch_limits.y),
					clampf(yaw, -yaw_limit, yaw_limit), 0.0)
				visible = true
				closeness = 1.0 - smoothstep(close_distance, notice_distance, distance)
				eye_target = target.global_position
	# Sessions: a look lasts longer and the breaks get shorter the closer the player is.
	if visible and conversation:
		# Speaking is an explicit fixation; random sessions must never interrupt it.
		# Anatomical limits still clamp the neck while the body turns toward the listener.
		_session = 0.5
	elif visible:
		if _session == 0.0:
			_session = rng.randf_range(3.0, 7.0) + closeness * 6.0
		elif _session > 0.0:
			_session = maxf(_session - delta, 0.0)
			if _session == 0.0:
				# Look away for a moment; when the player is right there, only briefly.
				_session = -(rng.randf_range(1.5, 4.0) * lerpf(1.0, 0.25, closeness))
				_start_idle_look(true)
		else:
			_session = minf(_session + delta, 0.0)
	else:
		_session = 0.0
	engaged = visible and _session > 0.0
	interest = move_toward(interest, 1.0 if engaged else 0.0, delta / 0.6)
	if engaged:
		last_angles = angles
		# Refresh every tick: look_toward is a timed override, this keeps it live and lets the
		# navigator's own rare glances coexist (they only run when this is not refreshing).
		mare.secondary.look_toward(angles, 0.4)
		return
	if not resting:
		return
	# Idle head life.
	if _idle_time > 0.0:
		_idle_time -= delta
		mare.secondary.look_toward(_idle_angles, 0.4)
		return
	_idle_wait -= delta
	if _idle_wait <= 0.0:
		_start_idle_look(false)


func _start_idle_look(brief: bool) -> void:
	var roll := rng.randf_range(-1.0, 1.0)
	var pick := rng.randf()
	if pick < 0.15:
		# A look at the ground in front of her.
		_idle_angles = Vector3(deg_to_rad(rng.randf_range(-35.0, -22.0)), deg_to_rad(rng.randf_range(-12.0, 12.0)), 0.0)
	elif pick < 0.45:
		# A curious tilt: mostly roll, a little pitch.
		_idle_angles = Vector3(deg_to_rad(rng.randf_range(-6.0, 8.0)), deg_to_rad(rng.randf_range(-10.0, 10.0)), deg_to_rad(9.0) * signf(roll))
	elif pick < 0.7:
		# Small nod / lift.
		_idle_angles = Vector3(deg_to_rad(rng.randf_range(-14.0, 10.0)), deg_to_rad(rng.randf_range(-6.0, 6.0)), 0.0)
	else:
		# A look to one side.
		_idle_angles = Vector3(deg_to_rad(rng.randf_range(-8.0, 6.0)), deg_to_rad(rng.randf_range(14.0, 32.0)) * signf(roll), deg_to_rad(roll * 3.0))
	_idle_duration = rng.randf_range(1.2, 2.8) if not brief else rng.randf_range(0.8, 1.6)
	_idle_time = _idle_duration
	_idle_wait = rng.randf_range(2.5, 6.5)
	idle_looks += 1
