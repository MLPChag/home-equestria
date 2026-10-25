extends Node
## The bridge between saved lives and existing physical navigators. No movement,
## animation, dialogue generation or collision solver is implemented here.
const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
const CORE := preload("res://world/life/living_world.gd")
const PLACEMENT := preload("res://world/navigation/roster_placement.gd")
const FORMATION := preload("res://world/ai/pony_social_groups.gd")
const OWNER := "life:"
const HOUSE := preload("res://world/buildings/house_interior.gd")
const REST_PLACEMENT := preload("res://world/navigation/rest_placement.gd")
var _house_cursor:=0
const PROFILES := {
	"rainbow_dash": {"sociability": .8, "favorites": ["stroll", "explore"]},
	"fluttershy": {"sociability": .45, "favorites": ["cloudwatch", "rest"]},
	"pinkie_pie": {"sociability": .95, "favorites": ["company", "stroll"]},
	"applejack": {"sociability": .75, "favorites": ["stroll", "company"]},
	"rarity": {"sociability": .7, "favorites": ["company", "cloudwatch"]},
	"twilight_sparkle": {"sociability": .6, "favorites": ["explore", "cloudwatch"]},
	"spike": {"sociability": .8, "favorites": ["company", "stroll"]},
}
var core := CORE.new()
var host: Node
var population: Node
var actors: Dictionary = {}
var _timer := 0.0
var _roster_stamp := 0
var _discover_cursor := 0
var _route_cursor := 0
var _route_job: Dictionary = {}
var _navigation_stamps: Dictionary = {}
var _generation := 0
var _pending: Array = []
var _steering_usec := 0
var statistics := {"updates": 0, "places": 0, "routes": 0, "last_usec": 0, "core_usec": 0,
	"steering_usec": 0, "discovery_usec": 0}

func setup(game: Node, world_id: String) -> void:
	host = game
	core.setup(world_id, absi(world_id.hash()))
	process_mode = Node.PROCESS_MODE_PAUSABLE

func bind_population(residents: Node) -> void:
	population = residents
	population.life = self
	_sync_roster()

func _sync_roster() -> void:
	var stamp := hash(population.config.assignments)
	if stamp == _roster_stamp:
		return
	_roster_stamp = stamp
	for id in core.state.residents.keys():
		if population.config.assignments.has(id):
			continue
		core.cancel(core.state.residents[id].activity, "Removed from population")
		if not actors.has(id):
			core.state.residents.erase(id)
	for id: String in population.config.assignments:
		var region: String = population.residence_region(id) if population.has_method("residence_region") else population.config.assignments[id]
		var at: Vector3 = population.home_position(id, true)
		if population.saved.has(id) and population.saved[id].region == region:
			at = population.saved[id].position
		var flavor := absi(id.hash())
		var profile: Dictionary = PROFILES.get(id, {"sociability": .45 + (flavor % 45) / 100.0,
			"group_size": 2 + flavor % 3, "favorites": [CORE.KINDS.keys()[flavor % CORE.KINDS.size()]]}).duplicate(true)
		var friends := {}
		for peer in host.world_context.state.relationships.get(id, {}):
			friends[peer] = host.world_context.relationship(id, peer).preference
		profile.friends = friends
		core.register_resident(id, region, at, profile)
		var resident: Dictionary = core.state.residents.get(id, {})
		if resident.is_empty():
			continue
		if resident.home_region != region and not actors.has(id):
			core.cancel(resident.activity, "Home assignment changed")
			resident.home_region = region
			resident.region = region
			resident.position = CORE.vector(at)
			resident.place = ""

func attach(id: String, actor: Node3D, preserve_command := false) -> void:
	_sync_roster()
	core.social_enabled = population.config.social_groups
	if not core.state.residents.has(id):
		return
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null:
		return
	var lease := core.attach(id, actor.global_position, actor.rotation)
	if lease < 0:
		return
	actors[id] = {"actor": actor, "nav": nav, "lease": lease, "ticket": "", "goal": Vector3.INF,
		"retry": 0.0, "discover": 0, "paused_at": -1.0, "attached_at": float(core.state.elapsed)}
	actor.set_meta("living_world", true)
	var schedule := actor.get_node_or_null("Schedule")
	if schedule != null:
		schedule.set_physics_process(false)
	if is_instance_valid(host.social):
		host.social.leave(id)
	if not preserve_command:
		nav.stay()
		nav.command_owner = OWNER + id
		if host.has_method("_resident_service"):
			var region:String=core.state.residents[id].region
			nav._service=host._resident_service(region,actor.global_position)
			actor.set_meta("navigation_region",region)
	actors[id]["route_callback"]=_remember_route.bind(id,lease)
	if not _pending.has(id): _pending.append(id)
	nav.route_changed.connect(actors[id].route_callback)

