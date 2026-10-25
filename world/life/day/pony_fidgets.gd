extends RefCounted
## Idle fidgets for a pony standing about with nothing to do (docs/PONY_ACTIVITIES_PLAN.md A1):
## now and then she stretches a hind leg back, yawns, lifts a forehoof, looks up at the sky, swishes
## her tail, turns a little on the spot, and after standing a long while sits or lies down for a
## bit and gets up again. One instance per resident, ticked from DayRunner's existing half-second
## beat; no callback of its own. Stretch and yawn go through pony_affection.gd fidget(), which
## drops them the moment anything touches, holds, moves or speaks to her. Ear flicks, tail swishes
## (world/life/idle/pony_idle_twitches.gd) and weight shifts (pony_secondary_motion.gd) run on the
## pony herself, for every pony; this picker adds the bigger, rarer gestures.
##
## Who she belongs to decides whether she may fidget (2026-10-14: the first version demanded no
## command owner at all, but the living world owns every free resident as "life:<id>" and a day
## step owns her for its whole stay, so nopony ever fidgeted): her own life (free, the living
## world, a day step that is just spending time somewhere, friends out together) leaves room for
## it; anything else (the player, a conversation, a kiss, a cuddle, a seat, the arrival story,
## a ride, a lease) does not.
const STAND := 2
const REST := 1
const NONE := 0
## Owners whose stand-still time is her own.
const AMBIENT_OWNERS := ["life:", "social:", "day:"]
## Owners under which she may also turn on the spot and sit down by herself: the living world
## holding her (spending time, or waiting while the player is near) and a day step's stay.
const SETTLING_OWNERS := ["life:", "day:"]
const WAIT := Vector2(8.0, 25.0)

var _rng := RandomNumberGenerator.new()
var _wait := -1.0
var last := ""
## Seconds she has stood idle in a row, and how long she stands before she may sit down.
var _stood := 0.0
var _patience := 60.0
## A rest she took by herself: the posture she asked for, the owner then, and seconds left.
var _rest_kind := ""
var _rest_owner := ""
var _rest_left := -1.0
## A turn on the spot she is making: the point she faces and seconds left.
var _turn_point := Vector3.INF
var _turn_left := 0.0
var _turn_nav: WeakRef

func tick(actor: Node3D, resident: String, delta: float, busy: bool) -> void:
	if _wait < 0.0:
		_rng.seed = hash("idle-fidget:" + resident) ^ randi()
		# The first one comes soon; after that 8-25 s apart, never in step with anypony else.
		_wait = _rng.randf_range(3.0, 14.0)
		_patience = _rng.randf_range(45.0, 110.0)
	var nav: Node = actor.get_node_or_null("Navigator") if is_instance_valid(actor) else null
	_advance_turn(nav, delta)
	var mode := level(actor, nav, busy)
	_advance_rest(actor, nav, mode, delta)
	var affection: Node = actor.get_node_or_null("Affection") if is_instance_valid(actor) else null
	if mode != STAND:
		if affection != null and affection.has_method("cancel_fidget") and mode == NONE: affection.cancel_fidget()
		if mode == NONE: _end_turn()
		_stood = 0.0
		_wait = maxf(_wait, 4.0)
		return
	_stood += delta
	_wait -= delta
	if _wait > 0.0: return
	_wait = _rng.randf_range(WAIT.x, WAIT.y)
	var owner := str(nav.get("command_owner"))
	# Standing a long while: sit or lie down for a bit (she gets up again by herself).
	if _stood > _patience and _settling(owner, nav) and _rng.randf() < .6 and _sit_down(actor, owner):
		return
	var choice := _rng.randf()
	if choice < .2 and affection != null and affection.has_method("fidget") and affection.fidget("stretch", _rng.randf() < .5):
		last = "stretch"
		return
	if choice < .34 and affection != null and affection.has_method("fidget") and affection.fidget("yawn"):
		last = "yawn"
		return
	# Forehoof lift: the HERO leg solver only.
	if choice < .48 and int(actor.get("sim_tier")) == 0:
		var hoof: RefCounted = actor.get("hoof_hold") as RefCounted
		if hoof != null and hoof.raise(_rng.randi_range(0, 1), _rng.randf_range(.9, 1.5)):
			last = "hoof_lift"
			return
	if choice < .7 and _settling(owner, nav) and _start_turn(actor, nav):
		last = "turn"
		return
	if choice < .85:
		var twitches: RefCounted = actor.get("idle_twitches") as RefCounted
		if twitches != null and twitches.swish_tail(actor):
			var secondary: RefCounted = actor.get("secondary") as RefCounted
			if secondary != null and secondary.has_method("shift_weight"): secondary.shift_weight()
			last = "swish"
			return
	var look: RefCounted = actor.get("secondary") as RefCounted
	if look != null:
		# Positive pitch looks up (pony_secondary_motion.gd: forward is -Z, so +X turns the muzzle up).
		look.look_toward(Vector3(.22, _rng.randf_range(-.15, .15), 0.0), 1.5)
		last = "sky_look"

