extends RefCounted
## Petting, per hand: the head-scratch rule (head_scratch_gesture.gd) generalised to her whole
## coat. The hand must touch her and travel gently along the coat: one long stroke in a
## direction, or a back-and-forth rub, both count. Hovering, a still hand, a slap and her walking
## under a still hand do not: the travel is the smaller of the hand's motion across the touched
## part and the tracked controller's own motion (the physics hand is dragged by her coat).
const MIN_CONTACT := 0.25   # s of touch before a stroke counts
const STROKE := 0.05        # m travelled in one direction
const RUB := 0.025          # m travelled before a reversal counts
const MAX_SPEED := 1.0      # m/s: faster is a swipe or a slap, not petting
const HOLD := 0.8           # s the reaction lasts after the hand stops moving
const GRACE := 0.15         # s of lost contact tolerated while the hand skims the coat
var contact_time := 0.0
var lost := 0.0
var run := 0.0
var travel := 0.0
var direction := Vector3.ZERO
var active_time := 0.0
var strokes := 0
var _run_counted := false
var _local := Vector3.INF
var _reference := Vector3.INF
var _frame_id := -1


func reset() -> void:
	_forget_contact()
	active_time = 0.0


func _forget_contact() -> void:
	contact_time = 0.0; lost = 0.0; run = 0.0; travel = 0.0; direction = Vector3.ZERO
	_run_counted = false; _local = Vector3.INF; _reference = Vector3.INF; _frame_id = -1


## `local` is the hand in the touched part's frame (`frame_id` names that part), `normal` the
## coat's outward direction there, `reference` the controller in tracking space. True while petting.
func advance(delta: float, contact: bool, local: Vector3, frame_id: int, normal: Vector3, reference: Vector3) -> bool:
	active_time = maxf(0.0, active_time - delta)
	if delta <= 0.0 or delta > 0.1 or not reference.is_finite():
		_forget_contact()
		return active_time > 0.0
	if not contact or not local.is_finite():
		lost += delta
		if lost > GRACE: _forget_contact()
		return active_time > 0.0
	lost = 0.0
	contact_time += delta
	if frame_id != _frame_id or not _local.is_finite():
		# A new part under the hand: its frame is not comparable with the last one.
		_frame_id = frame_id; _local = local; _reference = reference
		return active_time > 0.0
	var moved := local - _local
	moved -= normal * moved.dot(normal)
	var distance := minf(moved.length(), reference.distance_to(_reference))
	_local = local; _reference = reference
	if distance / delta >= MAX_SPEED:
		run = 0.0; direction = Vector3.ZERO; _run_counted = false
		return active_time > 0.0
	if distance <= 0.0004:
		return active_time > 0.0
	var along := moved.normalized()
	if direction != Vector3.ZERO and along.dot(direction) < -0.4:
		if run >= RUB and contact_time >= MIN_CONTACT and not _run_counted: _qualify()
		run = 0.0; _run_counted = false
		direction = along
	elif direction == Vector3.ZERO:
		direction = along
	else:
		direction = (direction * 0.7 + along * 0.3).normalized()
	run += distance
	travel += distance
	if run >= STROKE and contact_time >= MIN_CONTACT and not _run_counted: _qualify()
	if active_time > 0.0: active_time = HOLD
	return active_time > 0.0


func _qualify() -> void:
	_run_counted = true
	active_time = HOLD
	strokes += 1
