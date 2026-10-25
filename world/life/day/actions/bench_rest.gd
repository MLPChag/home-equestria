extends "res://world/life/day/day_action.gd"
## Seating owns support, hop and posture. This handler owns only the outing and its cup.
## Tea requires a measured TeaRest marker, positioned for the authored cup origin.
const CARRY := preload("res://world/life/day/pony_snack.gd")
const CUP_PATH := "res://world/props/ponyville_kit/activity/tea_cup.scn"
var _cup_scene: PackedScene
const MAGIC := preload("res://world/characters/magic/unicorn_magic.gd")
var _point := Vector3.INF
var _seat: Node3D
var _seating: Node
var _phase := "travel"
var _stay := 60.0
var _rest: Node3D
var _cup: Node3D
var _held_cup: Node3D
var _glow: Array = []
var _next_sip := 8.0
var _sip_left := 0.0
var _tea := false
var _travel_limit := 180.0

func start(ctx: Dictionary) -> bool:
	var selected: Dictionary = spot(ctx)
	var seat_point: Vector3 = selected.get("seat_point", Vector3.INF)
	_point = selected.get("approach", Vector3.INF)
	if not _point.is_finite() or not seat_point.is_finite(): return false
	for candidate: Node in ctx.tree.get_nodes_in_group("pony_seats"):
		if candidate is Node3D and str(candidate.get_meta("kit_spot_id", "")) == str(selected.get("id", "")):
			_seat = candidate as Node3D; break
	_seating = ctx.tree.get_first_node_in_group("pony_seating")
	if not is_instance_valid(_seat) or not is_instance_valid(_seating): return false
	_tea = str(ctx.step.get("item", "")) == "tea"
	if _tea:
		_rest = _seat.get_node_or_null("TeaRest") as Node3D
		if not is_instance_valid(_rest) or not ResourceLoader.exists(CUP_PATH): return false
		_cup_scene = load(CUP_PATH) as PackedScene
		if _cup_scene == null: return false
	claim(ctx)
	_stay = duration(float(ctx.step.get("minutes", 20.0)))
	# Seating walks her the last stretch and hops her on: any walkable point near the front will do.
	if ctx.nav.has_method("command_support"):
		var walkable: Vector3 = ctx.nav.command_support(_point)
		if walkable.is_finite() and walkable.distance_to(_point) <= .8: _point = walkable
	# From wherever her day left her: trot when far, and allow the time that walk takes.
	var far: float = ctx.actor.global_position.distance_to(_point)
	_travel_limit = maxf(180.0, far / .3 + 60.0)
	ctx.nav.go_to(_point, ctx.nav.Gait.TROT if far > 40.0 else ctx.nav.Gait.WALK)
	return true

func tick(ctx: Dictionary, delta: float) -> String:
	if not _owns(ctx) or not is_instance_valid(_seat) or not is_instance_valid(_seating): return "failed"
	seconds += delta
	match _phase:
		"travel":
			if arrived(ctx, _point, .65):
				if not _seating.sit(ctx.actor, 1.0, _seat, {"owner": "day:" + str(ctx.id)}): return "failed"
				_phase = "settle"; seconds = 0.0
			elif ctx.nav.state in [ctx.nav.State.UNREACHABLE, ctx.nav.State.BLOCKED] or seconds > _travel_limit:
				return "failed"
		"settle":
			var phase: String = _seating.phase(ctx.actor)
			if phase == "seated":
				_phase = "rest"; seconds = 0.0
				if _tea:
					if not is_instance_valid(_rest): return "failed"
					_cup = _cup_scene.instantiate() as Node3D
					_rest.add_child(_cup)
			elif phase.is_empty() or seconds > 70.0: return "failed"
		"rest":
			if _seating.phase(ctx.actor) != "seated": return "failed"
			if _tea and (not is_instance_valid(_rest) or not is_instance_valid(_cup)): return "failed"
			if seconds >= _stay: return "done"
			if _tea: _tea_tick(ctx, delta)
	return "running"

func _tea_tick(ctx: Dictionary, delta: float) -> void:
	if _sip_left > 0.0:
		_sip_left = maxf(0.0, _sip_left - delta)
		if _sip_left == 0.0:
			_end_sip()
		elif is_instance_valid(_held_cup):
			var lift := Vector3(.22, .08, 0) if is_instance_valid(ctx.actor.get("magic")) else Vector3.ZERO
			_held_cup.offset = Transform3D(Basis(Vector3.RIGHT, -.25 * sin(_sip_left * PI / 2.0)), lift)
		return
	if seconds < _next_sip: return
	_next_sip = seconds + 16.0
	_held_cup = CARRY.hold(ctx.actor, _cup_scene, Transform3D.IDENTITY)
	if not is_instance_valid(_held_cup): return
	_held_cup.carry_seconds = 3.0
	_sip_left = 2.0
	_cup.hide()
	var magic: Node = ctx.actor.get("magic")
	if is_instance_valid(magic) and ctx.actor.cast_magic(2.0):
		_glow = magic.glow_object(_held_cup)

func _end_sip() -> void:
	MAGIC.unglow_object(_glow); _glow.clear()
	if is_instance_valid(_held_cup): _held_cup.queue_free()
	_held_cup = null
	if is_instance_valid(_cup): _cup.show()

func _owns(ctx: Dictionary) -> bool:
	return is_instance_valid(ctx.get("nav")) and str(ctx.nav.command_owner) == "day:" + str(ctx.id)

func stop(ctx: Dictionary) -> void:
	release(ctx)

func release(ctx: Dictionary) -> void:
	_end_sip()
	if is_instance_valid(_cup): _cup.queue_free()
	_cup = null
	# Never clear a replacement action's navigation or posture request.
	if _owns(ctx):
		if is_instance_valid(ctx.get("actor")): ctx.actor.request_posture("stand")
		super.release(ctx)