func _remember_route(id: String, lease: int) -> void:
	if not actors.has(id) or actors[id].lease != lease:
		return
	var resident: Dictionary = core.state.residents[id]
	if resident.journey.has("legs"):return # Keep the regional itinerary; a local refinement is not its replacement.
	var intent := core.intent(id)
	if intent.is_empty() or resident.place.is_empty():
		return
	var entry: Dictionary = actors[id]
	var service: Node = entry.nav.get("_service")
	if not is_instance_valid(service):
		return
	# Only the navigator's complete, supported route can authorize the same
	# trip after its actor unloads. A follower's temporary slot is not a route.
	if core.certify_route(resident.place, intent.place, entry.nav.path, _navigation_stamp(service, entry.actor.profile)):
		resident.journey = {"route": str(resident.place) + ">" + str(intent.place),
			"progress": 0.0, "speed": float(resident.profile.get("travel_speed", 2.2))}

func detach(id: String) -> void:
	if not actors.has(id):
		return
	var entry: Dictionary = actors[id]
	if is_instance_valid(entry.nav) and entry.has("route_callback") and entry.nav.route_changed.is_connected(entry.route_callback):
		entry.nav.route_changed.disconnect(entry.route_callback)
	if is_instance_valid(entry.actor):
		core.detach(id, entry.lease, entry.actor.global_position, entry.actor.rotation)
	actors.erase(id)
	_roster_stamp = 0

func position_for(id: String) -> Vector3:
	return CORE.point(core.state.residents[id].position) if core.state.residents.has(id) else Vector3.INF

func checkpoint() -> Dictionary:
	for id in actors:
		var entry: Dictionary = actors[id]
		if is_instance_valid(entry.actor):
			core.observe(id, entry.lease, entry.actor.global_position, entry.actor.rotation)
	var snapshot := core.checkpoint()
	snapshot.pending_seconds += _timer
	return snapshot

func restore(value: Dictionary) -> bool:
	if not core.restore(value):
		return false
	for resident: Dictionary in core.state.residents.values():
		resident.position = CORE.vector(PLACEMENT.recover_saved_depth(CORE.point(resident.position)))
	_generation += 1
	_timer = 0
	_pending.clear()
	return true

func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(delta)
	if started > 0: CPU_PROFILE.record("living_world", started)

func _physics_step(delta: float) -> void:
	if not is_instance_valid(population) or not is_instance_valid(host):
		return
	var clock: Node = get_node("/root/TimeOfDay")
	if clock.paused:
		return
	if core.town_bounds.is_empty(): _measure_town()
	_timer += delta
	if _timer < .25:
		# Observe and steer each actor once per 0.25 s window, after that window's
		# advance, spread over its ticks (about two a tick) instead of all at once.
		_steer(ceili(_pending.size() / float(maxi(1, roundi((.25 - _timer) / delta)))))
		return
	var elapsed := _timer
	_timer = 0
	var started := Time.get_ticks_usec()
	_steer(_pending.size())
	statistics.steering_usec = _steering_usec
	_steering_usec = 0
	_sync_roster()
	core.social_enabled = population.config.social_groups
	core.daylight = clock.daylight()
	core.set_travel_clock(clock.day,clock.hours,core.daylight)
	var loaded_homes:Dictionary={}
	for home:Node3D in get_tree().get_nodes_in_group("house_interiors"):loaded_homes[home.place_id()]=true
	for place:Dictionary in core.state.places.values():
		if "HOUSE" in place.tags:place.enabled=loaded_homes.has(place.id)
	# Physical walking and cold terrain sampling do not accelerate with the sun.
	# A 20-minute day previously left only 12.5 seconds to gather, cancelling
	# ordinary local groups before their navigators could bring them together.
	core.meeting_grace = maxf(60.0, clock.day_length_minutes * 60.0 / 96.0)
	var phase := Time.get_ticks_usec()
	core.advance(elapsed)
	statistics.core_usec = Time.get_ticks_usec() - phase
	if not _route_job.is_empty() and (not is_instance_valid(_route_job.service) or float(core.state.elapsed) > float(_route_job.until)):
		if is_instance_valid(_route_job.service):
			_route_job.service.cancel_request(_route_job.request)
		_route_job = {}
	phase = Time.get_ticks_usec()
	var ids: Array = actors.keys()
	if not ids.is_empty():
		_discover_cursor %= ids.size()
		_discover(ids[_discover_cursor])
		_discover_cursor += 1
	statistics.discovery_usec = Time.get_ticks_usec() - phase
	_publish_outcomes()
	_pending = actors.keys()
	statistics.updates += 1
	statistics.last_usec = Time.get_ticks_usec() - started

func _steer(count: int) -> void:
	var started := Time.get_ticks_usec()
	for i in mini(count, _pending.size()):
		var id: String = _pending.pop_front()
		if not actors.has(id):
			continue
		# Observe right before steering: a stale pause reading could overwrite a player command.
		_observe(id)
		if actors.has(id):
			_apply(id)
	_steering_usec += Time.get_ticks_usec() - started