## Standing idle in view, free of every owner but her own life: STAND (standing still, settled),
## REST (sitting or lying, settled), or NONE (no plan step body work, command, follow, route, seat,
## cuddle, kiss, speech, conversation, held/carried prop, flight, sleep, or the arrival story).
static func level(actor: Node3D, nav: Node, busy: bool) -> int:
	if busy or not is_instance_valid(actor) or not actor.is_inside_tree() or not is_instance_valid(nav): return NONE
	# The player's own pony form leaves sim_ponies.
	if not actor.is_in_group("sim_ponies"): return NONE
	if int(actor.get("sim_tier")) > 1: return NONE
	if not ambient_owner(str(nav.get("command_owner"))) or str(nav.get("reserved_by")) != "": return NONE
	if bool(nav.get("_has_target")) or is_instance_valid(nav.get("_follow_target")): return NONE
	if actor.has_meta("seated") or bool(actor.get_meta("cuddle_active", false)) or bool(actor.get_meta("affection_active", false)): return NONE
	if bool(actor.get("sleeping")) or bool(actor.get("motion_paused")): return NONE
	if actor.needs_full_rate() or not actor.grounded(): return NONE
	if float(actor.get("actual_speed")) > .05: return NONE
	if is_instance_valid(actor.get("conversation_target")) or is_instance_valid(actor.get("action_gaze_target")): return NONE
	if actor.has_method("is_speaking") and actor.is_speaking(): return NONE
	var posture: RefCounted = actor.get("posture") as RefCounted
	if posture == null: return STAND
	if not posture.settled(): return NONE
	return REST if posture.active() else STAND

static func eligible(actor: Node3D, nav: Node, busy: bool) -> bool:
	return level(actor, nav, busy) == STAND

static func ambient_owner(owner: String) -> bool:
	if owner.is_empty(): return true
	for prefix: String in AMBIENT_OWNERS:
		if owner.begins_with(prefix): return true
	return false

## Turning and sitting change where she faces and how she rests: only under her own life's
## owners, never while somepony else steers her facing (the living world's group circle, a visit
## facing its host).
func _settling(owner: String, nav: Node) -> bool:
	var face := _face_point(nav)
	if face.is_finite() and face != _turn_point: return false
	for prefix: String in SETTLING_OWNERS:
		if owner.begins_with(prefix): return true
	return false

func _sit_down(actor: Node3D, owner: String) -> bool:
	var kind := "lie_down" if _rng.randf() < .3 else "sit"
	if not actor.has_method("request_posture") or not actor.request_posture(kind): return false
	_end_turn()
	_rest_kind = kind
	_rest_owner = owner
	_rest_left = _rng.randf_range(25.0, 70.0)
	_stood = 0.0
	_patience = _rng.randf_range(60.0, 140.0)
	last = kind
	return true

## Her own rest: she gets up again when it is over, unless something else has taken her (another
## posture asked for, another owner, a conversation); then it is no longer hers to end. A sit that
## pony_posture's automatic rest turned into lying down is still hers.
func _advance_rest(actor: Node3D, nav: Node, mode: int, delta: float) -> void:
	if _rest_left < 0.0: return
	if not is_instance_valid(actor) or not is_instance_valid(nav):
		_rest_left = -1.0
		return
	var requested := str(actor.posture_status().get("requested", "stand")) if actor.has_method("posture_status") else "stand"
	var still_mine := requested == _rest_kind or (_rest_kind == "sit" and requested == "lie_down")
	if not still_mine or str(nav.get("command_owner")) != _rest_owner:
		_rest_left = -1.0
		return
	if mode == NONE: return   # someone is with her (talking, touching): the rest waits
	_rest_left -= delta
	if _rest_left > 0.0: return
	_rest_left = -1.0
	actor.request_posture("stand")
	last = "stand_up"

## A turn of 25-70 degrees on the spot (20-35 while the player is close by): the navigator's
## facing walks her legs round, as when she faces a group.
func _start_turn(actor: Node3D, nav: Node) -> bool:
	if not ("face_point" in nav): return false
	var forward := -actor.global_basis.z
	forward.y = 0.0
	if forward.length() < .1: return false
	var span := Vector2(25.0, 70.0)
	var camera := actor.get_viewport().get_camera_3d() if actor.get_viewport() != null else null
	if camera != null and camera.global_position.distance_to(actor.global_position) < 5.0: span = Vector2(20.0, 35.0)
	var yaw := deg_to_rad(_rng.randf_range(span.x, span.y)) * (-1.0 if _rng.randf() < .5 else 1.0)
	_turn_point = actor.global_position + forward.normalized().rotated(Vector3.UP, yaw) * 4.0
	_turn_left = _rng.randf_range(2.5, 3.5)
	_turn_nav = weakref(nav)
	nav.face_point = _turn_point
	return true

func _advance_turn(nav: Node, delta: float) -> void:
	if not _turn_point.is_finite(): return
	_turn_left -= delta
	if _turn_left <= 0.0 or not is_instance_valid(nav) or _face_point(nav) != _turn_point: _end_turn()

## Hands her facing back, only if it is still the turn's point.
func _end_turn() -> void:
	if not _turn_point.is_finite(): return
	var nav: Node = _turn_nav.get_ref() as Node if _turn_nav != null else null
	if is_instance_valid(nav) and _face_point(nav) == _turn_point: nav.face_point = Vector3.INF
	_turn_point = Vector3.INF
	_turn_left = 0.0

static func _face_point(nav: Node) -> Vector3:
	var face: Variant = nav.get("face_point") if is_instance_valid(nav) else null
	return face if face is Vector3 else Vector3.INF
