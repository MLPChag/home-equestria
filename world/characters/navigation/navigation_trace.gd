extends RefCounted
## Bounded navigation trace for one pony (phase 0 of docs/NAVIGATION_OVERHAUL_COMPLETE_2026_10_02.txt,
## report docs/NAVIGATION_BASELINE_2026_10_02.md). Off by default: the navigator only creates one
## when a lab enables tracing (user argument --nav-trace, or `enabled = true` from a fixture), so
## normal play allocates and samples nothing. While on, it keeps a ring of SAMPLE_HZ x WINDOW_S
## samples: time, intent and route generation, corridor/waypoint progress, position, command and
## actual speed, contact normal and the recorded wait/safety reasons. A failed route prints the ring.
## Sampling only reads state; it never changes the route, the command or the motor.
##
## The static analysers read the same sample dictionaries, so fixtures and later runtime stall
## detection share one definition of an unexplained stop, circling and waypoint oscillation.

const SAMPLE_HZ := 10.0
const WINDOW_S := 5.0
const CAPACITY := 50
static var enabled := "--nav-trace" in preload("res://world/dev_tools.gd").user_args()
static var print_on_failure := true

var label := ""
## go_to()/command calls this navigator accepted, and planner routes it accepted.
var intent_generation := 0
var route_generation := 0
var clock := 0.0
var last_failure := ""
var _ring: Array[Dictionary] = []
var _next := 0
var _since := INF


## Advance the trace clock by one navigator step and keep a sample at SAMPLE_HZ.
func advance(nav: Node, step: float) -> void:
	clock += step
	_since += step
	if _since < 1.0 / SAMPLE_HZ: return
	_since = 0.0
	push(snapshot(nav))


func push(sample: Dictionary) -> void:
	if _ring.size() < CAPACITY:
		_ring.append(sample)
	else:
		_ring[_next] = sample
	_next = (_next + 1) % CAPACITY


## Oldest first.
func samples() -> Array[Dictionary]:
	var ordered: Array[Dictionary] = []
	if _ring.size() < CAPACITY:
		ordered.assign(_ring)
		return ordered
	for i in CAPACITY:
		ordered.append(_ring[(_next + i) % CAPACITY])
	return ordered


func failed(nav: Node, message: String) -> void:
	last_failure = message
	push(snapshot(nav))
	if print_on_failure:
		print(dump_text("route failed: " + message))


func dump_text(why: String) -> String:
	var lines := PackedStringArray()
	var ordered := samples()
	lines.append("[nav-trace] %s %s (%d samples, %.1f s window, intent %d, route %d)" % [
		label, why, ordered.size(), WINDOW_S, intent_generation, route_generation])
	for s: Dictionary in ordered:
		lines.append("[nav-trace]   " + sample_text(s))
	return "\n".join(lines)


static func sample_text(s: Dictionary) -> String:
	var at: Vector3 = s.get("pos", Vector3.ZERO)
	var contact: Vector3 = s.get("contact", Vector3.ZERO)
	return "t=%.2f i=%d r=%d wp=%d/%d prog=%.2f goal=%.2f pos=(%.2f,%.2f,%.2f) yaw=%.0f cmd=%.2f want=%.2f act=%.2f err=%.0f contact=%s look=%.2f navwant=%.2f avoid=%.2f %s '%s' wait=[%s] req=%d" % [
		float(s.get("t", 0.0)), int(s.get("intent", 0)), int(s.get("route", 0)), int(s.get("waypoint", 0)),
		int(s.get("points", 0)), float(s.get("progress", 0.0)), float(s.get("goal_distance", 0.0)),
		at.x, at.y, at.z, rad_to_deg(float(s.get("yaw", 0.0))), float(s.get("command", 0.0)),
		float(s.get("desired", 0.0)), float(s.get("speed", 0.0)), rad_to_deg(float(s.get("heading_error", 0.0))),
		"none" if contact == Vector3.ZERO else "(%.2f,%.2f,%.2f)" % [contact.x, contact.y, contact.z],
		float(s.get("lookahead", -1.0)), float(s.get("nav_desired", 0.0)), float(s.get("avoidance", 0.0)),
		str(s.get("state", "")), str(s.get("reason", "")), str(s.get("wait", "")), int(s.get("request", -1))] \
		+ (" native[%s]" % str(s.native) if s.has("native") else "")


