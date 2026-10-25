extends RefCounted
## GDScript route following of pony_navigator.gd (split 2026-10-13). Native following is the
## default on every shipping platform; this steering runs only with --native-navigation off (the
## comparison) or for a pony the native follower could not register. State stays on the
## navigator (traces and house travel read it there); calls back go through `nav.`.

static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## The legacy end of a navigator tick: waypoints, journey legs, arrival, braking, turns,
## avoidance, the clearance check of the next step and stuck recovery.
static func steer(nav: Node, delta: float) -> void:
	var pony: CharacterBody3D = nav.pony
	var service: WalkGridService = nav._service
	var profile: Variant = pony.profile
	var path: PackedVector3Array = nav.path
	# The nav surface approximates terrain height. Progress is measured in
	# XZ; collision/ground rays own Y. Keep a vertical guard for stacked floors.
	var waypoint: int = nav._waypoint
	while waypoint < path.size() - 1:
		var close := _flat(pony.global_position, path[waypoint]) < 0.22
		var previous := path[waypoint - 1] if waypoint > 0 else path[0] - (path[1] - path[0])
		var passed: bool = nav.passed_waypoint(pony.global_position, previous, path[waypoint])
		if not close and not passed: break
		if not close and not service.steering_segment_clear(pony.global_position, path[waypoint + 1], profile): break
		waypoint += 1
	nav._waypoint = waypoint
	var arrival: float = nav.arrival_distance
	# Long trips plan the next leg while this one is still being walked.
	var journey: Vector3 = nav._journey_goal
	var leg_length: float = nav.JOURNEY_LEG
	if journey.is_finite() and nav._request < 0 and not nav._needs_path and _flat(pony.global_position, nav.target) < 25.0:
		if not Array(nav._journey_via).is_empty() or _flat(pony.global_position, journey) > leg_length * 1.2 or _flat(nav.target, journey) > 1.0:
			nav._journey_attempt = 0
			nav._next_leg()
			# An approach already being followed keeps its route. Continue steering it;
			# skipping this tick leaves the old velocity running past the bridge.
			if nav._needs_path: return
			path = nav.path
	var moving_goal: bool = nav._moving_goal
	var target_speed: float = nav.command_target_speed
	var target: Vector3 = nav.target
	if not nav.house_travel.active() and not (moving_goal and target_speed > .3) and _flat(pony.global_position, target) <= arrival and absf(pony.global_position.y - target.y) < nav.target_snap_distance:
		nav._has_target = false
		nav._journey_goal = Vector3.INF
		nav._journey_via = []
		nav._approaching_player = false
		nav.state = nav.State.ARRIVED
		nav.reason = "Arrived"
		if nav._wandering:
			nav._begin_rest()
		nav.arrived.emit()
		nav._halt()
		return
	var next: Vector3 = nav._cached_lookahead(delta)
	var offset := next - pony.global_position
	offset.y = 0.0
	# Brake for the end of the route actually available, not a farther target
	# whose extension is still being sampled on a worker.
	# A moving goal is braked for the live slot, not for a route end that was the
	# slot a moment ago; the route is the corridor, the slot is the destination.
	var live_goal: Vector3 = nav._live_goal
	var remaining := _flat(pony.global_position, live_goal if moving_goal and live_goal.is_finite() else path[-1])
	var cruising: float = nav.pace
	var speed_limit: float = nav.command_speed_limit
	if is_finite(speed_limit): cruising = minf(speed_limit, profile.max_travel_speed)
	var tracking: float = nav._tracking_speed
	if tracking >= 0.0: cruising = minf(cruising, tracking)
	# Stopping distance at the controller's braking rate. A goal that is itself moving
	# (following) is never braked below the target's measured speed, so the formation
	# error closes instead of sawtoothing between sprint and stop.
	var brake := sqrt(2.0 * profile.braking * maxf(0.0, remaining - arrival * 0.5))
	var target_moving := moving_goal and target_speed > 0.3
	# Braking distance is relative to a moving slot: the target's own speed plus the
	# stopping curve for the remaining gap, so she closes instead of trailing.
	if target_moving: brake += target_speed
	var speed := minf(cruising, brake)
	# Fixed destinations end at a walk: greetings and arrivals are never collisions.
	if not target_moving and remaining < nav.approach_distance:
		speed = minf(speed, profile.walk_speed.y)
	# Sharp turns slow her down; avoidance and unsafe ground stay with the controller.
	var heading := -pony.global_basis.z; heading.y = 0.0
	if heading.length_squared() > 1e-6 and offset.length_squared() > 1e-6:
		var turn := heading.angle_to(offset)
		speed = minf(speed, lerpf(cruising, profile.walk_speed.y, smoothstep(deg_to_rad(35.0), deg_to_rad(90.0), turn)))
	speed = minf(speed, speed_limit)
	var desired := offset.normalized() * speed
	nav._desired_velocity = desired
	nav.agent.velocity = desired
	# Avoidance is velocity steering, never authority to leave the navmesh.
	var safe: Vector3 = nav._safe_velocity
	var command := safe
	if command.dot(desired) < 0.0:
		command = Vector3.ZERO
	# Avoidance answers a frame late and may stay silent; a silent avoider
	# must not park her (dev, round 5: "5 minutes and she hasn't moved").
	if safe.length() < 0.01 and desired.length() > 0.01:
		nav._silent_avoidance += delta
		if nav._silent_avoidance > 0.3:
			command = desired
	else:
		nav._silent_avoidance = 0.0
	# Check only as far as the certified lookahead. The next route sample may be
	# centimetres away: clamping height to that sample while predicting metres ahead
	# falsely puts the probe below an uphill road (or above a downhill one).
	var advance := minf(command.length() * 0.3, offset.length())
	var predicted := pony.global_position + command.normalized() * advance
	predicted.y = lerpf(pony.global_position.y, next.y, advance / maxf(offset.length(), .001))
	if not service.steering_segment_clear(pony.global_position, predicted, profile):
		# Unknown/unsafe ground is a stop, never permission to leave the corridor. The one
		# exception is pursuit of a moving leader over ground the grid has not measured
		# yet: nothing known refuses it, the physical probes still do, and she walks.
		if nav._unknown_pursuit and moving_goal and service.has_method("segment_unknown_or_clear") \
				and service.segment_unknown_or_clear(pony.global_position, predicted, profile, nav.autonomous_command()):
			command = command.limit_length(profile.walk_speed.y)
			nav._off_mesh_time = 0.0
		else:
			command = Vector3.ZERO
			nav._off_mesh_time += delta
	else:
		nav._off_mesh_time = 0.0
	pony.set_desired_velocity(command)
	nav.state = nav.State.MOVING
	nav.reason = "Following route"
	if pony.global_position.distance_to(nav._progress_position) >= 0.2:
		nav._progress_position = pony.global_position
		nav._stuck_time = 0.0
		nav._retries = 0
	elif nav._request < 0:
		# Waiting for a route is planning, not being stuck: counting it cancelled the
		# very request being built every nine seconds and left followers standing.
		nav._stuck_time += delta
	if nav._stuck_time >= nav.stuck_timeout:
		nav._stuck_time = 0.0
		nav._retries += 1
		var retries: int = nav._retries
		if nav._wandering and retries <= 2:
			# Replanning the same corridor walks into the same prop. A wanderer
			# has no stake in that spot: go somewhere else instead.
			nav._has_target = false
			nav._approaching_player = false
			nav.path = PackedVector3Array()
			nav._idle_time = randf_range(8.0, 16.0)
			nav.state = nav.State.IDLE
			nav.reason = "Blocked; picking another destination"
			nav._halt()
			return
		# Stuck on the way to a bridge approach (its ramp rail caught Twilight in river_trips.gd,
		# 2026-09-30): that point was only staging; head over the bridge to the far side.
		var via: Array = nav._journey_via
		if not via.is_empty() and _flat(pony.global_position, via[0]) < 25.0:
			via.pop_front(); nav._retries = 0
			nav._next_leg()
			return
		if retries <= 2:
			nav._needs_path = true
		else:
			nav._fail("Blocked after two replans", nav.State.BLOCKED)


