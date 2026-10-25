extends "res://world/life/day/actions/tend.gd"
## One ground errand under one day lease: well, fill, carry, then tend the owned garden.
const BUCKET := "res://world/props/household/fishing-bucket.scn"
## Measured handle top. Pivot at the actual lip; a forward offset detaches the handle.
const BUCKET_GRIP := Vector3(0, .477, 0)
const DRAW_SECONDS := 4.0
var _garden: Dictionary = {}

func _set_tilt(angle: float) -> void:
	# The bucket hangs below its handle. Tip its base forward toward the garden;
	# the can's opposite pivot direction swings this bucket into the pony's chest.
	super._set_tilt(-angle)

func start(ctx: Dictionary) -> bool:
	_garden = _resolve(ctx, "garden")
	if _garden.is_empty(): return false
	if not _begin(ctx, _resolve(ctx, "well")): return false
	_phase = "well_travel"
	return true

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	_phase_seconds += delta
	if not _owns(ctx) or _interrupted(ctx): return "failed"
	match _phase:
		"well_travel":
			var result := _travel(ctx)
			if result != "arrived": return result
			_phase = "well_align"
			_phase_seconds = 0.0
			return "running"
		"well_align":
			if not _at_spot(ctx) or _phase_seconds > ALIGN_LIMIT: return "failed"
			if not _aligned(ctx): return "running"
			if not _hold(ctx, BUCKET, BUCKET_GRIP): return "failed"
			_phase = "draw"
			_phase_seconds = 0.0
			return "running"
		"draw":
			if not _at_spot(ctx) or not is_instance_valid(_prop): return "failed"
			_look_down(ctx)
			_set_tilt(-.15 * sin(PI * clampf(_phase_seconds / DRAW_SECONDS, 0.0, 1.0)))
			if _floating and ctx.actor.has_method("cast_magic"): ctx.actor.cast_magic(.8)
			if _phase_seconds < DRAW_SECONDS: return "running"
			if not _state.mark_water_drawn(_token): return "failed"
			_source_well = str(_spot.id)
			_unlock_spot()
			if not _lock_spot(ctx, _garden): return "failed"
			_set_tilt(0.0)
			_navigate(ctx)
			_phase = "carry"
			return "running"
		"carry":
			if not is_instance_valid(_prop) or _prop.is_queued_for_deletion(): return "failed"
			var result := _travel(ctx)
			if result != "arrived": return result
			_begin_tending(ctx)
			return "running"
	return _tend(ctx)
