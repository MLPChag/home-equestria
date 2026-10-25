extends "res://world/life/day/day_action.gd"
## One owned garden spot: walk, inspect, water with the existing authored can.
## The day runner owns the 0.5 s cadence; the shared prop holder follows the muzzle.
const CARRY := preload("res://world/life/day/pony_snack.gd")
const MAGIC := preload("res://world/characters/magic/unicorn_magic.gd")
const CAN := "res://world/props/ponyville_kit/activity/watering_can.scn"
const TRAVEL_LIMIT := 180.0
const ALIGN_LIMIT := 6.0
const INSPECT_SECONDS := 2.0
const POUR_SECONDS := 6.0
const ARRIVAL_RADIUS := .4
const ARRIVAL_HEIGHT := .35
var _state: Node
var _token := 0
var _step_key := ""
var _source_well := ""
var _spot: Dictionary = {}
var _point := Vector3.INF
var _phase := "travel"
var _phase_seconds := 0.0
var _owner := ""
var _old_wander := false
var _claimed := false
var _prop: Node3D
var _glows: Array = []
var _grip := Vector3.ZERO
var _tool_basis := Basis.IDENTITY
var _floating := false
var _tries := 0
var _gait := 0
var _travel_limit := TRAVEL_LIMIT

func start(ctx: Dictionary) -> bool:
	var spot: Dictionary = _resolve(ctx, "garden")
	return _begin(ctx, spot)

func _resolve(ctx: Dictionary, kind: String) -> Dictionary:
	return SPOTS.resolve(ctx.population, str(ctx.id), kind)

func _begin(ctx: Dictionary, spot: Dictionary) -> bool:
	if spot.is_empty() or not is_instance_valid(ctx.actor) or not is_instance_valid(ctx.nav): return false
	var approach: Vector3 = spot.get("approach", Vector3.INF)
	if not approach.is_finite(): return false
	var nav: Node = ctx.nav
	if not str(nav.reserved_by).is_empty() or _interrupted(ctx): return false
	# The measured point can sit just inside kit or house collision: use the nearest walkable
	# cell within this handler's tolerance (real town run 2026-10-13), never farther.
	if nav.has_method("command_support"):
		var walkable: Vector3 = nav.command_support(approach)
		if walkable.is_finite() and Vector2(walkable.x - approach.x, walkable.z - approach.z).length() <= _snap_radius():
			spot = spot.duplicate()
			spot.approach = walkable
	var previous := str(nav.command_owner)
	if not previous.is_empty() and not previous.begins_with("life:") and not previous.begins_with("social:"): return false
	_state = ctx.get("kit_state")
	_step_key = str(ctx.get("step_key", ""))
	if not is_instance_valid(_state) or not _lock_spot(ctx, spot): return false
	_owner = "day:" + str(ctx.id)
	_old_wander = bool(nav.wander_enabled)
	# Admission happens before cancelling any previous motion.
	nav.command_owner = _owner
	if str(nav.command_owner) != _owner:
		_unlock_spot()
		return false
	_claimed = true
	if not _owns(ctx):
		release(ctx)
		return false
	nav.stay()
	nav.wander_enabled = false
	_navigate(ctx)
	return true

## How far the walkable point may move from the measured approach and still do the work.
func _snap_radius() -> float:
	return .5

func _lock_spot(ctx: Dictionary, spot: Dictionary) -> bool:
	var token: int = _state.acquire(str(spot.get("id", "")), ctx.actor, self, int(ctx.day), _step_key)
	if token == 0: return false
	_spot = spot
	_token = token
	return true

func _unlock_spot() -> void:
	if is_instance_valid(_state) and _token != 0: _state.release(_token)
	_token = 0

func _navigate(ctx: Dictionary) -> void:
	_point = _spot.approach
	_phase_seconds = 0.0
	_tries = 0
	ctx.nav.face_point = Vector3.INF
	# Far errands start from wherever her day left her: trot there empty-mouthed, walk while
	# carrying, and allow the time a walk of that length takes (real town run 2026-10-13).
	var far: float = Vector2(ctx.actor.global_position.x - _point.x, ctx.actor.global_position.z - _point.z).length()
	_gait = ctx.nav.Gait.TROT if far > 40.0 and not is_instance_valid(_prop) else ctx.nav.Gait.WALK
	# Walking with a load runs about 0.3-0.45 m/s on winding town routes.
	_travel_limit = maxf(TRAVEL_LIMIT, far / .3 + 60.0)
	# A carried bucket is a ground errand; no automatic flight shortcut.
	ctx.nav.go_to(_point, _gait, false)

func _at_spot(ctx: Dictionary) -> bool:
	var here: Vector3 = ctx.actor.global_position
	return Vector2(here.x - _point.x, here.z - _point.z).length() <= ARRIVAL_RADIUS and absf(here.y - _point.y) <= ARRIVAL_HEIGHT

func _travel(ctx: Dictionary) -> String:
	var nav: Node = ctx.nav
	if _phase_seconds > _travel_limit: return "failed"
	if nav.state == nav.State.ARRIVED and _at_spot(ctx):
		nav.stay()
		nav.face_point = _spot.position
		return "arrived"
	if nav.state in [nav.State.BLOCKED, nav.State.UNREACHABLE]: return "failed"
	# Exhausted/alternative routes outside the interaction point are not completion.
	if not nav._has_target and _phase_seconds > 1.0:
		_tries += 1
		if _tries > 2: return "failed"
		nav.go_to(_point, _gait, false)
	return "running"

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	_phase_seconds += delta
	if not _owns(ctx) or _interrupted(ctx): return "failed"
	if _phase == "travel":
		var result := _travel(ctx)
		if result != "arrived": return result
		_begin_tending(ctx)
		return "running"
	return _tend(ctx)