func _observe(id: String) -> void:
	var entry: Dictionary = actors[id]
	var actor: Node3D = entry.actor
	if not is_instance_valid(actor):
		actors.erase(id)
		return
	core.observe(id, entry.lease, actor.global_position, actor.rotation)
	# Reuse navigation's exact nearby-house candidates, including its streaming refresh.
	var home:Node3D=entry.nav.house_travel.here(actor)
	actor.set_meta("space_type","HOUSE" if home!=null else "LAND")
	actor.set_meta("house_id",home.place_id() if home!=null else "")
	core.state.residents[id].profile.travel_speed = actor.profile.trot_speed.x
	var nav: Node = entry.nav
	var external: bool = not nav.command_owner.is_empty() and not nav.command_owner.begins_with(OWNER)
	var reason: String = actor.action_interruption_reason() if actor.has_method("action_interruption_reason") else ""
	var talking: bool = host._population_busy(actor)
	if talking and is_instance_valid(host.director):
		talking = not host.director.movement_dialogue_allowed(id)
	var paused := external or not reason.is_empty() or talking
	core.pause_resident(id, paused, reason if not reason.is_empty() else "Player conversation or command")
	if paused:
		if entry.paused_at < 0:
			entry.paused_at = core.state.elapsed
		if float(core.state.elapsed) - float(entry.paused_at) > 60:
			core.cancel(core.state.residents[id].activity, "Friends continue while the player visits")
		# Never stop or rewrite a player-owned command.
		if not external:
			nav.stay()
			# In a conversation she stays put: no wandering off mid-chat (she says goodbye first).
			nav.wander_enabled = false
		entry.goal = Vector3.INF
	else:
		entry.paused_at = -1.0