## One sample of the navigator and its pony. Reads only; tolerant of lab stand-ins.
func snapshot(nav: Node) -> Dictionary:
	var pony: Node3D = nav.get("pony") as Node3D
	var sample := {"t": clock, "intent": intent_generation, "route": route_generation}
	if not is_instance_valid(pony): return sample
	var at := pony.global_position
	var path: PackedVector3Array = nav.get("path") if nav.get("path") is PackedVector3Array else PackedVector3Array()
	var waypoint := _int(nav, "_waypoint")
	var ground: Vector3 = _vector(pony, "_ground_velocity")
	var desired: Vector3 = _vector(pony, "_desired")
	var forward := -pony.global_basis.z
	forward.y = 0.0
	var error := 0.0
	if forward.length_squared() > 1e-6 and Vector2(desired.x, desired.z).length_squared() > 1e-6:
		error = absf(forward.signed_angle_to(Vector3(desired.x, 0.0, desired.z), Vector3.UP))
	var goal: Vector3 = _vector(nav, "_live_goal", Vector3.INF)
	if not goal.is_finite(): goal = _vector(nav, "target", Vector3.INF)
	var contact := Vector3.ZERO
	if pony is CharacterBody3D and (pony as CharacterBody3D).is_on_wall():
		contact = (pony as CharacterBody3D).get_wall_normal()
	var state: Variant = nav.get("state")
	var states: Variant = nav.get("State")
	sample.merge({
		"pos": at,
		"yaw": pony.rotation.y,
		"waypoint": waypoint,
		"points": path.size(),
		"progress": corridor_progress(path, waypoint, at),
		"goal_distance": Vector2(at.x - goal.x, at.z - goal.z).length() if goal.is_finite() else -1.0,
		"command": _float(pony, "_command_speed"),
		"desired": Vector2(desired.x, desired.z).length(),
		"speed": Vector2(ground.x, ground.z).length(),
		"velocity": Vector3(ground.x, 0.0, ground.z),
		"heading_error": error,
		"contact": contact,
		"state": (states as Dictionary).find_key(state) if states is Dictionary and state is int else str(state),
		"reason": str(nav.get("reason")),
		"wait": ",".join(wait_reasons(nav)),
		"request": _int(nav, "_request", -1),
	})
	# The navigator's own intermediate values: a zero command with no recorded reason comes from
	# its lookahead (refused corridor returns her own position), its desired velocity, or the
	# avoidance answer (reversed or silent).
	var lookahead: Vector3 = _vector(nav, "_lookahead_cache", Vector3.INF)
	sample["lookahead"] = Vector2(lookahead.x - at.x, lookahead.z - at.z).length() if lookahead.is_finite() else -1.0
	sample["nav_desired"] = _vector(nav, "_desired_velocity").length()
	sample["avoidance"] = _vector(nav, "_safe_velocity").length()
	sample["silent_avoidance"] = _float(nav, "_silent_avoidance")
	# Phase 2 native follower, when it owns her: mode, reason, escalation, corridor error, bearing.
	if nav.get("_native_active") == true and nav.has_method("native_follow_state"):
		var f: Dictionary = nav.call("native_follow_state")
		if bool(f.get("live", false)):
			sample["native"] = "m%d %s esc=%s(%s) lat=%.2f bear=%.0f v=%.2f w=%.2f k=%.2f cand=%d s=%.2f/%.2f refused g%d n%d e%d w%d b%d located=%s nb=%d" % [
				int(f.get("mode", 0)), str(f.get("reason", "")), str(f.get("escalation", "")), str(f.get("stall_cause", "")),
				float(f.get("lateral", -1.0)), rad_to_deg(float(f.get("bearing", 0.0))), float(f.get("speed", 0.0)),
				float(f.get("yaw_rate", 0.0)), float(f.get("curvature", 0.0)), int(f.get("candidates_validated", 0)),
				float(f.get("progress", 0.0)), float(f.get("length", 0.0)), int(f.get("refused_ground", 0)),
				int(f.get("refused_neighbour", 0)), int(f.get("refused_escape", 0)), int(f.get("refused_wall", 0)),
				int(f.get("refused_blocked", 0)), str(f.get("start_located", true)), int(f.get("neighbours", 0))]
	return sample


