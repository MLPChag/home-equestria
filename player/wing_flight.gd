extends RefCounted
signal activity_changed(active: bool)
signal wingbeat_started(strength: float, seconds: float)
signal takeoff_started
## Player flight arithmetic only. The existing character controller owns movement.
## Original metre/second adaptation of the researched momentum/wingbeat principles;
## no source-game code, scene scans, collision queries or per-tick collections.
const CAPACITY := 8.0
const MAX_SPEED := 70.0
const STEP := 1.0 / 120.0
const GRAVITY := 9.8
const BANK_LIMIT := PI * 55.0 / 180.0
var bank_input := 0.0
var bank_angle := 0.0
var charge := CAPACITY
var active := false
var landing := false
var beating := false
var phase := 0.0
var period := 0.5
var _beat_strength := 1.0
var _rest := 0.0
var resume_pending := false
var _velocity := Vector3.ZERO

func begin(velocity: Vector3, forward: Vector3) -> Vector3:
	if active or charge < 1.0: return velocity
	active = true; landing = false; bank_input = 0.0; bank_angle = 0.0
	activity_changed.emit(true)
	takeoff_started.emit()
	_start_beat(false)
	var flat := Vector3(forward.x, 0.0, forward.z).normalized()
	if not flat.is_finite(): flat = Vector3.FORWARD
	var result := velocity if velocity.is_finite() else Vector3.ZERO
	result += flat * 2.0
	result.y = maxf(result.y, 3.5)
	result = result.limit_length(MAX_SPEED)
	_velocity = result
	return result

func resume() -> Vector3:
	resume_pending = false; active = true; beating = false; phase = 0.0; bank_input = 0.0; bank_angle = 0.0
	activity_changed.emit(true)
	return _velocity

func finish() -> void:
	var was_active := active
	active = false; landing = false; beating = false; phase = 0.0; bank_input = 0.0; bank_angle = 0.0
	resume_pending = false
	if was_active: activity_changed.emit(false)

func _start_beat(boost: bool) -> void:
	var cost := 1.5 if boost else 1.0
	if charge < cost: return
	charge -= cost; _rest = 0.0; beating = true; phase = 0.0
	period = lerpf(0.62, 0.36, charge / CAPACITY)
	_beat_strength = 1.35 if boost else 1.0
	wingbeat_started.emit(_beat_strength, period)

func recover(delta: float) -> void:
	if charge >= CAPACITY or not is_finite(delta) or delta <= 0.0: return
	var elapsed := minf(delta, 0.1)
	# Continuous equivalent of accelerating rest recovery. Never recover mid-beat.
	charge = minf(CAPACITY, charge + (2.5 + 0.625 * _rest) * elapsed + 0.3125 * elapsed * elapsed)
	_rest += elapsed