func _apply(id: String) -> void:
	var entry: Dictionary = actors[id]
	var resident: Dictionary = core.state.residents[id]
	if resident.paused:
		return
	var nav: Node = entry.nav
	var actor: Node3D = entry.actor
	if host.has_method("_resident_service") and actor.get_meta("navigation_region",resident.region)!=resident.region:
		nav.stay();nav._service=host._resident_service(resident.region,actor.global_position)
		actor.set_meta("navigation_region",resident.region);entry.goal=Vector3.INF
	nav.command_owner = OWNER + id
	var intent := core.intent(id)
	actor.set_meta("life_intent", resident.last_reason)
	if intent.is_empty() or intent.stage != CORE.Stage.SPENDING_TIME:
		nav.face_point = Vector3.INF
	if intent.is_empty():
		if not entry.ticket.is_empty():
			nav.stay()
			actor.request_posture("stand")
			actor.remove_meta("social_group")
		entry.ticket = ""
		entry.goal = Vector3.INF
		# Place discovery is asynchronous and places can all be reserved. Keep
		# using the navigator's supported local outings while the planner waits.
		nav.command_speed_limit = INF
		nav.command_pace_target = -1.0
		nav.wander_enabled = true
		return
	if entry.ticket != intent.ticket:
		if REST_PLACEMENT.passage(get_tree(), intent.target, actor.profile.radius):
			core.cancel(intent.ticket, "Choose an activity away from the entrance")
			return
		nav.stay()
		entry.goal = Vector3.INF
	nav.wander_enabled = false
	entry.ticket = intent.ticket
	actor.set_meta("social_group", {"id": intent.ticket, "members": intent.members,
		"leader": intent.members[0], "state": intent.stage, "intention": intent.kind})
	match intent.stage:
		CORE.Stage.TRAVELLING:
			if intent.get("mode")=="train":
				nav.stay();actor.request_posture("stand");return
			if _at_meeting(id, intent) and actor.grounded():
				nav.stay()
				core.arrived(id, entry.lease, intent.ticket)
				return
			actor.request_posture("stand")
			if not actor.posture_status().settled:
				return
			if float(core.state.elapsed) < float(entry.retry):
				return
			var goal := _formation_goal(id, intent)
			if resident.journey.has("legs"):
				var route:Dictionary=core.state.routes.get(resident.journey.route,{})
				var progress:=CORE._project(route,actor.global_position)
				if progress<0:
					core.cancel(resident.activity,"Left the verified regional corridor");return
				goal=CORE._route_point(route,progress+24) if progress+24<float(route.length) else intent.target
			var following: bool = intent.members[0] != id and goal.distance_to(intent.target) > 1
			var pace := _company_pace(id, intent, goal, following)
			var gait := "walk" if pace <= float(actor.profile.walk_speed.y) + .01 else "trot"
			var failed: bool = nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]
			if failed:
				# The navigator has already exhausted its own recovery. Release the
				# reservation instead of reissuing this failed trip until its deadline.
				core.cancel(intent.ticket, "Could not reach the activity: " + nav.reason)
				return
			nav.command_speed_limit = pace
			nav.command_pace_target = pace
			# A navigator that stopped short (arrived at the nearest cell, or gave up) gets the
			# same goal again instead of standing there until the outing times out.
			var stopped_short: bool = not nav._has_target and Vector2(goal.x - actor.global_position.x, goal.z - actor.global_position.z).length() > 1.2
			# A meeting spot she cannot reach (the walk grid ends metres short of it): after
			# a few tries the nearest spot she did reach becomes her spot, instead of the
			# whole group standing there until the outing is cancelled.
			if stopped_short and goal.distance_to(intent.target) < .1:
				entry.short_tries = int(entry.get("short_tries", 0)) + 1
				if int(entry.short_tries) >= 3 and actor.global_position.distance_to(intent.target) < 14.0:
					if REST_PLACEMENT.passage(get_tree(), actor.global_position, actor.profile.radius):
						core.cancel(intent.ticket, "Could not reach a resting place clear of the entrance")
						return
					var activity: Dictionary = core.state.activities.get(intent.ticket, {})
					if not activity.is_empty():
						activity.targets[id] = [actor.global_position.x, actor.global_position.y, actor.global_position.z] if activity.targets[id] is Array else actor.global_position
					entry.short_tries = 0
					return
			elif not stopped_short:
				entry.short_tries = 0
			if (entry.goal as Vector3).distance_to(goal) < .6 and entry.get("gait", "") == gait and not stopped_short:
				return
			if nav.command_destination(goal, gait, following):
				entry.goal = goal; entry.gait = gait
			entry.retry = float(core.state.elapsed) + (.75 if following else 3)
		CORE.Stage.SPENDING_TIME:
			var checked: Vector3 = entry.get("rest_checked_at", Vector3.INF)
			if checked.distance_squared_to(actor.global_position) > .25:
				entry.rest_checked_at = actor.global_position
				if REST_PLACEMENT.passage(get_tree(), actor.global_position, actor.profile.radius):
					core.cancel(intent.ticket, "Move clear of the entrance before resting")
					return
			if intent.members.size() > 1 and intent.kind in ["stroll", "explore"]:
				_company_stroll(id, entry, intent); return
			if intent.members.size() > 1 and intent.posture == "sit" and not _company_settled(id, entry, intent):
				return
			if actor.has_meta("seating"): nav.face_point = Vector3.INF; return
			# A pony alone may take a bench, once per outing: retrying every tick stood her up
			# to walk to one, gave up, sat on the ground, and tried again (dev 2026-09-24:
			# "they get up and sit repeatedly"). Company never takes benches; benches all face
			# one way, and friends sit in the open facing one another.
			var seating: Node = get_tree().get_first_node_in_group("pony_seating")
			if intent.posture == "sit" and intent.members.size() < 2 and seating != null and entry.get("seat_ticket", "") != intent.ticket:
				entry.seat_ticket = intent.ticket
				if seating.sit(actor, 7.0): nav.face_point = Vector3.INF; return
			nav.stay()
			# Company sits facing one another: everyone turns toward the point between
			# them (their centroid) before settling (dev 2026-09-23).
			var centre := _group_centre(intent)
			nav.face_point = centre
			if centre.is_finite() and actor.posture_status().requested != intent.posture:
				if entry.get("face_ticket", "") != intent.ticket:
					entry.face_ticket = intent.ticket; entry.face_since = float(core.state.elapsed)
				var to := centre - actor.global_position; to.y = 0.0
				var off := absf(angle_difference(actor.rotation.y, atan2(-to.x, -to.z)))
				if to.length() > .25 and off > deg_to_rad(12.0) and float(core.state.elapsed) - float(entry.face_since) < 12.0:
					return
			actor.request_posture(intent.posture)

## Company pace (dev 2026-09-23: friends walk together and talk). Chatting friends amble
## side by side at a relaxed trot-walk; otherwise an easy trot, never the 2.2 m/s errand jog.
## A follower who has fallen behind her place catches up, then eases back.
const COMPANY_CHAT_PACE := 0.8
const COMPANY_PACE := 1.3
func _company_pace(id: String, intent: Dictionary, goal: Vector3, following: bool) -> float:
	var actor: Node3D = actors[id].actor
	if intent.members.size() < 2:
		return float(core.state.residents[id].profile.get("travel_speed", 2.2))
	var director: Node = host.get("director") if host != null else null
	var chatting: bool = director != null and director.has_method("company_chatting") and director.company_chatting(intent.members)
	var pace := COMPANY_CHAT_PACE if chatting else COMPANY_PACE
	if following:
		var lag := Vector2(goal.x - actor.global_position.x, goal.z - actor.global_position.z).length()
		pace += clampf((lag - 0.8) * 0.7, -0.3, 1.4)
	return clampf(pace, float(actor.profile.walk_speed.x), float(actor.profile.trot_speed.y))