## Recorded reasons why a navigating pony may legitimately be slow or stopped this tick:
## interaction and ownership (held, touched, posture, flight), the motor's safety refusals
## (unsafe support ahead, wall-contact cooldown), the navigator's own waits and its refusal
## to step onto uncertified ground. Empty while she is simply following her route.
static func wait_reasons(nav: Node) -> PackedStringArray:
	var reasons := PackedStringArray()
	var pony: Node = nav.get("pony") as Node
	if is_instance_valid(pony):
		if pony.get("sleeping") == true: reasons.append("sleeping")
		for owner: String in ["thrown", "flight", "hoof_hold", "posture"]:
			var part: Variant = pony.get(owner)
			if part is Object and (part as Object).has_method("active") and (part as Object).call("active"):
				reasons.append(owner)
		if pony.get("motion_paused") == true: reasons.append("paused")
		if pony.get("_held") == true: reasons.append("held")
		var interaction: Variant = pony.get("_interaction")
		if interaction is String and not (interaction as String).is_empty(): reasons.append("touch:" + interaction)
		if pony.get("_blocked") == true: reasons.append("support_blocked")
		if _float(pony, "_collision_cooldown") > 0.0: reasons.append("wall_contact")
		if pony.has_method("is_on_floor") and not pony.call("is_on_floor") and int(pony.get("sim_tier") if pony.get("sim_tier") != null else 0) == 0:
			reasons.append("airborne")
	var state: Variant = nav.get("state")
	var states: Variant = nav.get("State")
	if states is Dictionary and state is int:
		var name: String = str((states as Dictionary).find_key(state))
		if name == "WAITING": reasons.append("waiting:" + str(nav.get("reason")))
		elif name != "MOVING": reasons.append("not_travelling:" + name)
	if _float(nav, "_off_mesh_time") > 0.0: reasons.append("uncertified_step_refused")
	# Phase 2 native follower: its recorded reason for a slow-down or stop (stepping_turn,
	# yielding, no_safe_arc, corridor_end, ...); empty while it simply follows.
	var native_wait: Variant = nav.get("_native_wait")
	if native_wait is String and not (native_wait as String).is_empty(): reasons.append(native_wait)
	if _int(nav, "_request", -1) >= 0 and (nav.get("path") is PackedVector3Array) and (nav.get("path") as PackedVector3Array).is_empty():
		reasons.append("route_pending")
	return reasons


## Distance travelled along `path` (horizontal) up to her projection on the current segment.
static func corridor_progress(path: PackedVector3Array, waypoint: int, at: Vector3) -> float:
	if path.size() < 2: return 0.0
	var index := clampi(waypoint, 1, path.size() - 1)
	var travelled := 0.0
	for i in range(1, index):
		travelled += Vector2(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z).length()
	var a := path[index - 1]
	var b := path[index]
	var segment := Vector2(b.x - a.x, b.z - a.z)
	var length := segment.length()
	if length < 0.0001: return travelled
	var t := clampf(Vector2(at.x - a.x, at.z - a.z).dot(segment) / (length * length), 0.0, 1.0)
	return travelled + t * length


## Contiguous runs longer than `limit` seconds where `key` (speed, m/s) stays below `threshold`
## and no sample carries a recorded reason. Only samples with from_t <= t <= to_t count:
## callers exclude startup and the arrival stretch there.
static func unexplained_stops(samples: Array, threshold := 0.05, limit := 0.25, from_t := -INF, to_t := INF, key := "speed") -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var start := NAN
	var at := Vector3.ZERO
	var last := NAN
	for s: Dictionary in samples:
		var t: float = s.get("t", 0.0)
		var counted := t >= from_t and t <= to_t
		var stalled := counted and float(s.get(key, 0.0)) < threshold and str(s.get("wait", "")).is_empty()
		if stalled:
			if is_nan(start): start = t; at = s.get("pos", Vector3.ZERO)
			last = t
			continue
		if not is_nan(start):
			var end := t if counted else last
			if end - start > limit: found.append({"from": start, "to": end, "seconds": end - start, "at": at})
			start = NAN
	if not is_nan(start) and last - start > limit:
		found.append({"from": start, "to": last, "seconds": last - start, "at": at})
	return found


## Windows of at most `window` seconds in which her heading sweeps a full turn while the distance
## to her goal shrinks by less than `min_progress`: circling, or spinning on the spot.
static func circling(samples: Array, window := 8.0, min_progress := 0.5) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var sweep: Array[float] = [0.0]
	for i in range(1, samples.size()):
		var turned := absf(angle_difference(float(samples[i - 1].get("yaw", 0.0)), float(samples[i].get("yaw", 0.0))))
		sweep.append(sweep[i - 1] + turned)
	var first := 0
	var skip_until := -INF
	for i in samples.size():
		var t: float = samples[i].get("t", 0.0)
		while first < i and t - float(samples[first].get("t", 0.0)) > window: first += 1
		if t < skip_until: continue
		var turned := sweep[i] - sweep[first]
		if turned < TAU: continue
		var best := INF
		for j in range(first, i + 1): best = minf(best, float(samples[j].get("goal_distance", 0.0)))
		var gained := float(samples[first].get("goal_distance", 0.0)) - best
		if gained < min_progress:
			found.append({"from": samples[first].t, "to": t, "sweep_deg": rad_to_deg(turned), "gained": gained, "at": samples[i].get("pos", Vector3.ZERO)})
			skip_until = t + window
	return found


