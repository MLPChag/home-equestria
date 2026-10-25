extends "res://world/life/day/actions/tend.gd"
## Fetch the mail: walk to her own mailbox, float the letter out of its door with magic into her
## mouth, carry it home and deliver it inside. The flag drops when the letter leaves the box
## (kit_state.gd collect_mail); a step cut short before delivery puts the letter back.
##
## Kit mailboxes stand a metre up (activity/fit.json), above a standing pony's mouth
## (0.66-0.71 m on the real rig), so only unicorns, who reach it with magic, take this step.
const FITS := preload("res://world/props/ponyville_kit/kit_fits.gd")
const HOME := preload("res://world/buildings/house_interior.gd")
const LETTER := "res://world/props/ponyville_kit/activity/letter.scn"
const FLOAT_SECONDS := 1.6
var _fit: Dictionary = {}
var _placement := Transform3D.IDENTITY
var _home_point := Vector3.INF
var _home: Node3D

func start(ctx: Dictionary) -> bool:
	if ctx.actor.get("magic") == null or not ctx.actor.has_method("cast_magic"): return false
	_fit = FITS.get_kind("mailbox")
	if _fit.is_empty() or not bool(_fit.get("base_flag_removed", false)): return false
	var spot: Dictionary = _resolve(ctx, "mailbox")
	var state: Node = ctx.get("kit_state")
	if spot.is_empty() or not is_instance_valid(state): return false
	if not bool(state.snapshot(str(spot.id)).get("mail_pending", false)): return false
	_home_point = place_point(ctx, "home")
	if not _home_point.is_finite(): return false
	_placement = spot.transform
	var approach: Vector3 = _placement * FITS.point(_fit.get("approach"))
	if not approach.is_finite(): return false
	if is_instance_valid(WorldTerrain.instance):
		var height: float = WorldTerrain.instance.height_at(approach)
		if is_finite(height): approach.y = height
	spot = spot.duplicate()
	spot.approach = approach
	return _begin(ctx, spot)

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	_phase_seconds += delta
	if not _owns(ctx) or _interrupted(ctx): return "failed"
	match _phase:
		"travel":
			var result := _travel(ctx)
			if result != "arrived": return result
			_begin_tending(ctx)
			return "running"
		"align":
			if not _at_spot(ctx) or _phase_seconds > ALIGN_LIMIT: return "failed"
			if not _aligned(ctx): return "running"
			# The horn glows only where her horn is drawn (HERO); her magic works at any detail.
			ctx.actor.cast_magic(FLOAT_SECONDS + 1.0)
			if not _state.collect_mail(_token): return "failed"
			if not _take_letter(ctx): return "failed"
			_phase = "float"
			_phase_seconds = 0.0
			return "running"
		"float":
			if not _at_spot(ctx) or not is_instance_valid(_prop): return "failed"
			_look_down(ctx)
			if _phase_seconds < FLOAT_SECONDS: return "running"
			MAGIC.unglow_object(_glows)
			_glows.clear()
			_phase = "home"
			_phase_seconds = 0.0
			_tries = 0
			_home = HOME.at(ctx.tree, _home_point)
			ctx.nav.face_point = Vector3.INF
			_travel_limit = maxf(TRAVEL_LIMIT, ctx.actor.global_position.distance_to(_home_point) / .3 + 60.0)
			ctx.nav.go_to(_home_point, ctx.nav.Gait.WALK, false)
			return "running"
		"home":
			return _carry_home(ctx)
	return "failed"

func _carry_home(ctx: Dictionary) -> String:
	if not is_instance_valid(_prop) or _prop.is_queued_for_deletion(): return "failed"
	var nav: Node = ctx.nav
	var here: Vector3 = ctx.actor.global_position
	var home := false
	if is_instance_valid(_home): home = _home.contains(here) and not nav.house_travel.active()
	else: home = arrived(ctx, _home_point, 1.0)
	if home:
		if not _state.deliver_mail(_token): return "failed"
		nav.stay()
		_prop.queue_free()
		_prop = null
		_phase = "done"
		return "done"
	if _phase_seconds > _travel_limit: return "failed"
	if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
		_tries += 1
		if _tries > 2: return "failed"
		nav.go_to(_home_point, nav.Gait.WALK, false)
	elif not nav._has_target and _phase_seconds > 3.0:
		nav.go_to(_home_point, nav.Gait.WALK, false)
	return "running"

## The letter appears where it sat in the mailbox door and glides into her mouth, glowing.
func _take_letter(ctx: Dictionary) -> bool:
	var scene := load(LETTER) as PackedScene
	if scene == null: return false
	_prop = CARRY.hold(ctx.actor, scene, Transform3D.IDENTITY)
	if not is_instance_valid(_prop): return false
	_prop.carry_seconds = TRAVEL_LIMIT + 60.0
	_prop._process(0.0)
	var rest: Transform3D = _placement * FITS.transform(_fit.get("letter_rest"))
	if rest.origin.is_finite(): _prop.glide_from(_prop.global_transform.affine_inverse() * rest, FLOAT_SECONDS)
	var magic: Node = ctx.actor.get("magic")
	if magic != null: _glows = magic.glow_object(_prop)
	return true
