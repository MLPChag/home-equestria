extends RefCounted
## Coordinated footfalls for three gaits. Walk and trot share the imported trot clip
## (per-leg clocks, folded walking swings); the gallop is the native clip on one clock.
## Travel speed and clip cadence are separate: playback stays inside the profile's
## cadence range and the remaining ground per stance comes from stride extension.

# FL, RR, FR, RL: a lateral-sequence walk, with four distinct footfalls.
const WALK_ORDER := [0, 3, 1, 2]
const GAITS := ["walk", "trot", "gallop"]

var excluded_leg:=-1
var phases := PackedFloat64Array()
var _profile: Resource
var _published_phase := 0.0
var walking := false
## Backing up (pony_locomotion.gd back_up): the gait clock runs backwards, so the walk plays in
## reverse. Every pose is still an authored, in-range pose; only their order is reversed.
var reversed := false
var walk_blend := 0.0
## Active gait for cadence and new contacts: "walk", "trot" or "gallop".
var gait := "trot"
## 0..1 pose weight of the gallop clip; blends over profile.gait_blend_seconds.
var gallop_blend := 0.0
## Single shared clock of the gallop clip (phases[] carry the trot/walk clocks).
var gallop_phase := 0.0
## Current cadence multiplier of the active clip (1 = authored tempo).
var playback := 1.0
## Per-leg gallop pose weight. A planted hoof keeps the pose mix it landed with until
## lift-off (its contact follows that mix); airborne legs catch the body blend up.
var leg_blend := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
var _leg_held := [false, false, false, false]
## Review tools pin a gait ("" = automatic).
var forced_gait := ""
var _recovering_trot := false
var _time := 0.0
var _next_walk := 0
var _next_landing := 0.0
var _walk_launches := 0
var _stride_lengths := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
var _gait_hold := 0.0
## Contact model each leg follows; a planted hoof keeps the outgoing gait's window
## until its own lift-off, so a gait change never yanks a loaded contact.
var _owner: Array[String] = ["trot", "trot", "trot", "trot"]
var _owner_since := 0.0
var _switches := 0
var _switch_time := -INF
## Stride-offset discontinuity left by a contact-model change, decayed to zero so a
## hoof target never jumps when its leg adopts the new gait's window.
var _stride_shift := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])


func bind(profile: Resource) -> void:
	_profile = profile
	reset()


func reset(phase: float = 0.0) -> void:
	phases.resize(4)
	phases.fill(phase)
	_published_phase = phase
	walking = false
	walk_blend = 0.0
	gait = "trot"
	gallop_blend = 0.0
	gallop_phase = phase
	playback = 1.0
	leg_blend.fill(0.0)
	_leg_held = [false, false, false, false]
	_recovering_trot = false
	_time = 0.0
	_next_walk = 0
	_next_landing = 0.0
	_walk_launches = 0
	_stride_lengths.fill(0.0)
	_gait_hold = 0.0
	_owner = ["trot", "trot", "trot", "trot"]
	_owner_since = 0.0
	_stride_shift.fill(0.0)


func gait_switches() -> int:
	return _switches


## Seconds since the last gait change (INF before any).
func seconds_since_switch() -> float:
	return _time - _switch_time


## Contact model this leg currently follows.
func contact_gait(i: int) -> String:
	return _owner[i]


func leg_phase(i: int) -> float:
	return gallop_phase if _owner[i] == "gallop" else phases[i]


## 0..1 progress through the owning gait's cycle measured from contact start.
func leg_progress(i: int) -> float:
	var leg: Dictionary = _profile.gait_leg(_owner[i], i)
	return fposmod(leg_phase(i) - float(leg.contact_start), 1.0)


func leg_airborne(i: int) -> bool:
	return leg_progress(i) >= float(_profile.gait_leg(_owner[i], i).contact_span)


## Contact weight of the pose this leg actually shows: the trot/walk window and the
## gallop window mixed by the leg's own pose blend.
func leg_contact_weight(i: int) -> float:
	var trot_weight: float = _profile.step_contact_weight(_profile.gait_leg("trot", i), phases[i])
	if leg_blend[i] <= 0.0:
		return trot_weight
	var gallop_weight: float = _profile.step_contact_weight(_profile.gait_leg("gallop", i), gallop_phase)
	return lerpf(trot_weight, gallop_weight, leg_blend[i])


