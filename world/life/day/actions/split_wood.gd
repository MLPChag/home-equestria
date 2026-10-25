extends "res://world/life/day/actions/tend.gd"
## Split firewood: walk to her own log pile's work stance, turn her back to the log and buck it.
## The log splits only when a rear hoof really reaches it at the kick (activity/fit.json
## contact_box, judged on the posed skeleton); a missed or cut-short kick splits nothing.
## The kick is the accepted affection rear-leg buck (pony_affection.gd work_buck), with no
## player and no knockback. A FAR pony has no posed legs to judge, so her kick fails the step.
const FITS := preload("res://world/props/ponyville_kit/kit_fits.gd")
const HOOVES := ["pony_hoof_L_end", "pony_hoof_R_end"]
## A hoof is a few centimetres round: its end bone within this of the log box counts as a hit.
const HOOF_RADIUS := .06
const KICKS := 2
var _fit: Dictionary = {}
var _placement := Transform3D.IDENTITY
var _facing := Vector3.ZERO
var _contact := AABB()
var _affection: Node
var _skeleton: Skeleton3D
var _kicks := 0
var _judged := false
var _hit := false
var closest := INF   # nearest hoof-to-log gap seen in the last kick (metres), for tests/debug

func start(ctx: Dictionary) -> bool:
	_affection = ctx.actor.get_node_or_null("Affection")
	_skeleton = ctx.actor.get("skeleton")
	if _affection == null or not _affection.has_method("work_buck") or not is_instance_valid(_skeleton): return false
	_fit = FITS.get_kind("log_pile")
	var box := FITS.box(_fit.get("contact_box"))
	var facing := FITS.point(_fit.get("facing"))
	if _fit.is_empty() or not box.has_volume() or not facing.is_finite(): return false
	var spot: Dictionary = _resolve(ctx, "log_pile")
	var state: Node = ctx.get("kit_state")
	if spot.is_empty() or not is_instance_valid(state): return false
	if int(state.snapshot(str(spot.id)).get("split_count", 1)) > 0: return false
	_placement = spot.transform
	_contact = _placement * box
	_facing = (_placement.basis * facing).normalized()
	var approach: Vector3 = _placement * FITS.point(_fit.get("approach"))
	if not approach.is_finite(): return false
	if is_instance_valid(WorldTerrain.instance):
		var height: float = WorldTerrain.instance.height_at(approach)
		if is_finite(height): approach.y = height
	spot = spot.duplicate()
	spot.approach = approach
	return _begin(ctx, spot)

## The kick reaches 0.60 m behind her: the stance may move only a little.
func _snap_radius() -> float:
	return .12

func _begin_tending(ctx: Dictionary) -> void:
	_phase = "align"
	_phase_seconds = 0.0
	ctx.nav.face_point = _point + _facing * 3.0

## Body and the drawn model both face away from the log: the model's pivot eases after a body
## turn, and a kick thrown mid-turn lands beside the log.
func _aligned(ctx: Dictionary) -> bool:
	if float(ctx.actor.get("actual_speed")) > .08: return false
	var want := Vector3(_facing.x, 0.0, _facing.z).normalized()
	var bases: Array = [ctx.actor.global_basis]
	var pivot: Variant = ctx.actor.get("pivot")
	if pivot is Node3D: bases.append((pivot as Node3D).global_basis)
	for basis: Basis in bases:
		var forward: Vector3 = -basis.z
		forward.y = 0.0
		if forward.normalized().dot(want) < .96: return false
	return true

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
			return "running" if _kick(ctx) else "failed"
		"buck":
			if float(_affection.buck_time()) >= 0.0: return "running"
			_stop_judging()
			if _hit:
				if not _state.split_log(_token): return "failed"
				_phase = "done"
				return "done"
			if _kicks >= KICKS: return "failed"
			_phase = "align"
			_phase_seconds = 0.0
			return "running"
	return "failed"

func _kick(ctx: Dictionary) -> bool:
	# A FAR pony has no posed legs to judge: no kick, no wood.
	if int(ctx.actor.get("sim_tier")) == 2: return false
	if not is_instance_valid(_affection) or not _affection.work_buck(): return false
	_kicks += 1
	_phase = "buck"
	_phase_seconds = 0.0
	_judged = false
	_hit = false
	closest = INF
	ctx.nav.stay()
	# Judge on the posed skeleton (after modifiers) only while the kick plays: about 1.3 s.
	if not _skeleton.skeleton_updated.is_connected(_judge): _skeleton.skeleton_updated.connect(_judge)
	return true

## The kick peaks near 0.85 s (sin of the 0.55-1.15 s window): judge the hooves then, once.
func _judge() -> void:
	if _judged or not is_instance_valid(_affection) or not is_instance_valid(_skeleton): return
	var t: float = _affection.buck_time()
	if t < .75: return
	if t > 1.0: _judged = true; return
	for bone_name: String in HOOVES:
		var bone := _skeleton.find_bone(bone_name)
		if bone < 0: continue
		var hoof: Vector3 = _skeleton.global_transform * _skeleton.get_bone_global_pose(bone).origin
		var nearest := Vector3(clampf(hoof.x, _contact.position.x, _contact.end.x),
			clampf(hoof.y, _contact.position.y, _contact.end.y), clampf(hoof.z, _contact.position.z, _contact.end.z))
		closest = minf(closest, hoof.distance_to(nearest))
	if closest <= HOOF_RADIUS: _hit = true

func _stop_judging() -> void:
	if is_instance_valid(_skeleton) and _skeleton.skeleton_updated.is_connected(_judge): _skeleton.skeleton_updated.disconnect(_judge)

func release(ctx: Dictionary) -> void:
	_stop_judging()
	if is_instance_valid(_affection) and _affection.has_method("cancel_work_buck"): _affection.cancel_work_buck()
	super.release(ctx)
