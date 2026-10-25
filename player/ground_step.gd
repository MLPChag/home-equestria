extends RefCounted
## Small grounded human steps, tested with the complete unchanged body shape.
## No collision exceptions, capsule resizing or pose assignments. Each accepted probe
## is executed as a swept movement; tall obstacles and blocked headroom remain solid.
const HEIGHT := .20
const MAX_FORWARD_CONTACTS := 8
var _hit := KinematicCollision3D.new()
var _landing := KinematicCollision3D.new()
var _blocked_distance := 0.0
var _direction := Vector3.ZERO
var _last_call := 0
func reset() -> void:
	_blocked_distance = 0.0; _direction = Vector3.ZERO
func move(body: CharacterBody3D, delta: float, maximum_height := HEIGHT, support_check := Callable()) -> bool:
	var now := Time.get_ticks_msec()
	if now - _last_call > maxi(100, int(delta * 3000.0)): reset()
	_last_call = now
	if not body.is_on_floor() or body.velocity.y > .01:
		reset(); return false
	var forward := Vector3(body.velocity.x, 0, body.velocity.z) * delta
	if forward.length_squared() < .000001:
		reset(); return false
	var direction := forward.normalized()
	if _direction.dot(direction) < .95: reset()
	_direction = direction
	var start := body.global_transform
	if not body.test_move(start, forward, _hit, .001, false, MAX_FORWARD_CONTACTS):
		reset(); return false
	# A rounded capsule can touch a tread and the following riser in the same
	# sweep. The first (walkable) normal alone must not hide the blocking riser.
	var has_riser := false
	var floor_limit := cos(body.floor_max_angle)
	for contact in _hit.get_collision_count():
		if _hit.get_normal(contact).dot(Vector3.UP) < floor_limit:
			has_riser = true; break
	if not has_riser:
		reset(); return false
	# Save only motion the current obstacle would block. At high render cadence a
	# capsule needs several intended increments to reach a floor-safe lip normal.
	# Never borrow future travel; cap the pending amount and clear it on free movement.
	var blocked := maxf(0.0, forward.length() - maxf(0.0, _hit.get_travel().dot(direction)))
	var accumulated := direction * (forward.length() + _blocked_distance)
	var up := Vector3.UP * maximum_height
	if body.test_move(start, up):
		reset(); return false
	var raised := start; raised.origin += up
	if body.test_move(raised, accumulated):
		reset(); return false
	var ahead := raised; ahead.origin += accumulated
	var down := Vector3.DOWN * (maximum_height + .02)
	if not body.test_move(ahead, down, _landing):
		reset(); return false
	if _landing.get_normal().dot(Vector3.UP) < cos(body.floor_max_angle):
		_blocked_distance = minf(.10, _blocked_distance + blocked)
		return false
	var rise := maximum_height + _landing.get_travel().y
	if rise < .01 or rise > maximum_height:
		reset(); return false
	var supported := start; supported.origin += accumulated + Vector3.UP * rise
	if support_check.is_valid() and not bool(support_check.call(supported)):
		reset(); return false
	reset()
	# These are real swept motions, not a relocation to a sampled point. If anything
	# blocks a probe's execution, keep the safe partial motion instead of teleporting.
	if body.move_and_collide(up) != null: return false
	body.move_and_collide(accumulated)
	body.move_and_collide(down)
	var velocity := body.velocity
	body.velocity = Vector3.DOWN * .1
	body.move_and_slide() # Refresh floor state without consuming forward motion twice.
	body.velocity = Vector3(velocity.x, 0, velocity.z)
	return true