## Friends out for a stroll keep strolling together: the first member leads from one
## nearby spot to the next at an easy pace, the others walk beside her.
func _company_stroll(id: String, entry: Dictionary, intent: Dictionary) -> void:
	var actor: Node3D = entry.actor
	var nav: Node = entry.nav
	nav.face_point = Vector3.INF
	actor.request_posture("stand")
	if not actor.posture_status().settled: return
	var leader_id: String = intent.members[0]
	if leader_id == id:
		var pace := _company_pace(id, intent, actor.global_position, false)
		nav.command_speed_limit = pace; nav.command_pace_target = pace
		var here: Vector3 = actor.global_position
		var aim: Vector3 = entry.get("stroll_goal", Vector3.INF)
		if aim.is_finite() and Vector2(aim.x - here.x, aim.z - here.z).length() > 1.5 and nav.state != nav.State.UNREACHABLE and nav.state != nav.State.BLOCKED:
			return
		# Next leg: 10-18 m on, turning gently, around the activity's place.
		var heading := -actor.global_basis.z; heading.y = 0.0
		heading = heading.normalized().rotated(Vector3.UP, randf_range(-1.1, 1.1))
		var towards_home: Vector3 = intent.target - here; towards_home.y = 0.0
		if towards_home.length() > 22.0: heading = (heading + towards_home.normalized() * 1.5).normalized()
		var point: Vector3 = nav.command_support(here + heading * randf_range(10.0, 18.0)) if nav.has_method("command_support") else here + heading * 12.0
		if not point.is_finite(): return
		if nav.command_destination(point, "walk" if pace <= float(actor.profile.walk_speed.y) + .01 else "trot"):
			entry.stroll_goal = point
		return
	if not actors.has(leader_id): return
	var leader: Node3D = actors[leader_id].actor
	var slot := _abreast(leader, intent.members.find(id))
	var goal: Vector3 = nav.command_formation_support(slot, leader.global_position) if nav.has_method("command_formation_support") else slot
	if not goal.is_finite(): goal = leader.global_position
	var pace := _company_pace(id, intent, goal, true)
	nav.command_speed_limit = pace; nav.command_pace_target = pace
	var gait := "walk" if pace <= float(actor.profile.walk_speed.y) + .01 else "trot"
	if (entry.goal as Vector3).distance_to(goal) < .5 and entry.get("gait", "") == gait: return
	if nav.command_destination(goal, gait, true): entry.goal = goal; entry.gait = gait

## Side by side, not in a queue: slot 1 on the leader's right, 2 on her left, 3 further right…
## a little behind her shoulder, facing the way she is going.
static func _abreast(leader: Node3D, slot: int) -> Vector3:
	var forward: Vector3 = leader.velocity if "velocity" in leader else Vector3.ZERO
	forward.y = 0.0
	if forward.length() < 0.2: forward = -leader.global_basis.z; forward.y = 0.0
	forward = forward.normalized()
	var side := forward.cross(Vector3.UP)
	var rank := (slot + 1) / 2
	var lateral := 1.05 * rank * (1.0 if slot % 2 == 1 else -1.0)
	return leader.global_position + side * lateral - forward * 0.25

## Arriving somewhere to sit, one of them suggests sitting down and the others agree (a short
## spoken exchange) before they sit; nopony just drops where she stands. Waits at most 16 s.
func _company_settled(id: String, entry: Dictionary, intent: Dictionary) -> bool:
	var director: Node = host.get("director") if host != null else null
	if director == null or not director.has_method("propose_company_sit"): return true
	var key := ",".join(PackedStringArray(intent.members))
	if entry.get("settle_ticket", "") != intent.ticket:
		entry.settle_ticket = intent.ticket
		entry.settle_since = float(core.state.elapsed)
		# Already sitting there when she came near the player (her actor attached mid-visit): the
		# sitting-down exchange happened offscreen. Restarting it stood the whole group up as the
		# player approached (dev 2026-10-14).
		if float(core.state.elapsed) - float(entry.get("attached_at", -1e9)) < 2.0:
			entry.settled_ticket = intent.ticket
		elif intent.members[0] == id:
			var place: Dictionary = core.state.places.get(intent.place, {})
			director.propose_company_sit(intent.members, str(place.get("name", place.get("id", "here"))))
	if entry.get("settled_ticket", "") == intent.ticket or director.company_sit_agreed(key) or float(core.state.elapsed) - float(entry.settle_since) > 16.0:
		return true
	# Meanwhile stand together facing the middle of the group.
	entry.nav.stay()
	entry.nav.face_point = _group_centre(intent)
	return false