static func recover_cramped_start(nav: Node, delta: float) -> bool:
	var pony: CharacterBody3D = nav.pony
	var service: WalkGridService = nav._service
	if service.is_walkable(pony.global_position, pony.profile):
		nav._escape_goal = Vector3.INF
		return false
	nav._escape_timer -= delta
	if nav._escape_timer <= 0.0:
		nav._escape_timer = .5
		nav._escape_goal = service.escape_point(pony.global_position, pony.profile)
	var goal: Vector3 = nav._escape_goal
	if not goal.is_finite(): return false
	var motion := goal - pony.global_position
	# A small lift excludes resting floor contact from the body sweep, not walls.
	var frame := pony.global_transform; frame.origin.y += .02
	motion.y = maxf(0.0, motion.y)
	if pony.test_move(frame, motion): return false
	motion.y = 0.0
	var desired: Vector3 = motion.normalized() * pony.profile.walk_speed.y
	nav._desired_velocity = desired
	nav.agent.velocity = desired
	pony.set_desired_velocity(desired)
	nav.state = nav.State.MOVING; nav.reason = "Stepping away from obstruction"
	nav._stuck_time = 0.0
	nav._reset_lookahead()
	return true


static func lookahead_point(nav: Node, position: Vector3, distance: float) -> Vector3:
	nav._tracking_speed = -1.0
	var path: PackedVector3Array = nav.path
	if path.is_empty(): return position
	var pony: CharacterBody3D = nav.pony
	var service: WalkGridService = nav._service
	var moving_goal: bool = nav._moving_goal
	var live_goal: Vector3 = nav._live_goal
	var target_velocity: Vector3 = nav.command_target_velocity
	# Close formation matches the leader's velocity plus a small position correction.
	# Chasing successive stationary samples made her brake/turn back every 0.2 s.
	# This steering is allowed only along a certified short corridor; obstacles still
	# require the planned route. It also leaves moving head turns out of the gait.
	if moving_goal and target_velocity.length() > .3 and _flat(position, live_goal) < 3.0:
		var error := live_goal - position; error.y = 0.0
		var velocity: Vector3 = target_velocity + error * nav.follow_gain
		var candidate := position + velocity.limit_length(distance)
		candidate.y = lerpf(position.y, live_goal.y, _flat(position, candidate) / maxf(error.length(), .5))
		var support := service.closest(candidate, pony.profile, .8)
		if support.is_finite():
			candidate.y = support.y
			var trails: bool = nav.autonomous_command()
			var on_road := not trails or service.trail_weight_at(position) < .5 or service.trail_weight_at(candidate) >= .35
			if on_road and service.steering_segment_clear(position, candidate, pony.profile, trails):
				nav._tracking_speed = velocity.length()
				return candidate
	if nav._unknown_pursuit and moving_goal:
		var length := _flat(position, path[-1])
		var candidate := position.lerp(path[-1], minf(distance / maxf(length, .001), 1.0))
		if service.segment_unknown_or_clear(position, candidate, pony.profile, nav.autonomous_command()): return candidate
	var cursor := position; var remaining := distance; var best := position
	for i in range(nav._waypoint, path.size()):
		var candidate: Vector3 = path[i]
		var segment := candidate - cursor
		var horizontal_length := Vector2(segment.x, segment.z).length()
		if horizontal_length >= remaining:
			candidate = cursor.lerp(candidate, remaining / maxf(horizontal_length, 0.0001))
			return candidate if service.steering_segment_clear(position, candidate, pony.profile, true) else best
		if not service.steering_segment_clear(position, candidate, pony.profile, true): return best
		best = candidate
		remaining -= horizontal_length; cursor = candidate
	return best


static func cached_lookahead(nav: Node, delta: float) -> Vector3:
	nav._lookahead_timer -= delta
	var cache: Vector3 = nav._lookahead_cache
	var waypoint: int = nav._waypoint
	if not cache.is_finite() or nav._lookahead_timer <= 0.0 or nav._lookahead_waypoint != waypoint:
		var pony: CharacterBody3D = nav.pony
		cache = nav._lookahead_point(pony.global_position,
			minf(2.4, maxf(0.7, pony.actual_speed * 1.2)))
		nav._lookahead_cache = cache
		nav._lookahead_waypoint = waypoint
		# Per-instance phase spreads a crowd's clearance snapshots across frames.
		nav._lookahead_timer = 0.09 + randf() * 0.02
	return cache