## Waypoint oscillation: within one route generation the waypoint index goes back, or corridor
## progress reverses direction by more than `amplitude` at least `reversals` times in `window` s.
static func oscillation(samples: Array, window := 5.0, amplitude := 0.15, reversals := 3) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var flips: Array[float] = []
	var route := -1
	var waypoint := -1
	var extreme := 0.0
	var trend := 0
	for s: Dictionary in samples:
		var t: float = s.get("t", 0.0)
		var progress: float = s.get("progress", 0.0)
		if int(s.get("route", 0)) != route:
			route = int(s.get("route", 0)); waypoint = int(s.get("waypoint", 0))
			extreme = progress; trend = 0; flips.clear()
			continue
		if int(s.get("waypoint", 0)) < waypoint:
			found.append({"kind": "waypoint_back", "t": t, "from": waypoint, "to": int(s.get("waypoint", 0)), "at": s.get("pos", Vector3.ZERO)})
		waypoint = int(s.get("waypoint", 0))
		if trend >= 0 and progress > extreme: extreme = progress; trend = 1
		elif trend <= 0 and progress < extreme: extreme = progress; trend = -1
		elif absf(progress - extreme) > amplitude:
			trend = -trend if trend != 0 else (1 if progress > extreme else -1)
			extreme = progress
			flips.append(t)
			while not flips.is_empty() and t - flips[0] > window: flips.pop_front()
			if flips.size() >= reversals:
				found.append({"kind": "progress_reversals", "t": t, "count": flips.size(), "at": s.get("pos", Vector3.ZERO)})
				flips.clear()
	return found


## The analysers on synthetic traces with a known answer. Empty when every case is judged
## correctly; fixtures run it so a green result also proves the checks can fail.
static func self_test() -> PackedStringArray:
	var problems := PackedStringArray()
	var stop: Array = []
	for i in 60:
		var t := i / 30.0
		var moving := t < 0.7 or t > 1.3
		stop.append({"t": t, "speed": 0.4 if moving else 0.0, "wait": "", "yaw": 0.0, "progress": t, "route": 1, "waypoint": i, "goal_distance": 10.0 - t, "pos": Vector3.ZERO})
	if unexplained_stops(stop).size() != 1: problems.append("a 0.6 s stop without a reason is not flagged")
	var excused: Array = stop.map(func(s: Dictionary) -> Dictionary: return s.merged({"wait": "" if float(s.speed) > 0.0 else "wall_contact"}, true))
	if not unexplained_stops(excused).is_empty(): problems.append("a stop with a recorded wall contact is flagged")
	if not unexplained_stops(stop, 0.05, 0.25, 1.5).is_empty(): problems.append("a stop inside the excluded startup is flagged")
	var short: Array = stop.map(func(s: Dictionary) -> Dictionary: return s.merged({"speed": 0.4 if float(s.t) < 0.9 or float(s.t) > 1.1 else 0.0}, true))
	if not unexplained_stops(short).is_empty(): problems.append("a 0.2 s dip is flagged")
	var circle: Array = []
	for i in 300:
		var t := i / 30.0
		circle.append({"t": t, "yaw": wrapf(t * 1.2, -PI, PI), "goal_distance": 8.0 + 0.3 * sin(t * 1.2), "pos": Vector3.ZERO, "progress": t, "route": 1, "waypoint": 3})
	if circling(circle).is_empty(): problems.append("circling at 1.2 rad/s without progress is not flagged")
	var straight: Array = circle.map(func(s: Dictionary) -> Dictionary: return s.merged({"yaw": 0.3, "goal_distance": 10.0 - float(s.t)}, true))
	if not circling(straight).is_empty(): problems.append("a straight walk is flagged as circling")
	var bounce: Array = []
	for i in 150:
		var t := i / 30.0
		bounce.append({"t": t, "progress": 2.0 + 0.4 * sin(t * 5.0), "route": 1, "waypoint": 4, "pos": Vector3.ZERO})
	if oscillation(bounce).is_empty(): problems.append("progress bouncing across a waypoint is not flagged")
	var back: Array = straight.duplicate(true)
	back[100]["waypoint"] = 2
	if oscillation(back).is_empty(): problems.append("a waypoint index going back on the same route is not flagged")
	if not oscillation(straight).is_empty(): problems.append("steady progress is flagged as oscillation")
	return problems


static func _float(owner: Object, property: String, fallback := 0.0) -> float:
	var value: Variant = owner.get(property)
	return float(value) if value is float or value is int else fallback


static func _int(owner: Object, property: String, fallback := 0) -> int:
	var value: Variant = owner.get(property)
	return int(value) if value is int or value is float else fallback


static func _vector(owner: Object, property: String, fallback := Vector3.ZERO) -> Vector3:
	var value: Variant = owner.get(property)
	return value if value is Vector3 else fallback
