extends RefCounted
## Chat stops (docs/PONY_ACTIVITIES_PLAN.md A2): two ponies ambling about on their own who pass
## within a few metres sometimes stop, turn to each other, smile and nod along for a few seconds,
## then go on their way. Only free wanderers take part: never a pony on a plan step, a command,
## a follow, a route, a seat, a cuddle, a kiss, a group outing or a conversation with the player;
## anything that takes either pony ends the stop and leaves the new owner alone.
## Ticked from DayRunner's half-second beat over the live ponies; no AI call, no callback.
const OWNER := "chat:"
const RANGE := 3.5
const NEAR := 1.1
const CHANCE := .35
const COOLDOWN := 150.0
const SECONDS := Vector2(7.0, 13.0)
var _rng := RandomNumberGenerator.new()
var _cool: Dictionary = {}      # id -> seconds until she may stop to chat again
var _stops: Array = []          # {a, b, left, owner, wander_a, wander_b, beat}
var started := 0
var chance := CHANCE

func _init() -> void:
	_rng.seed = hash("chat-stops")

## actors: resident id -> live actor. busy: ids running a plan step this beat.
func tick(actors: Dictionary, busy: Dictionary, delta: float) -> void:
	for id: String in _cool.keys():
		_cool[id] = float(_cool[id]) - delta
		if float(_cool[id]) <= 0.0: _cool.erase(id)
	_advance(delta)
	var free: Array = []
	for id: String in actors:
		if _cool.has(id) or busy.has(id): continue
		var actor: Node3D = actors[id]
		if _free(actor): free.append(id)
	for i in free.size():
		var a: String = free[i]
		if _cool.has(a): continue
		for j in range(i + 1, free.size()):
			var b: String = free[j]
			if _cool.has(b): continue
			var pa: Vector3 = (actors[a] as Node3D).global_position
			var pb: Vector3 = (actors[b] as Node3D).global_position
			var gap := Vector2(pa.x - pb.x, pa.z - pb.z).length()
			if gap > RANGE or gap < NEAR or absf(pa.y - pb.y) > 1.0: continue
			# A passing glance most of the time; a stop now and then.
			_cool[a] = COOLDOWN * .25; _cool[b] = COOLDOWN * .25
			if _rng.randf() < chance: _begin(a, b, actors[a], actors[b])
			break

func _begin(id_a: String, id_b: String, a: Node3D, b: Node3D) -> void:
	var na: Node = a.get_node("Navigator")
	var nb: Node = b.get_node("Navigator")
	var owner := OWNER + str(a.get_instance_id()) + ":" + str(b.get_instance_id())
	var stop := {"a": a, "b": b, "na": na, "nb": nb, "owner": owner,
		"wander_a": bool(na.wander_enabled), "wander_b": bool(nb.wander_enabled),
		"left": _rng.randf_range(SECONDS.x, SECONDS.y), "beat": 0}
	for pair: Array in [[a, na, b], [b, nb, a]]:
		var nav: Node = pair[1]
		nav.command_owner = owner
		nav.stay()
		nav.wander_enabled = false
		nav.face_point = (pair[2] as Node3D).global_position
		var expressions: Variant = (pair[0] as Node3D).get("expressions")
		if expressions != null: expressions.touch("chat", .6, 0.0)
	_cool[id_a] = COOLDOWN; _cool[id_b] = COOLDOWN
	_stops.append(stop)
	started += 1

func _advance(delta: float) -> void:
	for stop: Dictionary in _stops.duplicate():
		stop.left = float(stop.left) - delta
		stop.beat = int(stop.beat) + 1
		var ok := true
		for side: String in ["a", "b"]:
			var actor: Node3D = stop[side]
			var nav: Node = stop["n" + side]
			if not is_instance_valid(actor) or not is_instance_valid(nav) or str(nav.command_owner) != str(stop.owner) \
					or bool(actor.get("sleeping")) or actor.is_held() or is_instance_valid(actor.get("conversation_target")):
				ok = false
		if not ok or float(stop.left) <= 0.0:
			_end(stop)
			continue
		# Take turns: the listener nods, the speaker tips her head. Mouths stay closed: this chat is
		# silent, and the old held open_soft (never reset on the listener) read as a confused gape.
		var talker := "a" if int(stop.beat) % 4 < 2 else "b"
		for side: String in ["a", "b"]:
			var actor: Node3D = stop[side]
			var secondary: Variant = actor.get("secondary")
			if secondary == null: continue
			if side == talker:
				secondary.look_toward(Vector3(.05, 0.0, _rng.randf_range(-.08, .08)), .5)
			else:
				secondary.look_toward(Vector3(-.12 if int(stop.beat) % 2 == 0 else .02, 0.0, 0.0), .45)

func _end(stop: Dictionary) -> void:
	_stops.erase(stop)
	for side: String in ["a", "b"]:
		var actor: Node3D = stop[side]
		var nav: Node = stop["n" + side]
		if is_instance_valid(actor):
			var expressions: Variant = actor.get("expressions")
			if expressions != null: expressions.release_touch("chat")
		# A newer owner (the player, a plan, bedtime) keeps her as it found her.
		if is_instance_valid(nav) and str(nav.command_owner) == str(stop.owner):
			nav.face_point = Vector3.INF
			nav.command_owner = ""
			nav.wander_enabled = bool(stop["wander_" + side])

## End every stop now (world teardown, runner exit).
func clear() -> void:
	for stop: Dictionary in _stops.duplicate(): _end(stop)

func active_owner(actor: Node3D) -> String:
	for stop: Dictionary in _stops:
		if stop.a == actor or stop.b == actor: return str(stop.owner)
	return ""

## A free wanderer standing or ambling on her own, near enough to be drawn in full.
static func _free(actor: Node3D) -> bool:
	if not is_instance_valid(actor) or not actor.is_inside_tree() or not actor.is_in_group("sim_ponies"): return false
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null or str(nav.command_owner) != "" or str(nav.reserved_by) != "" or not bool(nav.wander_enabled): return false
	if is_instance_valid(nav.get("_follow_target")): return false
	if int(actor.get("sim_tier")) > 1 or bool(actor.get("sleeping")) or bool(actor.get("motion_paused")) or actor.is_held(): return false
	if actor.has_meta("seated") or bool(actor.get_meta("cuddle_active", false)) or bool(actor.get_meta("affection_active", false)): return false
	if not (actor.get_meta("social_group", {}) as Dictionary).is_empty(): return false
	if is_instance_valid(actor.get("conversation_target")) or (actor.has_method("is_speaking") and actor.is_speaking()): return false
	var posture: Variant = actor.get("posture")
	if posture != null and (bool(posture.get("intentional_rest")) or posture.active()): return false
	return actor.grounded()
