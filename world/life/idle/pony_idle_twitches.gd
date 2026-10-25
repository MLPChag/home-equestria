extends RefCounted
## Small involuntary life on a quiet pony (dev 2026-10-14: "a pony is still just standing around
## in one place completely fucking still"): an ear flick every few seconds and a swish of the tail.
## One per hybrid, advanced on her 20 Hz face beat (hybrid_mare.gd) in HERO and NEAR only: two
## timers, and during a flick one dictionary write per beat. No per-frame work of its own.
##
## Ears use the head's own authored ear shapes (openpony_eye_motion.gd expression_ears) and only
## while nothing else holds them: a spoken line's face, fluster or any other ear shape ends the
## flick at once and leaves their weights alone. The tail is a kick to its spring solver
## (hybrid_tail_physics.gd kick), so the swing stays inside the tail's own joint limits and floor
## contacts; nothing is posed directly.
const EAR_SECONDS := .42
const EAR_SHAPES := ["ears_side", "ears_side", "ears_alert"]
## Angular speed (rad/s) the swish adds to the tail joints, sideways; the solver caps it at 2.8.
const SWISH := Vector2(1.1, 1.9)

var _rng := RandomNumberGenerator.new()
var _ear_wait := 0.0
var _tail_wait := 0.0
var _ear_time := -1.0
var _ear_shape := ""
var _ear_peak := 0.0
var _ear_written := -1.0
var _second_swish := -1.0
var _swish_side := 1.0
## Counters for tests and traces.
var flicks := 0
var swishes := 0


func _init(seed_value: int = 0) -> void:
	_rng.seed = seed_value if seed_value != 0 else randi()
	# Out of step from the first second: no two ponies flick or swish together.
	_ear_wait = _rng.randf_range(1.5, 8.0)
	_tail_wait = _rng.randf_range(2.0, 10.0)


## `quiet`: she is standing or resting still, awake, not held, kissed or carried.
func advance(delta: float, mare: Node3D, quiet: bool) -> void:
	var eyes: Object = mare.get("eye_motion")
	if _ear_time >= 0.0: _advance_ear(delta, eyes)
	if _second_swish >= 0.0:
		_second_swish -= delta
		if _second_swish < 0.0 and quiet: _kick(mare, -_swish_side * .8)
	if not quiet: return
	_ear_wait -= delta
	_tail_wait -= delta
	if _ear_wait <= 0.0:
		_ear_wait = _rng.randf_range(3.5, 12.0)
		flick_ears(eyes)
	if _tail_wait <= 0.0:
		_tail_wait = _rng.randf_range(4.0, 14.0)
		swish_tail(mare)


## A quick ear flick through one authored ear shape; false while anything else holds her ears.
func flick_ears(eyes: Object) -> bool:
	if _ear_time >= 0.0 or eyes == null: return false
	var ears: Variant = eyes.get("expression_ears")
	if not (ears is Dictionary) or not (ears as Dictionary).is_empty(): return false
	_ear_shape = EAR_SHAPES[_rng.randi_range(0, EAR_SHAPES.size() - 1)]
	_ear_peak = _rng.randf_range(.45, .85)
	_ear_time = 0.0
	_ear_written = -1.0
	flicks += 1
	return true


func _advance_ear(delta: float, eyes: Object) -> void:
	var ears: Variant = eyes.get("expression_ears") if eyes != null else null
	if not (ears is Dictionary):
		_ear_time = -1.0
		return
	var shapes: Dictionary = ears
	# Another owner wrote her ears since the last beat (a line's face, fluster): theirs now.
	var ours := shapes.has(_ear_shape) and float(shapes[_ear_shape]) == _ear_written
	var foreign := shapes.size() > (1 if shapes.has(_ear_shape) else 0)
	if foreign or (_ear_written >= 0.0 and not ours):
		_ear_time = -1.0
		return
	_ear_time += delta
	var t := _ear_time / EAR_SECONDS
	if t >= 1.0:
		shapes.erase(_ear_shape)
		_ear_time = -1.0
		return
	# Out fast, back a little slower: a flick, not a pose.
	var weight := _ear_peak * smoothstep(0.0, .25, t) * (1.0 - smoothstep(.45, 1.0, t))
	shapes[_ear_shape] = weight
	_ear_written = weight


## One swish to a random side, now and then a second one back.
func swish_tail(mare: Node3D) -> bool:
	_swish_side = -1.0 if _rng.randf() < .5 else 1.0
	if not _kick(mare, _swish_side): return false
	swishes += 1
	_second_swish = _rng.randf_range(.35, .55) if _rng.randf() < .35 else -1.0
	return true


func _kick(mare: Node3D, side: float) -> bool:
	var tail: Object = mare.get("tail_motion")
	if tail == null or not bool(tail.get("active")): return false
	var springs: Object = tail.get("springs")
	if springs == null or not springs.has_method("kick"): return false
	springs.kick(mare.global_basis.x.normalized() * side * _rng.randf_range(SWISH.x, SWISH.y))
	return true


## Cut short (asleep, picked up): her ears go back to whatever owns them.
func cancel(mare: Node3D) -> void:
	_second_swish = -1.0
	if _ear_time < 0.0: return
	var eyes: Object = mare.get("eye_motion")
	var ears: Variant = eyes.get("expression_ears") if eyes != null else null
	if ears is Dictionary and (ears as Dictionary).has(_ear_shape) and float(ears[_ear_shape]) == _ear_written:
		(ears as Dictionary).erase(_ear_shape)
	_ear_time = -1.0
