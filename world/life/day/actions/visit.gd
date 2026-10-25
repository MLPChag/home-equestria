extends "res://world/life/day/day_action.gd"
## Visit another pony. In town: walk up to her wherever she is and spend a while with her (they
## count as company afterwards, so they may go on together). On her cloud home (Rainbow Dash on the
## Cloudominium): a pegasus flies up, lands on a free spot of the cloud near her, sits a while
## and flies back down. Fails if she is not about, or on a cloud and the visitor has no wings.

var _host: Node3D
var _host_id := ""
var _phase := "travel"
var _stay := 60.0
var _spot := Vector3.INF
var _sky := false

func start(ctx: Dictionary) -> bool:
	_host_id = str(ctx.step.target)
	var live: Dictionary = ctx.population.live.get(_host_id, {})
	_host = live.get("actor")
	if not is_instance_valid(_host) or not _host.is_inside_tree(): return false
	_stay = duration(float(ctx.step.minutes))
	var rest: Node = ctx.night_rest
	if rest != null and rest.has_method("sky_guest_spot") and rest.at_sky_home(_host_id):
		if not ctx.actor.has_method("request_flight"): return false
		_spot = rest.sky_guest_spot(_host_id, str(ctx.id))
		if not _spot.is_finite(): return false
		claim(ctx)
		if not ctx.actor.request_flight(_spot, 0.0, true): release(ctx); return false
		_sky = true
		return true
	claim(ctx)
	ctx.nav.go_to(_beside(ctx), ctx.nav.Gait.TROT if ctx.actor.global_position.distance_to(_host.global_position) > 30.0 else ctx.nav.Gait.WALK)
	return true

func _beside(ctx: Dictionary) -> Vector3:
	var away: Vector3 = ctx.actor.global_position - _host.global_position
	away.y = 0.0
	away = away.normalized() if away.length() > 0.1 else Vector3.FORWARD
	return _host.global_position + away * 1.6

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	if not is_instance_valid(_host): return "failed"
	var nav: Node = ctx.nav
	var flying: bool = ctx.actor.get("flight") != null and ctx.actor.flight.active()
	match _phase:
		"travel":
			if _sky:
				if flying: return "running" if seconds < 120.0 else "failed"
				if ctx.actor.global_position.distance_to(_spot) > 4.0: return "failed"
				_phase = "stay"; seconds = 0.0
				nav.face_point = _host.global_position
				ctx.actor.request_posture("sit")
				return "running"
			if ctx.actor.global_position.distance_to(_host.global_position) < 2.4:
				_phase = "stay"; seconds = 0.0
				nav.stay()
				nav.face_point = _host.global_position
				var life: Node = ctx.runner.life()
				if life != null and life.get("core") != null: life.core.note_company([str(ctx.id), _host_id])
				return "running"
			# She moves about: follow her, at most every few seconds.
			if int(seconds) % 4 == 0 and (not nav._has_target or nav.state in [nav.State.ARRIVED, nav.State.IDLE]):
				nav.go_to(_beside(ctx), nav.Gait.WALK)
			if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED] and seconds > 20.0: return "failed"
			if seconds > 300.0: return "failed"
		"stay":
			nav.face_point = _host.global_position
			if seconds >= _stay:
				ctx.actor.request_posture("stand")
				if _sky:
					_phase = "home"; seconds = 0.0
					var down: Vector3 = ctx.population.home_position(str(ctx.id), true) if ctx.population.has_method("home_position") else Vector3.INF
					if not down.is_finite() or not ctx.actor.request_flight(down, 0.0, true): return "done"
					return "running"
				return "done"
		"home":
			if flying and seconds < 180.0: return "running"
			return "done"
	return "running"
