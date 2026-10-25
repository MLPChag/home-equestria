extends RefCounted
## A small, bounded filter on the hand motor's target, never the tracked node
## or the collision body. Quiet poses settle; deliberate motion opens the
## bandwidth immediately. Physics, visible arms and grabs still share one hand.

const STILL_CUTOFF := 6.0
const MOVING_CUTOFF := 60.0
const POSITION_LAG_METRES := 0.003
const ANGULAR_LAG := deg_to_rad(0.75)
const RESET_DISTANCE_METRES := 0.35
const RESET_ANGLE := deg_to_rad(120.0)
const RESET_GAP := 0.25

var pose := Transform3D.IDENTITY
var was_reset := false
var _initialized := false
var _previous_raw := Transform3D.IDENTITY
var _world_scale := 1.0


func invalidate() -> void:
	# Keep the last safe target during tracking loss; reacquisition starts fresh.
	_initialized = false


func reset(raw: Transform3D, world_scale: float = 1.0) -> Transform3D:
	pose = raw
	_previous_raw = raw
	_world_scale = maxf(world_scale, 0.001)
	_initialized = true
	was_reset = true
	return pose


func sample(raw: Transform3D, delta: float, world_scale: float = 1.0,
		tracked: bool = true) -> Transform3D:
	was_reset = false
	if not tracked or not raw.is_finite() or absf(raw.basis.determinant()) < 0.000001:
		invalidate()
		return pose
	var scale := maxf(world_scale, 0.001)
	var raw_rotation := raw.basis.get_rotation_quaternion().normalized()
	if not _initialized or delta >= RESET_GAP or not is_equal_approx(scale, _world_scale):
		return reset(raw, scale)
	var previous_rotation := _previous_raw.basis.get_rotation_quaternion().normalized()
	if raw.origin.distance_to(_previous_raw.origin) > RESET_DISTANCE_METRES * scale \
			or previous_rotation.angle_to(raw_rotation) > RESET_ANGLE:
		return reset(raw, scale)
	if delta <= 0.0:
		return pose
	_previous_raw = raw
	var distance := pose.origin.distance_to(raw.origin) / scale
	var position_cutoff := lerpf(STILL_CUTOFF, MOVING_CUTOFF, smoothstep(0.001, 0.012, distance))
	var position_alpha := 1.0 - exp(-TAU * position_cutoff * delta)
	var filtered_position := pose.origin.lerp(raw.origin, position_alpha)
	# This is an added smoothing-error bound, not a limit on physical collision lag.
	filtered_position = raw.origin + (filtered_position - raw.origin).limit_length(POSITION_LAG_METRES * scale)
	var rotation := pose.basis.get_rotation_quaternion().normalized()
	var angle := rotation.angle_to(raw_rotation)
	var rotation_cutoff := lerpf(STILL_CUTOFF, MOVING_CUTOFF, smoothstep(deg_to_rad(0.5), deg_to_rad(8.0), angle))
	var rotation_alpha := 1.0 - exp(-TAU * rotation_cutoff * delta)
	if angle > ANGULAR_LAG:
		rotation_alpha = maxf(rotation_alpha, 1.0 - ANGULAR_LAG / angle)
	var filtered_rotation := rotation.slerp(raw_rotation, rotation_alpha).normalized()
	pose = Transform3D(Basis(filtered_rotation).scaled(raw.basis.get_scale()), filtered_position)
	return pose