## Seconds until the owning gait's clip lands this leg at the current cadence.
func touchdown_seconds(i: int) -> float:
	var cycle: float = _profile.gait_cycle(_owner[i])
	var rate := _gait_playback(_owner[i])
	return (1.0 - leg_progress(i)) * cycle / maxf(rate, 0.05)


func _gait_playback(name: String) -> float:
	if name == "gallop": return _gallop_playback
	if name == "walk": return maxf(_walk_swing_rate, 0.05)
	return _trot_playback

var _trot_playback := 1.0
var _gallop_playback := 1.0
var _walk_swing_rate := 1.0
var _speed := 0.0


func advance(delta: float, speed: float, phase: float, feet: Array[Dictionary] = [],
		backward: Vector3 = Vector3.BACK, requested_speed: float = -1.0) -> float:
	# The review tools can explicitly seek a phase. Normal integration never
	# seeks a leg when speed changes, so an airborne hoof cannot jump backward.
	if absf(wrapf(phase - _published_phase, -0.5, 0.5)) > 0.0001:
		reset(phase)
	var requested := speed if requested_speed < 0.0 else requested_speed
	_speed = speed
	_select_gait(delta, speed, requested, feet)
	var range: Vector2 = _profile.cadence_range
	_trot_playback = clampf(speed / _profile.gait_natural_speed("trot"), range.x, range.y)
	_gallop_playback = clampf(speed / _profile.gait_natural_speed("gallop"), range.x, range.y)
	# Walking swings quicken with speed so a brisk walk keeps two hooves loaded.
	var walk_swing: Vector2 = _profile.walk_swing_speed
	_walk_swing_rate = clampf(1.0 + (speed - walk_swing.x) / maxf(walk_swing.y - walk_swing.x, 0.01) * (range.y - 1.0), 1.0, range.y)
	var ratio := _trot_playback
	walk_blend = move_toward(walk_blend, 1.0 if walking else 0.0, delta / 0.4)
	gallop_blend = move_toward(gallop_blend, 1.0 if gait == "gallop" else 0.0, delta / _profile.gait_blend_seconds)
	for i in 4:
		var planted: bool = feet.size() == 4 and bool(feet[i].planted)
		if planted and _leg_held[i]:
			continue
		_leg_held[i] = planted
		if not planted:
			leg_blend[i] = move_toward(leg_blend[i], gallop_blend, delta / 0.1)
	playback = _gait_playback(gait)
	for i in 4:
		var owner := _owner[i]
		var leg: Dictionary = _profile.gait_leg(owner, i)
		var support: float
		if owner == "walk":
			support = _walk_beat(speed) * 4.0 - _swing_seconds(i)
		else:
			support = float(leg.contact_span) * _profile.gait_cycle(owner) / _gait_playback(owner)
		var cap: float = _profile.stride_extension.get(owner, 0.12)
		var extra := clampf(speed * support - float(leg.stance_travel) * _profile.body_scale, -cap, cap)
		_stride_lengths[i] = lerpf(_stride_lengths[i], extra, 1.0 - exp(-delta / 0.12))
	for i in 4:
		_stride_shift[i] *= exp(-delta / 0.1)
	var steps := maxi(1, ceili(delta * 120.0))
	var dt := delta / steps
	# Outside a walk every leg runs at the clip's playback, swing included; a
	# recovering trot regains its diagonal timing through grounded rate coupling.
	var swing_rate := ratio if not walking else _walk_swing_rate
	for step in steps:
		gallop_phase = fposmod(gallop_phase + _gallop_playback * dt / _profile.gait_cycle("gallop"), 1.0)
		if excluded_leg>=0 and WALK_ORDER[_next_walk]==excluded_leg:_next_walk=(_next_walk+1)%4
		var master := phases[0]
		if reversed:
			# One clock for every leg, run backwards at the clip's playback: each hoof lifts at the
			# front of its stance and lands behind, which walks the body backwards. No landing
			# coordination or diagonal coupling: those schedule forward travel.
			var back_step: float = (swing_rate if walking else ratio) * dt / _profile.CYCLE
			for i in 4:
				if i == excluded_leg: continue
				phases[i] = fposmod(phases[i] - back_step, 1.0)
			_time += dt
			continue
		if not walking and not _recovering_trot:
			# A trot is one shared clock. Per-leg clocks that stretched only the
			# stance let a rear hoof swing at authored tempo while its same-side
			# front hoof was still slowly loaded: at 60% pace the rear landed
			# on the front's lift-off spot (0.5 cm apart, authored 13.5 cm), and
			# a standing start launched both hind legs together. Slowing the
			# whole cycle keeps every authored inter-leg relationship intact.
			var shared: float = ratio * dt / _profile.CYCLE
			for i in 4:
				# Absorb whatever separation a walk-to-trot recovery left.
				var error := wrapf(master - phases[i], -0.5, 0.5) if i > 0 else 0.0
				phases[i] = fposmod(phases[i] + shared + error * minf(1.0, dt / 0.2), 1.0)
			_time += dt
			continue
		var swinging := 0
		for i in 4:
			if i==excluded_leg:continue
			var leg: Dictionary = _profile.legs[i]
			if fposmod(phases[i] - float(leg.contact_start), 1.0) >= float(leg.contact_span):
				swinging += 1
		for i in 4:
			if i==excluded_leg:continue
			var leg: Dictionary = _profile.legs[i]
			var progress := fposmod(phases[i] - float(leg.contact_start), 1.0)
			var stance: float = leg.contact_span
			var airborne := progress >= stance
			var rate := swing_rate if airborne else ratio
			if not airborne and walking:
				# Coordinate the next landing, accounting for each source leg's
				# different swing duration. Alter support time, never seek a pose.
				var order := (WALK_ORDER.find(i) - _next_walk + 4) % 4
				var lift_at := _next_landing + order * _walk_beat(speed) - _swing_seconds(i)
				rate = minf(1.25, (stance - progress) * _profile.CYCLE / maxf(lift_at - _time, dt))
			if not airborne and not walking and i > 0:
				# Regain the original diagonal trot through grounded motion only.
				var error := wrapf(master - phases[i], -0.5, 0.5)
				var coupling := 4.0 * smoothstep(0.75, 1.0, ratio) if not _recovering_trot else 8.0
				rate *= clampf(1.0 + error * coupling, 0.5, 1.5)
			if not airborne and not walking and feet.size() == 4 and feet[i].planted and _owner[i] != "gallop":
				# Keep the source stance under its world contact as the torso
				# tilts. If the hoof has swept back too early, wait for the body;
				# if the body is ahead, finish support sooner. Never seek a pose.
				var offset: Vector3 = feet[i].offset
				rate = clampf(rate + offset.dot(backward) * 8.0, rate * 0.8, rate * 1.2)
			var advance: float = rate * dt / _profile.CYCLE
			# Finish a stance interval exactly, then use the remaining time at
			# swing tempo. A slow stance rate must not leak into the hoof lift.
			if not airborne and progress + advance >= stance - 0.0000001:
				# Slow steps wait for support instead of allowing three or four
				# simultaneous lifts. Swinging feet still finish at their own pace.
				if walking and (i != WALK_ORDER[_next_walk] or (swinging >= (1 if excluded_leg>=0 else 2) and (_walk_launches>=4 or excluded_leg>=0))
						or _time + dt < _next_landing - _swing_seconds(i)):
					phases[i] = fposmod(float(leg.contact_start) + stance - 0.000001, 1.0)
					continue
				swinging += 1
				var remainder: float = maxf(0.0, dt - (stance - progress) * _profile.CYCLE / maxf(rate, 0.00001))
				if walking:
					# If support delayed a lift, move the remaining sequence with
					# it. Never catch up by launching several hooves together.
					_next_walk = (_next_walk + 1) % 4
					_walk_launches += 1
					_next_landing = _time + dt - remainder + _swing_seconds(i) + _walk_beat(speed)
				advance = stance - progress + remainder * swing_rate / _profile.CYCLE
			elif airborne and progress + advance > 1.0:
				swinging -= 1
				var remainder: float = dt - (1.0 - progress) * _profile.CYCLE / maxf(rate, 0.00001)
				advance = 1.0 - progress + remainder * ratio / _profile.CYCLE
			phases[i] = fposmod(phases[i] + advance, 1.0)
		_time += dt
	_published_phase = phases[0]
	if _recovering_trot:
		var separation := 0.0
		for i in range(1, 4):
			separation = maxf(separation, absf(wrapf(phases[i] - phases[0], -0.5, 0.5)))
		if separation < 0.025:
			_recovering_trot = false
	_release_owners(delta, feet)
	return _published_phase