## The point most in between the company's members who are here: their centroid.
## INF for a lone pony (nothing to face).
func _group_centre(intent: Dictionary) -> Vector3:
	if intent.members.size() < 2: return Vector3.INF
	var sum := Vector3.ZERO
	var count := 0
	for member: String in intent.members:
		if not actors.has(member) or not is_instance_valid(actors[member].actor): continue
		var at: Vector3 = actors[member].actor.global_position
		if at.distance_to(intent.target) > 12.0: continue
		sum += at; count += 1
	return sum / count if count >= 2 else Vector3.INF

func _at_meeting(id: String, intent: Dictionary) -> bool:
	var entry: Dictionary = actors[id]
	if "HOUSE" in core.state.places[intent.place].tags:
		var home:Node3D=entry.nav.house_travel.here(entry.actor)
		return home!=null and home.place_id()==intent.place and entry.actor.global_position.distance_to(intent.target)<.85
	if intent.members.size() == 1 or core.state.residents[id].journey.has("legs"):
		return entry.actor.global_position.distance_to(intent.target) < .85
	if not core.at_activity(id, entry.actor.global_position): return false
	var leader_id: String = intent.members[0]
	if leader_id == id: return true
	if not actors.has(leader_id): return false
	var leader: Node3D = actors[leader_id].actor
	return core.at_activity(leader_id, leader.global_position) and entry.nav.command_target_visible(leader)


func _formation_goal(id: String, intent: Dictionary) -> Vector3:
	if "HOUSE" in core.state.places[intent.place].tags:return intent.target
	var leader_id: String = intent.members[0]
	if leader_id == id or not actors.has(leader_id):
		return intent.target
	var leader: Node3D = actors[leader_id].actor
	# Open up into reserved seats at the meeting place. While travelling, reuse
	# the existing supported formation slots rather than inventing another gait.
	if leader.global_position.distance_to(intent.target) < 5:
		return intent.target
	var nav: Node = actors[id].nav
	var beside: Vector3 = nav.command_formation_support(_abreast(leader, intent.members.find(id)), leader.global_position)
	return beside if beside.is_finite() else leader.global_position

func _discover(id: String) -> void:
	var entry: Dictionary = actors[id]
	var actor: Node3D = entry.actor
	var nav: Node = entry.nav
	var service: Node = nav.get("_service")
	if not is_instance_valid(service) or not service.ready_for_paths:
		return
	var region: String = core.state.residents[id].region
	_discover_house(actor,nav,region)
	var stamp := _navigation_stamp(service, actor.profile)
	if _navigation_stamps.get(region) != stamp:
		_navigation_stamps[region] = stamp
		for key in core.state.routes.keys():
			var route: Dictionary = core.state.routes[key]
			if route.get("mode")=="train":continue
			if core.state.places[route.from].region == region and route.revision != stamp:
				core.state.routes.erase(key)
		_cancel_stale_journeys("Navigation changed; waiting for a verified route")
	var choices: Array = nav.command_places()
	var index: int = entry.discover
	# The first lookup commonly queues cold ground sampling and returns INF.
	# Retry the anchor until published; losing it also prevents offscreen trips.
	if index > 0:
		entry.discover += 1
	var at := actor.global_position
	var place_id: String
	var tags:Array=["rest","view","walk"]
	var railway:Node=host.get("railway")
	var station:String=railway.station_place_near(at) if is_instance_valid(railway) else ""
	if index==0:
		place_id="%s:anchor:%s"%[region,id]
		if core.state.residents[id].home_region==region:tags.append("home:"+id)
	elif not station.is_empty() and index%3==0:
		place_id=station;at=railway.station_exits[station.trim_prefix("rail:")];tags.append("station")
	elif not choices.is_empty() and index % 2 == 0:
		var named: String = choices[(index / 2) % choices.size()]
		at = nav.command_location(named)
		place_id = region + ":" + named
	else:
		# Stable outdoor cells extend unpainted regions; supported slots are
		# checked before publication, including elevation (clouds/bridges).
		at += Vector3(cos(index * 2.4), 0, sin(index * 2.4)) * 20
		at.x = snappedf(at.x, 16)
		at.z = snappedf(at.z, 16)
		place_id = "%s:outdoor:%d:%d:%d" % [region, at.x, at.z, roundi(at.y / 8)]
	if not at.is_finite() or at.distance_to(actor.global_position) > 90:
		return
	at = nav.command_support(at)
	if not at.is_finite():
		return
	if REST_PLACEMENT.passage(get_tree(), at, actor.profile.radius): return
	if core.state.places.has(place_id):
		var previous := CORE.point(core.state.places[place_id].position)
		var same_column := Vector2(previous.x-at.x, previous.z-at.z).length() < 3
		var changed_floor := same_column and absf(previous.y-at.y) > .5
		if not changed_floor:
			if index == 0:
				# Visiting another place must not relocate the existing home anchor.
				entry.discover = 1
			_certify_next_route(service, actor.profile, place_id)
			return
		# Revalidate saved places after a raised-platform spawn correction. Keep
		# the old reservation until the replacement slots pass support checks.
	for existing: Dictionary in ([] if core.state.places.has(place_id) else core.state.places.values()):
		var other := CORE.point(existing.position)
		if "station" in tags and existing.id!=place_id:continue
		if existing.region == region and absf(other.y - at.y) < .25 and Vector2(other.x - at.x, other.z - at.z).length() < 3:
			if "home:"+id in tags:
				if "home:"+id not in existing.tags:existing.tags.append("home:"+id)
			if index == 0:
				if core.state.residents[id].place.is_empty():core.state.residents[id].place=existing.id
				entry.discover = 1
			_certify_next_route(service, actor.profile, existing.id)
			return
	if not core.state.places.has(place_id) and "station" not in tags and index!=0 and core.state.places.values().filter(func(p): return p.region == region and ":anchor:" not in p.id and not str(p.id).begins_with("rail:")).size() >= 24:
		return
	var slots: Array = []
	var spacing: float = maxf(.85, actor.profile.radius * 2.5)
	for offset in [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD * 1.8, Vector3.BACK * 1.8]:
		var seat: Vector3 = nav.command_support(at + offset * spacing)
		if REST_PLACEMENT.passage(get_tree(), seat, actor.profile.radius): continue
		if not seat.is_finite() or not service.steering_segment_clear(at, seat, actor.profile):
			break
		if not PLACEMENT.support(actor.get_world_3d().direct_space_state, seat, actor.profile).is_finite():
			break
		slots.append(CORE.vector(seat))
	if slots.size() < 2:
		return
	var area:=WorldLayout.region(region)
	if area.get("kind") in ["city","town","village","hamlet","farm","sky_city"] and WorldLayout.distance_to(area,at)<30:tags.append("settlement")
	if core.state.places.has(place_id):
		for member in core.state.places[place_id].reserved.duplicate():
			core.cancel(core.state.residents[member].activity, "Meeting place moved to its supported floor")
		for key in core.state.routes.keys():
			var route: Dictionary = core.state.routes[key]
			if route.from == place_id or route.to == place_id: core.state.routes.erase(key)
		_cancel_stale_journeys("Meeting place moved to its supported floor")
	core.register_place(place_id, region, at, tags, slots.size(), slots)
	if index == 0:
		if core.state.residents[id].place.is_empty():core.state.residents[id].place=place_id
		entry.discover = 1
	if is_instance_valid(railway):railway.publish_connections()
	statistics.places += 1
	_certify_next_route(service, actor.profile, place_id)

