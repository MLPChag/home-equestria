extends "res://world/life/day/day_action.gd"
## Go flying for the fun of it (pegasi): take off, a loop-de-loop or two, land nearby.

func start(ctx: Dictionary) -> bool:
	if not ctx.actor.has_method("request_fun_flight"): return false
	claim(ctx)
	if not ctx.actor.request_fun_flight(): release(ctx); return false
	return true

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	var flying: bool = ctx.actor.get("flight") != null and ctx.actor.flight.active()
	return "running" if flying and seconds < 180.0 else "done"
