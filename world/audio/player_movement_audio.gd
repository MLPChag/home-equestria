extends Node
## Observes the real motor after its physics tick. No movement, skeletal updates or support rays.
var body: CharacterBody3D
var ambience: Node3D
var pony := false
var _previous := Vector3.INF
var _grounded := false
var _primed := false
var _vertical := 0.0
var _air_seconds := 0.0


func setup(owner_body: CharacterBody3D, owner_ambience: Node3D, is_pony := false) -> void:
	body = owner_body
	ambience = owner_ambience
	pony = is_pony
	_primed = false
	_previous = Vector3.INF
	process_physics_priority = 20


func _physics_process(delta: float) -> void:
	if not is_instance_valid(body) or not is_instance_valid(ambience): return
	var at := body.global_position
	if not at.is_finite() or not body.velocity.is_finite():
		_primed = false
		return
	var floor_now: bool = bool(body.call("grounded")) if pony and body.has_method("grounded") else body.is_on_floor()
	var flying: bool = bool(body.get("flying")) if "flying" in body else false
	var swimming: Variant = body.get("swimming") if "swimming" in body else null
	var wet: bool = swimming != null and bool(swimming.get("active"))
	var held: bool = bool(body.get("_held")) if "_held" in body else false
	observe(at, body.velocity, floor_now, flying or wet or held, delta)


## Accept only measured motor state; useful for isolated transition fixtures too.
func observe(at: Vector3, velocity: Vector3, floor_now: bool, blocked: bool, delta: float) -> void:
	if not at.is_finite() or not velocity.is_finite() or not is_finite(delta) or delta <= 0.0:
		_primed = false
		return
	if not _primed or not _previous.is_finite() or at.distance_to(_previous) > maxf(.75, delta * 25.0) or blocked:
		_primed = true
		_air_seconds = 0.0
	else:
		if not floor_now: _air_seconds += delta
		if _grounded and not floor_now and velocity.y > 1.5:
			ambience.call("play_jump", body, at)
		elif not _grounded and floor_now and _air_seconds > .08 and _vertical < -1.2:
			ambience.call("play_landing", body, at, -_vertical, pony)
		if floor_now: _air_seconds = 0.0
	_grounded = floor_now
	_vertical = velocity.y
	_previous = at