func step(velocity: Vector3, view: Basis, input: Vector2, flap: bool, boost: bool,
		retract: bool, delta: float) -> Vector3:
	if not velocity.is_finite(): velocity = Vector3.ZERO
	if not is_finite(delta) or delta <= 0.0: return velocity
	if not view.is_finite() or absf(view.determinant()) < 0.001: view = Basis.IDENTITY
	if not input.is_finite(): input = Vector2.ZERO
	view = view.orthonormalized(); input = input.limit_length(1.0)
	var forward := (-view.z + view.x * input.x * 0.7).normalized()
	var brake := maxf(input.y, 0.0)
	var remaining := minf(delta, 0.1)
	while remaining > 0.000001:
		var dt := minf(remaining, STEP); remaining -= dt
		var wanted_bank := clampf(bank_input,-1.0,1.0) * BANK_LIMIT if is_finite(bank_input) and not landing else 0.0
		bank_angle = lerpf(bank_angle,wanted_bank,1.0-exp(-dt*5.0))
		if landing or retract: beating = false
		if flap and not landing and not retract and not beating: _start_beat(boost)
		var speed := velocity.length()
		if speed > 0.01 and not landing:
			# Redirect, never replace momentum with an input-dependent target speed.
			var direction := velocity / speed
			var angle := direction.angle_to(forward)
			if angle > 0.0001:
				var axis := direction.cross(forward)
				if axis.length_squared() < 0.000001: axis = direction.cross(Vector3.UP)
				if axis.length_squared() < 0.000001: axis = Vector3.RIGHT
				velocity = velocity.rotated(axis.normalized(), minf(angle, dt * (0.8 if retract else 1.5) * (1.0-absf(bank_angle)/BANK_LIMIT)))
		var acceleration := Vector3.DOWN * GRAVITY
		if not retract and speed > 0.01:
			# Lift is perpendicular to velocity: it cannot create kinetic energy.
			var along := velocity.normalized()
			# Banking rotates lift around travel; the same momentum integrator owns the turn.
			# Ease aim assistance while banked so it does not cancel the lift-driven turn.
			var lift := (Vector3.UP - along * along.y).rotated(along,bank_angle)
			acceleration += lift * minf(GRAVITY, speed * speed * 0.035)
		if beating:
			var middle := minf(1.0, phase + dt / (2.0 * period))
			var pulse := sin(PI * middle / 0.6) if middle < 0.6 else 0.0
			var thrust := (Vector3.UP + forward * (0.35 + maxf(-input.y, 0.0))).normalized()
			acceleration += thrust * pulse * 36.0 * _beat_strength
			phase += dt / period
			if phase >= 1.0: phase = 1.0; beating = false
		else: recover(dt)
		# Broadside flow and backward input cost speed; folded wings dive faster.
		var normal_speed := velocity.dot(view.y)
		var drag := speed * speed * (0.001 if retract else 0.003)
		drag += normal_speed * normal_speed * (0.01 if retract else 0.035)
		drag += brake * speed * speed * 0.10
		if landing: drag += speed * speed * 0.8
		velocity = velocity.move_toward(Vector3.ZERO, drag * dt)
		velocity = (velocity + acceleration * dt).limit_length(MAX_SPEED)
	_velocity = velocity
	return velocity

func snapshot() -> Dictionary:
	return {"charge": charge, "airborne": active or resume_pending, "landing": landing,
		"velocity": [_velocity.x, _velocity.y, _velocity.z]}

static func valid(value: Variant) -> bool:
	if not value is Dictionary: return false
	var amount: Variant = value.get("charge")
	if not ((amount is float or amount is int) and is_finite(float(amount)) and float(amount) >= 0.0 and float(amount) <= CAPACITY): return false
	for key: String in ["airborne", "landing"]:
		if value.has(key) and not value[key] is bool: return false
	if value.get("airborne", false):
		var v: Variant = value.get("velocity")
		if not v is Array or v.size() != 3: return false
		for component: Variant in v:
			if not (component is float or component is int) or not is_finite(float(component)) or absf(float(component)) > MAX_SPEED: return false
	return true

func restore(value: Dictionary) -> void:
	finish(); _rest = 0.0
	charge = float(value.charge) if valid(value) else CAPACITY
	if valid(value) and value.get("airborne", false):
		resume_pending = true; landing = bool(value.get("landing", false))
		_velocity = Vector3(value.velocity[0], value.velocity[1], value.velocity[2]).limit_length(MAX_SPEED)

## Captured desktop flight owns left/right mouse; menus and grounded actions keep them.
static func mouse_banking(body: Node) -> bool:
	return is_instance_valid(body) and body.has_method("uses_mouse_flight_controls") and body.uses_mouse_flight_controls() \
		and "wing_flight" in body and body.wing_flight.active \
		and not bool(body.get("controls_locked")) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

static func bank_buttons(body: Node) -> float:
	if not mouse_banking(body): return 0.0
	return float(Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT))-float(Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT))

static func reserves_mouse(event: InputEvent, body: Node) -> bool:
	return event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT,MOUSE_BUTTON_RIGHT] and mouse_banking(body)
