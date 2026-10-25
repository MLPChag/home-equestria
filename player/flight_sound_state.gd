extends RefCounted
## Presentation arithmetic, sampled after movement. No camera/view input or physics writes.
var airspeed := 0.0
var acceleration := 0.0
var bank := 0.0
var dive := 0.0
var hover := 0.0
var soft_gain := 0.0
var rush_gain := 0.0
var soft_pitch := .84
var rush_pitch := .90
var discontinuity := false
var _primed := false
var _position := Vector3.ZERO
var _velocity := Vector3.ZERO

func reset() -> void:
	_primed = false
	airspeed = 0.0; acceleration = 0.0; bank = 0.0; dive = 0.0; hover = 0.0
	soft_gain = 0.0; rush_gain = 0.0
	soft_pitch = .84; rush_pitch = .90; discontinuity = false

func step(at: Vector3, velocity: Vector3, active: bool, beating: bool,
		bank_angle: float, clearance: float, delta: float) -> void:
	discontinuity = false
	if not at.is_finite() or not velocity.is_finite() or not is_finite(delta) or delta <= 0.0 or delta > .25:
		reset(); discontinuity = true; return
	var speed := minf(velocity.length(), 100.0)
	if _primed and at.distance_to(_position) > maxf(4.0, (_velocity.length() + speed) * delta * 1.5 + 1.0):
		reset(); discontinuity = true
		_position = at; _velocity = velocity
		return
	var forward_accel := (speed - minf(_velocity.length(), 100.0)) / delta if _primed else 0.0
	var turn := 0.0
	if _primed and speed > 4.0 and _velocity.length() > 4.0:
		turn = clampf(velocity.angle_to(_velocity) / delta / 2.0, 0.0, 1.0)
	_position = at; _velocity = velocity; _primed = true
	var blend := 1.0 - exp(-delta * 5.0)
	airspeed = lerpf(airspeed, speed if active else 0.0, blend)
	acceleration = lerpf(acceleration, clampf(forward_accel / 20.0, -1.0, 1.0) if active else 0.0, blend)
	bank = lerpf(bank, clampf(absf(bank_angle) / .96, 0.0, 1.0) if is_finite(bank_angle) and active else 0.0, blend)
	dive = lerpf(dive, smoothstep(4.0, 24.0, -velocity.y) if active else 0.0, blend)
	hover = lerpf(hover, (1.0 - smoothstep(1.5, 4.0, speed)) if active and beating else 0.0, blend)
	var low_pass := 1.0 - smoothstep(1.0, 7.0, clearance) if is_finite(clearance) else 0.0
	soft_gain = clampf(smoothstep(1.0, 22.0, airspeed) * .65 + smoothstep(22.0, 70.0, airspeed) * .18 + hover * .025, 0.0, 1.0)
	rush_gain = clampf(smoothstep(7.0, 50.0, airspeed) * (.54 + dive * .16 + bank * .10 + maxf(acceleration, 0.0) * .10 + turn * .06 + low_pass * .08), 0.0, 1.0)
	soft_pitch = lerpf(.84, 1.08, smoothstep(0.0, 70.0, airspeed))
	rush_pitch = lerpf(.90, 1.20, smoothstep(5.0, 70.0, airspeed))
