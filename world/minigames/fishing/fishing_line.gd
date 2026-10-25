extends RefCounted
## Shared physical line simulation for player and companion rods. No timers award a catch:
## the float must land in water, a bite must be hooked, and the line reeled back to the rod.
signal caught(at: Vector3)
signal changed(state: String)
const MAX_LINE: float = 13.0
const BITE_WINDOW: float = 2.6
var state: String = "ready"
var bobber: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
var water_y: float = 0.0
var remaining: float = 0.0
var tension: float = 0.0
var clock: float = 0.0
var wait_time: float = 0.0
var _rod_last: Vector3
var _ready: bool = false
var _lifting: bool = false
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

func reset(tip: Vector3) -> void:
	bobber = tip; velocity = Vector3.ZERO; tension = 0; remaining = 0
	_rod_last = tip; _ready = true; _lifting = false; _set_state("ready")

func cast(tip: Vector3, direction: Vector3, strength: float = 1.0) -> bool:
	if state != "ready" or not tip.is_finite() or not direction.is_finite() or direction.length_squared() < .01: return false
	reset(tip)
	var horizontal: Vector3 = Vector3(direction.x,0,direction.z).normalized()
	if horizontal.length_squared() < .1: return false
	velocity = horizontal * clampf(6.0*strength,4.0,8.0) + Vector3.UP*3.7
	clock = 0; _set_state("casting"); return true

## sweep(from,to) returns {position,water} for the first water/solid hit, or {}.
func tick(delta: float, tip: Vector3, sweep: Callable) -> void:
	if not tip.is_finite() or delta <= 0: return
	if not _ready: reset(tip)
	clock += delta
	if state == "ready": bobber = tip
	elif state == "casting":
		velocity.y -= 9.8*delta
		var next: Vector3 = bobber + velocity*delta
		var hit: Dictionary = sweep.call(bobber,next)
		if not hit.is_empty():
			bobber = hit.position
			if hit.get("water",false):
				water_y = bobber.y; remaining = tip.distance_to(bobber)
				wait_time = rng.randf_range(5.0,14.0); clock = 0; _set_state("waiting")
			else: reset(tip)
		else: bobber = next
		if tip.distance_to(bobber) > MAX_LINE or clock > 5: reset(tip)
	elif state == "waiting":
		if not _lifting:
			bobber.y = water_y + .025 + sin(clock*2.8)*.013
			if clock >= wait_time: clock = 0; _set_state("bite")
	elif state == "bite":
		bobber.y = water_y - .06 + sin(clock*16)*.026
		# A real upward wrist/rod movement hooks the bite in VR.
		if tip.y-_rod_last.y > maxf(.045,delta*.65): hook()
		elif clock > BITE_WINDOW:
			clock = 0; wait_time = rng.randf_range(6,15); _set_state("waiting")
	elif state == "hooked":
		if not _lifting: bobber.y = water_y + .025 + sin(clock*14)*.018
		var distance: float = tip.distance_to(bobber)
		# Walking away cannot reel: an overstretched line loses its fish.
		tension = maxf(0.0,distance-remaining)
		if tension > 2.5: reset(tip)
	_rod_last = tip

func hook() -> bool:
	if state != "bite": return false
	clock = 0; tension = 0; _set_state("hooked"); return true

## Metres collected by turning the physical reel (mouse wheel or the other VR hand).
func reel(metres: float, tip: Vector3) -> bool:
	if state not in ["waiting","bite","hooked"] or metres <= 0 or not is_finite(metres): return false
	var has_fish: bool = state == "hooked"
	metres = minf(metres,.35)
	remaining = maxf(0,remaining-metres)
	var toward: Vector3 = tip-bobber
	var distance: float = toward.length()
	if not _lifting and Vector2(toward.x,toward.z).length() > 1.5:
		toward.y = 0
	else:
		_lifting = true
		if state == "bite": _set_state("waiting")
	if distance > .001:
		bobber += toward.normalized()*minf(metres,toward.length())
	# A spent line-length counter is not a landed fish. It must physically reach
	# the tip; once lifted, later ticks must not snap it back down to the water.
	if tip.distance_to(bobber) <= .65:
		var landed: Vector3 = bobber
		reset(tip)
		if has_fish: caught.emit(landed)
	return true

func _set_state(next: String) -> void:
	if next == state: return
	state = next; changed.emit(state)