## Requested speed picks the gait with separate entry/exit thresholds and a minimum
## hold; the actual speed must be near the band too, so a blocked or braking pony
## never gallops on the spot.
func _select_gait(delta: float, speed: float, requested: float, feet: Array[Dictionary]) -> void:
	_gait_hold = maxf(0.0, _gait_hold - delta)
	var wanted := gait
	if not forced_gait.is_empty():
		wanted = forced_gait
	elif gait == "gallop":
		if requested < _profile.gallop_exit or speed < _profile.gallop_exit - 0.8:
			wanted = "trot"
	elif gait == "trot":
		if requested >= _profile.gallop_entry and speed >= _profile.gallop_entry - 0.8:
			wanted = "gallop"
		elif requested > 0.0 and requested < _profile.trot_exit and speed < _profile.trot_entry:
			wanted = "walk"
	else:
		if requested >= _profile.gallop_entry and speed >= _profile.gallop_entry - 0.8:
			wanted = "gallop"
		elif requested >= _profile.trot_entry:
			wanted = "trot"
	if wanted == gait or (_gait_hold > 0.0 and forced_gait.is_empty()):
		return
	_switch_gait(wanted, feet)


func _switch_gait(wanted: String, feet: Array[Dictionary]) -> void:
	var previous := gait
	gait = wanted
	_gait_hold = _profile.gait_hold_seconds
	_switches += 1
	_switch_time = _time
	if wanted == "walk":
		_begin_walk(feet)
	elif previous == "walk":
		walking = false
		_recovering_trot = true
	if wanted == "gallop":
		gallop_phase = _matching_phase("gallop", previous)
	elif previous == "gallop":
		# The trot clocks were idling on one clock; seat them where the
		# gallop's supports are so loaded hooves stay loaded.
		var seat := _matching_phase("trot", "gallop")
		phases.fill(seat)
		_recovering_trot = false
		walking = false
		if wanted == "walk":
			_begin_walk(feet)
	# Legs loaded under the outgoing gait keep its window until lift-off.
	for i in 4:
		var loaded: bool = _profile.step_contact_weight(_profile.gait_leg(_owner[i], i), leg_phase(i)) >= 0.7
		if not loaded or (_owner[i] != "gallop" and wanted != "gallop"):
			_adopt(i, wanted)
	_owner_since = _time