func _begin_tending(ctx: Dictionary) -> void:
	_phase = "align"
	_phase_seconds = 0.0
	ctx.nav.face_point = _spot.position

func _tend(ctx: Dictionary) -> String:
	if not _at_spot(ctx): return "failed"
	if _phase == "align":
		if _phase_seconds > ALIGN_LIMIT: return "failed"
		if not _aligned(ctx): return "running"
		_phase = "inspect"
		_phase_seconds = 0.0
		return "running"
	_look_down(ctx)
	if _phase == "inspect":
		_state.touch(_token, .2 * sin(PI * clampf(_phase_seconds / INSPECT_SECONDS, 0.0, 1.0)))
		if _phase_seconds < INSPECT_SECONDS: return "running"
		if not is_instance_valid(_prop) and not _hold(ctx, CAN, Vector3.ZERO): return "failed"
		_phase = "pour"
		_phase_seconds = 0.0
		return "running"
	if _phase == "pour":
		if not is_instance_valid(_prop) or _prop.is_queued_for_deletion(): return "failed"
		var fraction := clampf(_phase_seconds / POUR_SECONDS, 0.0, 1.0)
		_set_tilt(-.65 * sin(PI * fraction))
		_state.touch(_token, sin(PI * fraction))
		if _floating and ctx.actor.has_method("cast_magic"): ctx.actor.cast_magic(.8)
		if _phase_seconds < POUR_SECONDS: return "running"
		if not _mark_watered(ctx): return "failed"
		_phase = "done"
		return "done"
	return "failed"

func _aligned(ctx: Dictionary) -> bool:
	if float(ctx.actor.get("actual_speed")) > .08: return false
	var toward: Vector3 = _spot.position - ctx.actor.global_position
	toward.y = 0.0
	if toward.length_squared() < .01: return true
	var forward: Vector3 = -ctx.actor.global_basis.z
	forward.y = 0.0
	return forward.normalized().dot(toward.normalized()) >= .96

func _look_down(ctx: Dictionary) -> void:
	var secondary: RefCounted = ctx.actor.get("secondary")
	if secondary != null: secondary.look_toward(Vector3(-.16, 0, 0), .6)

func _hold(ctx: Dictionary, scene_path: String, grip: Vector3) -> bool:
	var scene := load(scene_path) as PackedScene
	if scene == null: return false
	_grip = grip
	# Authored can spout is +X; face it toward the garden (-Z in the mouth frame).
	_tool_basis = Basis(Vector3.UP, PI * .5) if scene_path == CAN else Basis.IDENTITY
	_prop = CARRY.hold(ctx.actor, scene, Transform3D(_tool_basis, -(_tool_basis * grip)))
	if not is_instance_valid(_prop): return false
	_prop.carry_seconds = TRAVEL_LIMIT + 30.0
	var magic: Node = ctx.actor.get("magic")
	_floating = magic != null and ctx.actor.has_method("cast_magic") and ctx.actor.cast_magic(2.0)
	if _floating: _glows = magic.glow_object(_prop)
	_set_tilt(0.0)
	return true

func _set_tilt(angle: float) -> void:
	if not is_instance_valid(_prop): return
	var basis := Basis(Vector3.RIGHT, angle) * _tool_basis
	var float_offset := Vector3(.35, .1, -.15) if _floating else Vector3.ZERO
	# Ease over the half-second action beat so the can tips smoothly, not in steps.
	_prop.glide_to(Transform3D(basis, float_offset - basis * _grip), .5)

func _mark_watered(_ctx: Dictionary) -> bool:
	return _state.mark_watered(_token, _source_well)

func _owns(ctx: Dictionary) -> bool:
	return _owns_navigation(ctx) and is_instance_valid(_state) and _state.owns(_token)

func _owns_navigation(ctx: Dictionary) -> bool:
	return _claimed and is_instance_valid(ctx.nav) and str(ctx.nav.command_owner) == _owner

func _interrupted(ctx: Dictionary) -> bool:
	var actor: Node3D = ctx.actor
	if actor.get("sleeping") == true: return true
	var flight: RefCounted = actor.get("flight")
	if flight != null and flight.active(): return true
	return actor.has_method("action_interruption_reason") and not str(actor.action_interruption_reason()).is_empty()

func stop(ctx: Dictionary) -> void:
	release(ctx)

func release(ctx: Dictionary) -> void:
	MAGIC.unglow_object(_glows)
	_glows.clear()
	if is_instance_valid(_prop): _prop.queue_free()
	_prop = null
	_unlock_spot()
	if is_instance_valid(_state) and not _step_key.is_empty(): _state.cancel_step(_step_key)
	# A new command/body owner must keep its motion, facing and wander decision.
	if _owns_navigation(ctx):
		ctx.nav.stay()
		ctx.nav.face_point = Vector3.INF
		ctx.nav.command_owner = ""
		ctx.nav.wander_enabled = _old_wander
	_claimed = false
