extends "res://world/life/day/day_action.gd"
## Go to a place and spend a while there in a posture: go to the fountain, eat at Sugarcube
## Corner, buy a scarf at the Boutique, read a book at home, nap at the spa, watch the stars.
## Sitting takes a seat nearby when there is a free one (world/life/seat.gd, benches, sofas).

var _point := Vector3.INF
var _phase := "travel"
var _stay := 60.0
var _tries := 0
var _snack: Node3D
var _home: Node3D
const HOME := preload("res://world/buildings/house_interior.gd")

func start(ctx: Dictionary) -> bool:
	_point = place_point(ctx, str(ctx.step.target))
	if not _point.is_finite(): return false
	_home = HOME.at(ctx.tree, _point)
	if _home != null and _home.has_method("request_visit"):
		if not _home.request_visit(ctx.actor): return false
		_point = _home.visit_point(ctx.actor)
	claim(ctx)
	_stay = duration(float(ctx.step.minutes))
	var far: bool = ctx.actor.global_position.distance_to(_point) > 40.0
	ctx.nav.go_to(_point, ctx.nav.Gait.TROT if far else ctx.nav.Gait.WALK)
	return true

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	var nav: Node = ctx.nav
	if is_instance_valid(_home) and _home.has_method("request_visit") and not _home.request_visit(ctx.actor): return "failed"
	match _phase:
		"travel":
			var reached: bool = arrived(ctx, _point, 3.0) or nav.state == nav.State.ARRIVED
			if is_instance_valid(_home):
				reached = _home.contains(ctx.actor.global_position) and arrived(ctx, _point, .65) and not nav.house_travel.active()
			if reached:
				_phase = "stay"; seconds = 0.0
				nav.stay()
				# An "eat" step: she eats something from the place, visibly (pony_snack.gd).
				if str(ctx.step.get("action", "")) == "eat" and not is_instance_valid(_snack):
					_snack = preload("res://world/life/day/pony_snack.gd").attach(ctx.actor, str(ctx.step.target))
				var posture := str(ctx.step.posture)
				var seating: Node = ctx.tree.get_first_node_in_group("pony_seating")
				if posture == "sit" and seating != null and seating.sit(ctx.actor, 8.0): return "running"
				if posture != "stand": ctx.actor.request_posture(posture)
				return "running"
			if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
				_tries += 1
				if _tries > 2: return "failed"
				nav.go_to(_point, nav.Gait.WALK)
			elif not nav._has_target and seconds > 3.0:
				nav.go_to(_point, nav.Gait.WALK)
			if seconds > 300.0: return "failed"
		"stay":
			if seconds >= _stay:
				ctx.actor.request_posture("stand")
				if is_instance_valid(_snack): _snack.queue_free()
				# Leaving a shop with her purchase, visibly (pony_snack.gd carry mode).
				if str(ctx.step.get("action", "")) == "buy": preload("res://world/life/day/pony_snack.gd").carry_basket(ctx.actor)
				return "done"
	return "running"

func stop(ctx: Dictionary) -> void:
	if is_instance_valid(_snack): _snack.queue_free()
	super.stop(ctx)

func release(ctx: Dictionary) -> void:
	if is_instance_valid(_home) and _home.has_method("release_visit"): _home.release_visit(ctx.actor)
	super.release(ctx)