func _discover_house(actor:Node3D,nav:Node,region:String) -> void:
	var homes:Array=get_tree().get_nodes_in_group("house_interiors")
	if homes.is_empty():return
	_house_cursor%=homes.size()
	var home:Node3D=homes[_house_cursor];_house_cursor+=1
	# Owners' home tags, also added to places restored from an older save (2026-09-22).
	var owners:Array=[]
	if is_instance_valid(population) and population.has_method("residents_of"):
		for id in population.residents_of(home.place_id()):owners.append("home:"+id)
	if core.state.places.has(home.place_id()):
		var tags:Array=core.state.places[home.place_id()].tags
		for tag in owners:
			if not tag in tags:tags.append(tag);core.state.revision+=1
		return
	if home.center().distance_to(actor.global_position)>90 or not home.fits(actor.profile):return
	var slots:Array=[]
	for desired:Vector3 in home.slots():
		if REST_PLACEMENT.passage(get_tree(), desired, actor.profile.radius): continue
		var seat:Vector3=PLACEMENT.support(actor.get_world_3d().direct_space_state,desired,actor.profile,home)
		if seat.is_finite():slots.append(CORE.vector(seat))
	if slots.size()<2:
		# A furnished small room can lose all four centre samples. Search its
		# authored floor at discovery time; keep the same support/passage rules.
		var spacing:float=actor.profile.radius*2.0+.08
		for room:Rect2 in home.floors:
			for z in 4:
				for x in 4:
					var local:=room.position+room.size*Vector2((x+.5)/4.0,(z+.5)/4.0)
					var desired:Vector3=home.to_global(Vector3(local.x,home.floor_y,local.y))
					if REST_PLACEMENT.passage(get_tree(),desired,actor.profile.radius):continue
					var separated:=true
					for slot:Array in slots:
						if CORE.point(slot).distance_to(desired)<spacing:separated=false;break
					if not separated:continue
					var seat:Vector3=PLACEMENT.support(actor.get_world_3d().direct_space_state,desired,actor.profile,home)
					if seat.is_finite():slots.append(CORE.vector(seat))
					if slots.size()>=4:break
				if slots.size()>=4:break
			if slots.size()>=4:break
	if slots.size()<2:return
	core.register_place(home.place_id(),region,home.center(),["HOUSE","rest","settlement"]+owners,slots.size(),slots)