func _adopt(i: int, owner: String) -> void:
	if _owner[i] == owner:
		return
	var before := stride_offset(i, _speed)
	_owner[i] = owner
	_stride_shift[i] = 0.0
	_stride_shift[i] = before - stride_offset(i, _speed)


## Phase of `target`'s clip whose per-leg contact weights best match the current
## contact state of the `source` gait, so a switch releases and lands hooves in order.
func _matching_phase(target: String, source: String) -> float:
	var current := PackedFloat32Array()
	for i in 4:
		var source_phase := gallop_phase if source == "gallop" else phases[i]
		current.append(_profile.step_contact_weight(_profile.gait_leg(source, i), source_phase))
	var best := 0.0
	var best_error := INF
	for step in 256:
		var candidate := float(step) / 256.0
		var error := 0.0
		for i in 4:
			error += absf(_profile.step_contact_weight(_profile.gait_leg(target, i), candidate) - current[i])
		if error < best_error:
			best_error = error
			best = candidate
	return best


func _release_owners(delta: float, feet: Array[Dictionary]) -> void:
	var active := gait
	var overdue: bool = _time - _owner_since > _profile.gait_blend_seconds * 2.0
	for i in 4:
		if _owner[i] == active:
			continue
		var weight: float = _profile.step_contact_weight(_profile.gait_leg(_owner[i], i), leg_phase(i))
		var reach_lost := feet.size() == 4 and bool(feet[i].get("limited", false))
		if weight < 0.7 or overdue or reach_lost:
			_adopt(i, active)


func _swing_seconds(i: int) -> float:
	return (1.0 - float(_profile.legs[i].contact_span)) * _profile.CYCLE / maxf(_walk_swing_rate, 0.05)


func stride_offset(i: int, _speed: float) -> float:
	var owner := _owner[i]
	var leg: Dictionary = _profile.gait_leg(owner, i)
	var extra := _stride_lengths[i]
	var progress := fposmod(leg_phase(i) - float(leg.contact_start), 1.0)
	if progress < float(leg.contact_span):
		return extra * (progress / float(leg.contact_span) - 0.5) + _stride_shift[i]
	var swing := (progress - float(leg.contact_span)) / (1.0 - float(leg.contact_span))
	# Longer support needs a slightly longer step. Distribute that reach
	# before and behind the shoulder/hip instead of stopping the torso.
	return extra * 0.5 * cos(PI * swing) + _stride_shift[i]


## Four beats per stride. The period follows the requested speed so each stance
## sweeps the hoof no further than the profile's walking reach, while at least two
## hooves stay loaded; quick steps come from a shorter period, never a longer sweep.
func _walk_beat(speed: float) -> float:
	var reach: float = _profile.walk_stance_sweep(speed)
	var slowest: float = _profile.walk_period_max
	var swing := 0.0
	var longest := 0.0
	for i in 4:
		longest = maxf(longest, _swing_seconds(i))
	swing = _swing_seconds(0)
	# At most two hooves swing at once, so no period can be shorter than two of the
	# longest swings; that floor, not the sweep, bounds the walking speed.
	var period := clampf(swing + reach / maxf(speed, 0.05), maxf(longest * 2.0, _profile.walk_period_min), slowest)
	var target := period / 4.0
	# Finish the old support contacts promptly, then open out the walking
	# spacing over the first four lifts. Existing airborne arcs never rush.
	return lerpf(0.18, target, smoothstep(0.0, 4.0, _walk_launches))


func _begin_walk(feet: Array[Dictionary] = []) -> void:
	walking = true
	_recovering_trot = false
	_walk_launches = 0
	var soonest := INF
	var oldest := -1.0
	for i in 4:
		var leg: Dictionary = _profile.legs[i]
		var progress := fposmod(phases[i] - float(leg.contact_start), 1.0)
		# A trot may be in suspension at entry. Select the earliest upcoming
		# support expiry then too; defaulting to FL strands the other pair.
		var remaining := fposmod(float(leg.contact_span) - progress, 1.0)
		if remaining < soonest:
			soonest = remaining
			_next_walk = WALK_ORDER.find(i)
	if feet.size() == 4:
		for i in 4:
			if feet[i].planted and feet[i].valid and float(feet[i].age) > oldest:
				oldest = feet[i].age
				_next_walk = WALK_ORDER.find(i)
	# Existing airborne feet finish normally before the walking sequence.
	_next_landing = _time + _swing_seconds(WALK_ORDER[_next_walk]) + 0.03


func start_walk(speed: float) -> float:
	# Seed the four-beat pose while still blending from standing. Starting
	# every leg at trot phase zero leaves one old support waiting a cycle.
	walking = true
	gait = "walk"
	_gait_hold = _profile.gait_hold_seconds
	_recovering_trot = false
	_walk_launches = 4
	_owner = ["walk", "walk", "walk", "walk"]
	_stride_shift.fill(0.0)
	var beat := _walk_beat(speed)
	var period := beat * 4.0
	var first_lift := INF
	for order in 4:
		var i: int = WALK_ORDER[order]
		var leg: Dictionary = _profile.legs[i]
		var support := period - _swing_seconds(i)
		var elapsed := fposmod(-order * beat, period)
		var progress: float = elapsed / support * float(leg.contact_span)
		if elapsed >= support:
			progress = float(leg.contact_span) + (elapsed - support) / _profile.CYCLE
		phases[i] = fposmod(float(leg.contact_start) + progress, 1.0)
		var until_lift := fposmod(support - elapsed, period)
		if until_lift < first_lift:
			first_lift = until_lift
			_next_walk = order
	_next_landing = _time + first_lift + _swing_seconds(WALK_ORDER[_next_walk])
	_published_phase = phases[0]
	return _published_phase