func _cancel_stale_journeys(reason: String) -> void:
	for activity: Dictionary in core.state.activities.values():
		for member in activity.members:
			var journey: Dictionary = core.state.residents[member].journey
			if journey.is_empty() or journey.get("direct", false): continue
			if journey.get("legs", [journey.route]).any(func(leg): return not core.state.routes.has(leg)):
				core.cancel(activity.id, reason)
				break


func _certify_next_route(service: Node, profile: Resource, to: String) -> void:
	if not _route_job.is_empty():
		return
	var places: Array = core.state.places.keys()
	_route_cursor %= places.size()
	var from: String = places[_route_cursor]
	_route_cursor += 1
	if from == to or core.state.routes.has(from + ">" + to):
		return
	var a: Dictionary = core.state.places[from]
	var b: Dictionary = core.state.places[to]
	if a.region != b.region or CORE.point(a.position).distance_to(CORE.point(b.position)) > 90:
		return
	_route_job = {"service": service, "from": from, "to": to, "generation": _generation,
		"until": float(core.state.elapsed) + 30, "stamp": _navigation_stamp(service, profile)}
	_route_job.request = service.request_path(CORE.point(a.position), CORE.point(b.position), profile,
		_route_ready.bind(_route_job.duplicate()), false, true)

func _route_ready(result: Dictionary, request: int, revision: int, job: Dictionary) -> void:
	if _route_job.get("request", -1) != request or _route_job.get("service") != job.service:
		return
	_route_job = {}
	if job.generation != _generation or not is_instance_valid(job.service):
		return
	if result.get("stale", false) or revision != job.service.revision:
		return
	var path: PackedVector3Array = result.get("path", PackedVector3Array())
	if core.certify_route(job.from, job.to, path, job.stamp):
		statistics.routes += 1

func _navigation_stamp(service: Node, profile: Resource) -> String:
	return str(hash([service.get("_cache_dir"), service.revision, profile.radius, profile.step_height, profile.max_slope_degrees]))

func _publish_outcomes() -> void:
	for event: Dictionary in core.take_outcomes():
		if event.kind != "completed":
			continue
		var description := "Spent time %s at %s." % [event.activity.replace("_", " "), event.place]
		host.world_context.shared_event("shared_outing", event.members, event.id, description)
		for id in event.members:
			var friends: Dictionary = core.state.residents[id].profile.get("friends", {})
			for peer in event.members:
				friends[peer] = host.world_context.relationship(id, peer).preference
			core.state.residents[id].profile.friends = friends

## The settled town: the houses' extent plus a margin for the square, gardens and streets.
func _measure_town() -> void:
	var houses := get_tree().get_nodes_in_group("house_interiors")
	var box := Rect2()
	var count := 0
	for h: Node3D in houses:
		if _house_region(h) != "ponyville": continue
		var p := Vector2(h.global_position.x, h.global_position.z)
		box = Rect2(p, Vector2.ZERO) if count == 0 else box.expand(p)
		count += 1
	if count < 3: return
	core.town_bounds["ponyville"] = box.grow(45.0)

## Scenery under the town root also contains distant homes (Zecora in Everfree).
## An owner's assignment disambiguates overlapping region footprints only when it
## contains the physical house; saved reassignment cannot move a fixed building.
func _house_region(house: Node3D) -> String:
	var at := house.global_position
	var owner := str(house.get_meta("reserved_for", ""))
	if not owner.is_empty() and is_instance_valid(population):
		var assigned := str(population.config.assignments.get(owner, ""))
		var area := WorldLayout.region(assigned)
		if not area.is_empty() and is_zero_approx(WorldLayout.distance_to(area, at)):
			return assigned
	return str(WorldLayout.nearest(at).get("id", ""))

func _exit_tree() -> void:
	if not _route_job.is_empty() and is_instance_valid(_route_job.service):
		_route_job.service.cancel_request(int(_route_job.get("request", -1)))

## Debug readout for one resident's outing (playtest bridge: call path=LivingWorld method=debug_resident).
func debug_resident(id: String) -> Dictionary:
	if not core.state.residents.has(id): return {}
	var resident: Dictionary = core.state.residents[id]
	var activity: Dictionary = core.state.activities.get(resident.activity, {})
	var out := {"paused": resident.paused, "reason": resident.last_reason, "activity": activity.get("kind", ""),
		"stage": activity.get("stage", ""), "members": activity.get("members", []), "arrived": activity.get("arrived", []),
		"deadline_in": float(activity.get("deadline", 0.0)) - float(core.state.elapsed), "company_with": resident.get("company_with", [])}
	if actors.has(id) and not activity.is_empty():
		var at: Vector3 = actors[id].actor.global_position
		out["at_activity"] = core.at_activity(id, at)
		out["target"] = core.point(activity.targets[id])
		out["to_target"] = at.distance_to(core.point(activity.targets[id]))
		out["at_meeting"] = _at_meeting(id, core.intent(id)) if not core.intent(id).is_empty() else false
	return out
