extends RefCounted
## Persistent lives independent of scene residency. Only observed physical arrivals or
## completed certified abstract routes can start an activity. No model/provider dependency.
const VERSION := 1
const MAX_EVENTS := 8192
const MAX_MEMORIES := 64
const CHOICES_PER_REVIEW := 24
const INVITATION_DISTANCE := 50.0
const TRAIN_NIGHT_SHARE := Vector2(.01,.03)
const TRAIN_DAY_SHARE := Vector2(.06,.09)
const TRAIN_LEISURE_BREAK := 300.0
# Stable names survive JSON without numeric enum conversion.
const Stage := {"TRAVELLING": "travelling", "SPENDING_TIME": "spending_time"}

# All activity-specific policy lives here. Selection and completion use the same
# rules for every kind; adding a kind does not add branches to the simulation.
const KINDS := preload("res://world/life/activities.gd").KINDS
const CHECKPOINT := preload("res://world/life/life_checkpoint.gd")

var state: Dictionary = {}
var social_enabled := true
var daylight := 1.0
var meeting_grace := 60.0
var _leases: Dictionary = {}
var _lease_serial := 0
var _outcomes: Array = []
var _accumulator := 0.0
var _cursor := 0
var transport_available := false
## Region id -> Rect2 (XZ) of the settled town: outside "explore", residents keep their
## outings inside it and head back into it when they have strayed (dev 2026-09-23).
var town_bounds := {}

func setup(world_id: String, seed_value := 1) -> void:
	state = {"version":VERSION,"world_id":world_id,"seed":seed_value,"revision":0,"serial":0,"elapsed":0.0,
		"residents":{},"places":{},"routes":{},"activities":{},"events":[]}
	_leases.clear()
	_outcomes.clear()
	_accumulator = 0
	_cursor = 0
	transport_available = false

static func vector(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

static func point(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])
static func finite_position(value: Variant) -> bool:
	return value is Array and value.size()==3 and value.all(func(n): return (n is float or n is int) and is_finite(float(n)) and absf(float(n))<100000)

func register_resident(id: String, home: String, position: Vector3, profile: Dictionary = {}) -> bool:
	if id.is_empty() or not position.is_finite() or state.residents.size() >= 4096: return false
	if state.residents.has(id): return true
	state.residents[id] = {"id":id,"home_region":home,"region":home,"position":vector(position),"rotation":[0,0,0],
		"profile":profile.duplicate(true),"activity":"","place":"","journey":{},"paused":false,
		"wants":{"social":.45,"energy":.6,"curiosity":.5},"next_review":float(state.elapsed)+_roll(id,"initial")*12,
		"decisions":0,"choice_cursor":0,"memories":[],"recent_kinds":[],"last_reason":"Settling into the day"}
	state.revision += 1
	return true

func register_place(id: String, region: String, position: Vector3, tags: Array, capacity := 4, slots: Array = []) -> bool:
	if id.is_empty() or not position.is_finite() or capacity < 1: return false
	# Caller certifies supported ground/clearance before publishing. Refresh preserves occupancy.
	var reservations: Array = state.places.get(id,{}).get("reserved",[])
	var radius := 2.0
	for slot in slots:
		radius = maxf(radius, point(slot).distance_to(position) + .5)
	state.places[id] = {"id":id,"region":region,"position":vector(position),"tags":tags.duplicate(),
		"capacity":capacity,"reserved":reservations,"enabled":true,"slots":slots.duplicate(true),"radius":radius}
	state.revision += 1; return true

func certify_route(from: String, to: String, points: PackedVector3Array, revision: String, mode := "walk", service := "", seconds := 0.0) -> bool:
	if not state.places.has(from) or not state.places.has(to) or points.size()<2 or revision.is_empty(): return false
	if mode not in ["walk","train"] or (mode=="train" and (service.is_empty() or not is_finite(seconds) or seconds<=0)):return false
	for p in points: if not p.is_finite(): return false
	if points[0].distance_to(point(state.places[from].position))>2 or points[-1].distance_to(point(state.places[to].position))>2: return false
	var encoded: Array=[]; var length:=0.0
	for i in points.size():
		encoded.append(vector(points[i]))
		if i>0: length+=points[i-1].distance_to(points[i])
	state.routes[from+">"+to]={"from":from,"to":to,"points":encoded,"length":length,"revision":revision}
	if mode=="train":state.routes[from+">"+to].merge({"mode":mode,"service":service,"seconds":seconds})
	state.revision+=1; return true

func attach(id: String, position: Vector3, rotation := Vector3.ZERO) -> int:
	if not state.residents.has(id) or _leases.has(id):
		return -1
	if not position.is_finite() or not rotation.is_finite():
		return -1
	_lease_serial += 1
	_leases[id] = _lease_serial
	observe(id,_lease_serial,position,rotation)
	var resident: Dictionary = state.residents[id]
	# Her body walks from here; the offscreen straight line is only for while she is unloaded.
	if resident.journey.get("direct", false): resident.journey = {}
	if not resident.activity.is_empty():
		var activity: Dictionary = state.activities[resident.activity]
		if not at_activity(id, position):
			activity.arrived.erase(id)
			activity.stage = Stage.TRAVELLING
			activity.deadline = maxf(activity.deadline,float(state.elapsed) + meeting_grace + position.distance_to(point(activity.targets[id])) / 1.5)
	return _lease_serial

func observe(id: String, lease: int, position: Vector3, rotation := Vector3.ZERO) -> bool:
	if lease <= 0 or _leases.get(id,-1)!=lease or not position.is_finite() or not rotation.is_finite(): return false
	var resident: Dictionary=state.residents[id]
	resident.position=vector(position); resident.rotation=vector(rotation)
	state.revision+=1; return true

func detach(id: String, lease: int, position: Vector3, rotation := Vector3.ZERO) -> bool:
	if not observe(id,lease,position,rotation): return false
	_leases.erase(id)
	var resident: Dictionary=state.residents[id]
	# Resume an offscreen journey on its certified path when she is on it; otherwise, and when
	# she was walking there on her own navigator, carry on offscreen in a straight line
	# (dev 2026-09-26: residents never freeze, whatever the distance; only the model unloads).
	var activity: Dictionary = state.activities.get(resident.activity, {})
	if not resident.journey.is_empty():
		var route: Dictionary=state.routes.get(resident.journey.route,{})
		if route.get("mode","walk")=="train":return true
		var progress := _project(route,position)
		if progress >= 0:
			resident.journey.progress = progress
		elif not activity.is_empty():
			resident.journey = direct_journey(resident, point(activity.targets[id]))
	elif not activity.is_empty() and not id in activity.arrived:
		resident.journey = direct_journey(resident, point(activity.targets[id]))
	return true

## An unloaded resident's walk to `to` when no certified route exists: a straight line with a
## detour allowance for its length. Nopony sees it; her body is placed on safe ground near
## wherever it has got to if she streams back in.
const DETOUR := 1.3
func direct_journey(resident: Dictionary, to: Vector3) -> Dictionary:
	var from := point(resident.position)
	return {"direct": true, "from": vector(from), "to": vector(to), "progress": 0.0,
		"length": maxf(.01, from.distance_to(to) * DETOUR), "speed": float(resident.profile.get("travel_speed", 2.2))}

## One second of a straight-line journey; true once she is there.
static func advance_direct(resident: Dictionary) -> bool:
	var journey: Dictionary = resident.journey
	journey.progress = minf(float(journey.length), float(journey.progress) + float(journey.speed))
	var t := float(journey.progress) / float(journey.length)
	var at := point(journey.from).lerp(point(journey.to), t)
	if t < 1.0 and is_instance_valid(WorldTerrain.instance):
		var h: float = WorldTerrain.instance.height_at(at)
		if is_finite(h): at.y = h
	resident.position = vector(at)
	return t >= 1.0

func pause_resident(id: String, paused: bool, reason := "Player interaction") -> void:
	if not state.residents.has(id): return
	var resident: Dictionary=state.residents[id]
	if resident.paused==paused: return
	resident.paused=paused; resident.last_reason=reason if paused else "Returning to the afternoon"
	if not resident.activity.is_empty(): _event("interrupted" if paused else "resumed",state.activities.get(resident.activity,{}),[id])
	state.revision+=1

func propose(leader: String, kind: String, place_id: String, companions: Array = []) -> Dictionary:
	if not KINDS.has(kind) or not state.residents.has(leader) or not state.places.has(place_id):
		return {"status": "rejected", "reason": "Unknown resident, activity or place"}
	var place: Dictionary = state.places[place_id]
	if not _supports(place, kind):
		return {"status": "rejected", "reason": "Place cannot support this activity"}
	var members: Array = [leader]
	for id in companions:
		if id not in members:
			members.append(id)
	if members.size() > mini(6, int(place.capacity)) or not place.reserved.is_empty():
		return {"status": "deferred", "reason": "Not enough room"}
	for id in members:
		if not state.residents.has(id):
			return {"status": "rejected", "reason": "Unknown participant"}
		var resident: Dictionary = state.residents[id]
		if not _can_join(resident, place, kind):
			return {"status": "deferred", "reason": "Participant is busy or has no certified route"}
		if id != leader and not _accepts_invitation(resident, state.residents[leader]):
			return {"status": "rejected", "reason": "Companion declined or is not nearby"}

	# Reserve only after everyone has accepted and can reach the place.
	state.serial += 1
	var ticket: String = "life-" + str(state.serial)
	var activity := {
		"id": ticket, "kind": kind, "place": place_id, "members": members,
		"arrived": [], "targets": {}, "stage": Stage.TRAVELLING, "created": state.elapsed,
		"started": -1.0, "remaining": float(KINDS[kind].duration),
		"deadline": float(state.elapsed) + meeting_grace,
	}
	state.activities[ticket] = activity
	for id in members:
		var resident: Dictionary = state.residents[id]
		resident.activity = ticket
		resident.last_reason = "Heading to " + kind
		place.reserved.append(id)
		activity.deadline = maxf(activity.deadline, float(state.elapsed) + meeting_grace + point(resident.position).distance_to(point(place.position)) / 1.5)
		activity.targets[id] = place.slots[members.find(id)] if not place.slots.is_empty() else place.position
		var route_id: String = str(resident.place) + ">" + place_id
		var plan:=_regional_plan(resident,place,kind) if _needs_itinerary(resident,place) else {}
		if plan.is_empty() and not _leases.has(id) and point(resident.position).distance_to(point(place.position)) <= float(place.radius):
			activity.arrived.append(id)
			resident.place = place_id
			resident.position = activity.targets[id].duplicate()
		elif not plan.is_empty() and plan.status=="ready":
			var legs:Array=plan.legs.map(func(leg):return leg.id)
			resident.journey={"route":legs[0],"legs":legs,"leg":0,"progress":0.0,"speed":float(resident.profile.get("travel_speed",2.2)),"aboard":false}
			# Allow one missed departure plus the actual service journey, not a walking ETA.
			activity.deadline=maxf(activity.deadline,float(state.elapsed)+meeting_grace+plan.seconds*3)
		elif state.routes.has(route_id) and state.routes[route_id].get("mode","walk")=="walk":
			resident.journey = {"route": route_id, "progress": 0.0,
				"speed": float(resident.profile.get("travel_speed", 2.2))}
		elif not _leases.has(id):
			resident.journey = direct_journey(resident, point(activity.targets[id]))
	_event("planned", activity, members)
	if members.size() > 1:
		_event("invited", activity, members)
	var departing: Array = members.filter(func(id): return id not in activity.arrived)
	if not departing.is_empty():
		_event("departed", activity, departing)
	_maybe_start(activity)
	state.revision += 1
	return {"status": "accepted", "ticket": ticket}

func arrived(id: String, lease: int, ticket: String) -> bool:
	if lease <= 0 or _leases.get(id,-1)!=lease or not state.activities.has(ticket): return false
	if state.residents[id].activity!=ticket: return false
	var activity: Dictionary=state.activities[ticket]
	var resident:Dictionary=state.residents[id]
	if not resident.journey.is_empty() and resident.journey.has("legs"):
		var route:Dictionary=state.routes.get(resident.journey.route,{})
		if route.is_empty() or route.get("mode","walk")=="train":return false
		if point(resident.position).distance_to(intent(id).target)>1:return false
		_next_leg(id,activity);return true
	if not at_activity(id, point(state.residents[id].position)): return false
	_arrive(id,activity); return true

## Outdoor company gathers within conversational distance, not an exact chair.
## Keep solo/transport arrivals precise and reject vertically stacked floors.
func at_activity(id: String, position: Vector3) -> bool:
	if not state.residents.has(id): return false
	var activity: Dictionary = state.activities.get(state.residents[id].activity, {})
	if activity.is_empty(): return false
	var target := point(activity.targets[id])
	if "HOUSE" in state.places[activity.place].tags or activity.members.size() == 1 or state.residents[id].journey.has("legs"):
		return position.distance_to(target) <= 1.0
	if absf(position.y-target.y) <= .5 and position.distance_to(target) <= 3.0: return true
	# Company gathers around each other, not on exact spots: beside a friend who is already
	# there counts. An unreachable seat slot left followers standing 5 m short until the
	# whole outing was cancelled ("Could not meet in time").
	for other: String in activity.arrived:
		if other == id or not state.residents.has(other): continue
		var there := point(state.residents[other].position)
		if absf(position.y-there.y) <= .6 and position.distance_to(there) <= 3.0 and position.distance_to(target) <= 9.0: return true
	return false


func _arrive(id: String, activity: Dictionary) -> void:
	if id in activity.arrived: return
	activity.arrived.append(id)
	var resident: Dictionary=state.residents[id]
	resident.place=activity.place; resident.region=state.places[activity.place].region; resident.journey={}
	resident["wander_stops"]=0 if _settled_place(state.places[activity.place],id) else int(resident.get("wander_stops",0))+1
	_event("arrived",activity,[id]); _maybe_start(activity)

func _maybe_start(activity: Dictionary) -> void:
	if activity.stage!=Stage.TRAVELLING or activity.arrived.size()!=activity.members.size(): return
	activity.stage=Stage.SPENDING_TIME; activity.started=state.elapsed
	for id in activity.members:
		state.residents[id].last_reason = "Spending time " + str(activity.kind).replace("_", " ")
	_event("started",activity,activity.members)

func cancel(ticket: String, reason: String) -> void:
	if not state.activities.has(ticket): return
	var activity: Dictionary=state.activities[ticket]
	_event("cancelled",activity,activity.members,reason)
	_release(activity,reason)

func _release(activity: Dictionary, reason: String) -> void:
	for id in activity.members:
		var resident: Dictionary=state.residents[id]
		resident.activity=""; resident.journey={}; resident.next_review=float(state.elapsed)+15+_roll(id,"rest")*20
		resident.last_reason=reason
		if state.places.has(activity.place): state.places[activity.place].reserved.erase(id)
	state.activities.erase(activity.id); state.revision+=1

## Friends stay friends for the afternoon (dev 2026-09-23: "walk together, talk together,
## sit down"): after an outing together, or a chance chat, these ponies prefer each other as
## company for a while, accept each other's invitations, and the first of them plans the next
## outing right away so the group moves on together instead of scattering.
const COMPANY_MEMORY := 300.0
func note_company(members: Array, seconds := COMPANY_MEMORY, regroup := true) -> void:
	var here: Array = members.filter(func(id): return state.residents.has(id))
	if here.size() < 2: return
	for id: String in here:
		var resident: Dictionary = state.residents[id]
		resident["company_with"] = here.filter(func(other): return other != id)
		resident["company_until"] = float(state.elapsed) + seconds
		if regroup and resident.activity.is_empty():
			resident.next_review = float(state.elapsed) + (1.0 if id == here[0] else 6.0)
			resident.wants.social = maxf(float(resident.wants.social), .5)

func _sticky(resident: Dictionary, peer_id: String) -> bool:
	return peer_id in resident.get("company_with", []) and float(state.elapsed) < float(resident.get("company_until", -1.0))

func _finish(activity: Dictionary) -> void:
	_event("completed",activity,activity.members)
	var effects: Dictionary = KINDS[activity.kind].effects
	for id in activity.members:
		var resident: Dictionary=state.residents[id]
		for need in effects:
			resident.wants[need] = clampf(float(resident.wants[need]) + float(effects[need]), 0, 1)
		resident.wants.social=clampf(float(resident.wants.social)-(0.3 if activity.members.size()>1 else .02),0,1)
		resident.recent_kinds.append(activity.kind)
		if resident.recent_kinds.size()>4: resident.recent_kinds.pop_front()
	_release(activity,"Finished "+activity.kind)
	if activity.members.size() > 1: note_company(activity.members)

## Process one bounded slice. Large wait/sleep advances drain remaining time over frames.
func advance(seconds: float, max_steps := 8) -> void:
	if not is_finite(seconds) or seconds<0 or state.is_empty(): return
	_accumulator+=seconds
	for i in max_steps:
		if _accumulator<1.0: break
		_accumulator-=1.0; state.elapsed+=1.0
		_step()

func pending_seconds() -> float: return _accumulator

func _step() -> void:
	var tickets: Array = state.activities.keys()
	tickets.sort()
	for ticket in tickets:
		var activity: Dictionary = state.activities[ticket]
		if activity.members.any(func(id): return state.residents[id].paused):
			activity.deadline += 1
			continue
		match activity.stage:
			Stage.TRAVELLING:
				_travel(activity)
			Stage.SPENDING_TIME:
				activity.remaining -= 1
				if activity.remaining <= 0:
					_finish(activity)

	var ids: Array = state.residents.keys()
	ids.sort()
	for i in mini(12, ids.size()):
		_cursor = posmod(_cursor, ids.size())
		var resident: Dictionary = state.residents[ids[_cursor]]
		_cursor += 1
		if _available(resident) and float(resident.next_review) <= float(state.elapsed):
			_decide(resident.id)

func _travel(activity: Dictionary) -> void:
	if float(state.elapsed) > float(activity.deadline):
		cancel(activity.id, "Could not meet in time")
		return
	for id in activity.members:
		var resident: Dictionary = state.residents[id]
		# Loaded actors report arrival through their lease; never move them here.
		if _leases.has(id) or resident.journey.is_empty():
			continue
		if resident.journey.get("direct", false):
			if advance_direct(resident): _next_leg(id, activity)
			continue
		var route: Dictionary = state.routes.get(resident.journey.route, {})
		if route.is_empty():
			cancel(activity.id, "Route is no longer available")
			return
		if route.get("mode","walk")=="train":continue # Only the actual rail service advances riders.
		resident.journey.progress = minf(float(route.length), float(resident.journey.progress) + float(resident.journey.speed))
		resident.position = vector(_route_point(route, float(resident.journey.progress)))
		if float(resident.journey.progress) >= float(route.length):
			_next_leg(id, activity)

func _next_leg(id:String,activity:Dictionary)->void:
	var resident:Dictionary=state.residents[id];var journey:Dictionary=resident.journey
	var route:Dictionary=state.routes.get(journey.get("route",""),{})
	if not route.is_empty():resident.place=route.to;resident.region=state.places[route.to].region
	if journey.has("legs") and int(journey.leg)+1<journey.legs.size():
		journey.leg=int(journey.leg)+1;journey.route=journey.legs[journey.leg];journey.progress=0.0;journey.aboard=false
		return
	if not _leases.has(id):resident.position=activity.targets[id].duplicate()
	_arrive(id,activity)

func train_boarded(id:String,service_id:String)->bool:
	var intent_now:=intent(id)
	if intent_now.get("mode")!="train" or intent_now.get("service")!=service_id:return false
	if state.residents[id].journey.get("aboard",false):return false
	if point(state.residents[id].position).distance_to(intent_now.target)>2:return false
	state.residents[id].journey.aboard=true;return true

func train_arrived(id:String,service_id:String,station_place:String,position:Vector3)->bool:
	var intent_now:=intent(id)
	if intent_now.get("mode")!="train" or intent_now.get("service")!=service_id or intent_now.get("arrival")!=station_place:return false
	if not state.residents[id].journey.get("aboard",false) or position.distance_to(point(state.places[station_place].position))>2:return false
	state.residents[id].position=vector(position)
	state.residents[id].last_train_arrival=float(state.elapsed)
	_next_leg(id,state.activities[intent_now.ticket]);return true

func train_demand() -> Dictionary:
	# Count the whole outward journey, including its walk and wait, but not the
	# destination activity or final walk after the last train leg.
	var travelling:=0
	for resident:Dictionary in state.residents.values():
		var journey:Dictionary=resident.journey
		var legs:Array=journey.get("legs",[])
		for index in range(int(journey.get("leg",0)),legs.size()):
			if state.routes.get(legs[index],{}).get("mode")=="train":
				travelling+=1;break
	var climate:Dictionary=state.get("travel_clock",{"hours":12.0,"daylight":daylight})
	var random:=RandomNumberGenerator.new()
	# Day's sample changes at midnight (its weight is zero); night's sample
	# changes at noon. One night therefore keeps its draw across midnight.
	random.seed=hash("%d/train-day/%d"%[int(state.seed),floori(float(climate.hours)/24)])
	var day:=random.randf_range(TRAIN_DAY_SHARE.x,TRAIN_DAY_SHARE.y)
	random.seed=hash("%d/train-night/%d"%[int(state.seed),floori((float(climate.hours)-12)/24)])
	var night:=random.randf_range(TRAIN_NIGHT_SHARE.x,TRAIN_NIGHT_SHARE.y)
	var share:=lerpf(night,day,clampf(float(climate.daylight),0,1))
	return {"target":roundi(state.residents.size()*share),"travelling":travelling,"share":share}

func set_travel_clock(day:int,hours:float,light:float)->void:
	state["travel_clock"]={"hours":day*24.0+hours,"daylight":clampf(light,0,1)}

func _decide(id: String) -> void:
	var resident: Dictionary = state.residents[id]
	resident.decisions += 1
	resident.next_review = float(state.elapsed) + 5 + _roll(id, "review") * 10
	resident.wants.social = minf(1, float(resident.wants.social) + .02)
	resident.wants.curiosity = minf(1, float(resident.wants.curiosity) + .015)
	resident.wants.energy = maxf(0, float(resident.wants.energy) - .005)
	var choice := _choose_activity(resident)
	if choice.is_empty():
		resident.last_reason = "Waiting for an available supported place or route"
		return
	var companions := _choose_companions(resident, choice)
	propose(id, choice.kind, choice.place, companions)

func _choose_activity(resident: Dictionary) -> Dictionary:
	var demand:=train_demand() if transport_available else {"target":0,"travelling":0}
	var encourage_trip:bool=demand.travelling<demand.target and float(state.elapsed)-float(resident.get("last_train_arrival",-TRAIN_LEISURE_BREAK))>=TRAIN_LEISURE_BREAK
	var needs := {
		"social": float(resident.wants.social) * float(resident.profile.get("sociability", .65)),
		"rest": 1.0 - float(resident.wants.energy),
		"curiosity": float(resident.wants.curiosity),
	}
	var places: Array = state.places.keys()
	places.sort()
	var kinds: Array = KINDS.keys()
	var count := places.size() * kinds.size()
	var best: Dictionary = {}
	var best_score := -INF
	# Always consider the nearest available places as well as the rotating
	# discovery window. Alphabetical slices alone skipped nearby hangouts and
	# filled the town's route queue with simultaneous 100-180m errands.
	var nearby: Array = []
	var origin := point(resident.position)
	for place_id: String in places:
		var candidate: Dictionary = state.places[place_id]
		if candidate.region != resident.region or not candidate.enabled or not candidate.reserved.is_empty(): continue
		nearby.append({"id":place_id,"distance":origin.distance_squared_to(point(candidate.position))})
		nearby.sort_custom(func(a,b): return a.distance < b.distance if a.distance != b.distance else a.id < b.id)
		nearby.resize(mini(3,nearby.size()))
	# Her own house is always a candidate, wherever she is in town.
	for place_id: String in places:
		var own: Dictionary = state.places[place_id]
		if "home:" + str(resident.id) in own.tags and own.region == resident.region and own.enabled and own.reserved.is_empty() \
				and not nearby.any(func(entry): return entry.id == place_id):
			nearby.append({"id":place_id,"distance":0.0})
	var local_choices := nearby.size() * kinds.size()
	for i in mini(CHOICES_PER_REVIEW, count):
		var index := posmod(int(resident.get("choice_cursor", 0)), count)
		var place: Dictionary
		if i < local_choices:
			place = state.places[nearby[i / kinds.size()].id]
			index = i
		else:
			resident.choice_cursor = index + 1
			place = state.places[places[index / kinds.size()]]
		var kind: String = kinds[index % kinds.size()]
		if not _supports(place, kind):
			continue
		var town: Rect2 = town_bounds.get(resident.home_region, Rect2())
		var in_town := not town.has_area() or town.has_point(Vector2(float(place.position[0]), float(place.position[2])))
		if not in_town and kind != "explore" and place.region == resident.home_region:
			continue
		# Houses are for their own residents to rest in, mostly in the evening: nopony
		# hangs about in somepony else's house, or indoors all day (dev 2026-09-23).
		if "HOUSE" in place.tags:
			if kind != "rest" or not ("home:" + str(resident.id) in place.tags): continue
			if daylight > 0.6 and _roll(resident.id, str(place.id) + str(int(float(state.elapsed) / 600.0))) > 0.2: continue
		# Population demand admits new autonomous train trips; explicit proposals
		# still use their ordinary availability/route checks. Never interrupt a trip
		# already under way just because roster size or demand changed.
		if place.region!=resident.region and kind!="explore" and not encourage_trip:
			continue
		if not place.reserved.is_empty() or not _can_join(resident, place, kind):
			continue
		var distance := point(resident.position).distance_to(point(place.position))
		# While town navigation warms, start a nearby outing rather than reserve
		# a distant unknown route and stand waiting for its entire corridor.
		# Verified longer trips and regional train visits remain candidates.
		if place.region == resident.region and distance > 40 and _leases.has(resident.id) and not state.routes.has(str(resident.place) + ">" + str(place.id)):
			continue
		# Company needs actual company. Count willing, available neighbours before
		# scoring: an empty private spot must not beat a reachable social outing.
		var companions := _choose_companions(resident, {"kind":kind,"place":place.id})
		if kind == "company" and companions.is_empty():
			continue
		var settled:=_settled_place(place,resident.id)
		var returning:=int(resident.get("wander_stops",0))>=3 and settled
		if (place.region==resident.region and distance > 180 and not returning) or distance < float(KINDS[kind].get("min_distance", 0)):
			continue
		if int(resident.get("wander_stops",0))>=3 and not settled:continue
		var distance_cost := minf(distance,180) / (80.0 if place.region == resident.region else 600.0)
		var score := .4 + _roll(resident.id, str(place.id) + kind) * .25 - distance_cost
		score += .45 * int(settled)
		# Home: mildly preferred by day, strongly for rest at night (dev, 2026-09-22).
		if "home:" + str(resident.id) in place.tags:
			score += .2 + (1.0 if kind == "rest" and "HOUSE" in place.tags else .25) * (1.0 - daylight)
		if not companions.is_empty():
			score += needs.social * .8
			# Friends out together keep going together.
			if companions.any(func(peer): return _sticky(resident, peer)): score += .9
		for friend in resident.profile.get("friends",{}):
			var peer:Dictionary=state.residents.get(friend,{})
			if peer.get("region")==place.region and point(peer.position).distance_to(point(place.position))<35:
				score+=maxf(0,float(resident.profile.friends[friend]))*.5
		if place.region!=resident.region:score-=.35
		if encourage_trip and place.region!=resident.region and kind!="explore":score+=1.25
		if town.has_area():
			var here := point(resident.position)
			if not town.has_point(Vector2(here.x, here.z)) and in_town: score += 1.0   # strayed: come home
			if not in_town: score -= .3   # exploring outside town is the exception
		score += float(KINDS[kind].get("night_weight", 0)) * (1.0 - daylight)
		for need in KINDS[kind].needs:
			score += float(needs[need]) * float(KINDS[kind].needs[need])
		score -= .25 * int(kind in resident.recent_kinds)
		score += .2 * int(kind in resident.profile.get("favorites", []))
		if score > best_score:
			best_score = score
			best = {"kind": kind, "place": place.id}
	return best

func _choose_companions(resident: Dictionary, choice: Dictionary) -> Array:
	if not social_enabled:
		return []
	var place: Dictionary = state.places[choice.place]
	# Regional visits join company at the destination; no group waits indefinitely
	# for more seats than the current two-car service offers on one departure.
	if place.region!=resident.region:return []
	var has_friends: bool = resident.get("company_with", []).any(func(peer): return _sticky(resident, peer))
	if not KINDS[choice.kind].company or (float(resident.wants.social) <= .35 and not has_friends):
		return []
	if int(place.capacity) - place.reserved.size() < 2:
		return []
	var candidates: Array = []
	var count := mini(int(resident.profile.get("group_size", 3)), int(place.capacity)) - 1
	# ponytail: one roster scan per invitation; index nearby residents if the
	# 512-resident performance fixture shows this exceeds the simulation budget.
	for peer: Dictionary in state.residents.values():
		if peer.id == resident.id or peer.region != resident.region or not _can_join(peer, place, choice.kind):
			continue
		if not _accepts_invitation(peer, resident):
			continue
		var score := float(resident.profile.get("friends", {}).get(peer.id, 0)) + _roll(resident.id, peer.id) * .3
		if _sticky(resident, peer.id): score += 2.0
		candidates.append({"id": peer.id, "score": score})
		candidates.sort_custom(func(a, b): return a.score > b.score if a.score != b.score else a.id < b.id)
		candidates.resize(mini(count, candidates.size()))
	return candidates.map(func(candidate): return candidate.id)

## `day_busy`: on a step of her day plan (world/life/day); `asleep`: in bed or on her way
## there (world/life/night_rest.gd). Both hold unloaded residents too.
static func _available(resident: Dictionary) -> bool:
	return not resident.paused and resident.activity.is_empty() and not resident.get("day_busy", false) and not resident.get("asleep", false)

static func _supports(place: Dictionary, kind: String) -> bool:
	return place.enabled and KINDS[kind].tags.all(func(tag): return tag in place.tags)

func _can_join(resident: Dictionary, place: Dictionary, kind := "company") -> bool:
	if not _available(resident):
		return false
	# Door interactions require a loaded actor; an offscreen route must not
	# silently bypass a closed or player-held door.
	if "HOUSE" in place.tags and not _leases.has(resident.id):return false
	if _needs_itinerary(resident,place):return _regional_plan(resident,place,kind).get("status")=="ready"
	# A physical navigator requests a path; an unloaded resident in the same region walks there
	# offscreen (a certified route when there is one, otherwise a straight line).
	return (_leases.has(resident.id)
		or point(resident.position).distance_to(point(place.position)) <= float(place.radius)
		or state.routes.has(str(resident.place) + ">" + str(place.id))
		or resident.region == place.region)

func _settled_place(place:Dictionary,id:String)->bool:
	if "settlement" in place.tags or "home:"+id in place.tags:return true
	for peer:Dictionary in state.residents.values():
		var activity:Dictionary=state.activities.get(peer.activity,{})
		if peer.id!=id and peer.region==place.region and activity.get("stage",Stage.SPENDING_TIME)==Stage.SPENDING_TIME and point(peer.position).distance_to(point(place.position))<35:return true
	return false

func _needs_itinerary(resident:Dictionary,place:Dictionary)->bool:
	return resident.region!=place.region or (int(resident.get("wander_stops",0))>=3 and point(resident.position).distance_to(point(place.position))>180)

func _regional_plan(resident:Dictionary,place:Dictionary,kind:String)->Dictionary:
	if not state.places.has(resident.place) or point(resident.position).distance_to(point(state.places[resident.place].position))>2:return {}
	var explore:bool=kind=="explore" or resident.region==place.region
	# A stroll is local leisure; only explicitly choosing exploration permits an overland trip.
	if not explore and not transport_available:return {}
	var plan:=plan_journey(resident.place,place.id,"explore" if explore else "visit")
	if explore and not _settled_place(place,resident.id):return {}
	if explore and resident.region!=place.region and plan_journey(place.id,resident.place,"explore").status!="ready":return {}
	return plan

func _accepts_invitation(resident: Dictionary, leader: Dictionary) -> bool:
	if _sticky(resident, str(leader.id)):
		return resident.region == leader.region and point(resident.position).distance_to(point(leader.position)) <= INVITATION_DISTANCE
	return (resident.region == leader.region
		and point(resident.position).distance_to(point(leader.position)) <= INVITATION_DISTANCE
		and _roll(resident.id, "invite-" + str(leader.id)) <= float(resident.profile.get("sociability", .65)))

func intent(id: String) -> Dictionary:
	if not state.residents.has(id): return {}
	var resident: Dictionary=state.residents[id]
	if resident.paused or resident.activity.is_empty() or not state.activities.has(resident.activity): return {}
	var activity: Dictionary=state.activities[resident.activity]
	var result:Dictionary={"ticket":activity.id,"kind":activity.kind,"stage":activity.stage,"place":activity.place,
		"target":point(activity.targets[id]),"members":activity.members.duplicate(),
		"posture":KINDS[activity.kind].posture if activity.stage==Stage.SPENDING_TIME else "stand"}
	if not resident.journey.is_empty() and resident.journey.has("legs"):
		var route:Dictionary=state.routes.get(resident.journey.route,{})
		if route.is_empty():return {}
		result["mode"]=route.get("mode","walk");result["service"]=route.get("service","");result["arrival"]=route.to
		result.target=point(state.places[route.from if result.mode=="train" else route.to].position)
		if result.mode=="walk" and int(resident.journey.leg)==resident.journey.legs.size()-1:result.target=point(activity.targets[id])
	return result

func take_outcomes() -> Array:
	var result:=_outcomes; _outcomes=[]; return result

func _event(kind: String, activity: Dictionary, witnesses: Array, detail := "") -> void:
	if activity.is_empty(): return
	var event: Dictionary={"id":str(activity.id)+"-"+kind+"-"+str(state.revision),"kind":kind,"activity":activity.kind,
		"place":activity.place,"witnesses":witnesses.duplicate(),"members":activity.members.duplicate(),"time":state.elapsed,"detail":detail}
	state.events.append(event); _outcomes.append(event.duplicate(true)); state.revision+=1
	if state.events.size()>MAX_EVENTS: state.events.pop_front()
	if kind=="completed":
		for id in witnesses:
			state.residents[id].memories.append(event.duplicate(true))
			if state.residents[id].memories.size()>MAX_MEMORIES: state.residents[id].memories.pop_front()

func _roll(id: String, salt: String) -> float:
	return float(posmod(hash(str(int(state.seed))+"/"+id+"/"+salt+"/"+str(int(state.residents.get(id,{}).get("decisions",0)))),1000000))/1000000.0

static func _route_point(route: Dictionary, distance: float) -> Vector3:
	var points: Array=route.get("points",[])
	for i in range(1,points.size()):
		var a:=point(points[i-1]); var b:=point(points[i]); var length:=a.distance_to(b)
		if distance<=length: return a.lerp(b,clampf(distance/maxf(length,.0001),0,1))
		distance-=length
	return point(points[-1]) if not points.is_empty() else Vector3.INF

static func _project(route: Dictionary, position: Vector3) -> float:
	var points: Array=route.get("points",[]); var walked:=0.0; var best:=-1.0; var error:=2.0
	for i in range(1,points.size()):
		var a:=point(points[i-1]); var b:=point(points[i]); var segment:=b-a
		var t:=clampf((position-a).dot(segment)/maxf(segment.length_squared(),.0001),0,1)
		var gap:=position.distance_to(a+segment*t)
		if gap<error: error=gap; best=walked+segment.length()*t
		walked+=segment.length()
	return best

func checkpoint() -> Dictionary:
	var result:=copy_state(state)
	# Physics owns loaded positions. Capture progress once at the save boundary,
	# not every frame, so restoration cannot rewind an observed traveller.
	for id in _leases:
		var resident: Dictionary = result.residents[id]
		if resident.journey.is_empty():
			continue
		if result.routes.get(resident.journey.route,{}).get("mode","walk")=="train":continue
		var progress := _project(result.routes.get(resident.journey.route, {}), point(resident.position))
		if progress < 0:
			resident.journey = {}
		else:
			resident.journey.progress = progress
	result["pending_seconds"]=_accumulator
	result["review_cursor"]=_cursor
	return result

## state.duplicate(true), except that the records (events, each resident's memories) are
## shared, not copied: they are only ever appended or dropped, never edited, so a save worker
## can read them while the simulation carries on. Copying ~16k records stalled every autosave.
static func copy_state(value: Dictionary) -> Dictionary:
	var result := {}
	for key in value:
		var item: Variant = value[key]
		if key == "events" and item is Array: result[key] = item.duplicate()
		elif key == "residents" and item is Dictionary:
			var residents := {}
			for id in item:
				var resident: Variant = item[id]
				if not resident is Dictionary:
					residents[id] = resident.duplicate(true) if resident is Array else resident
					continue
				var copy := {}
				for field in resident:
					var entry: Variant = resident[field]
					if field == "memories" and entry is Array: copy[field] = entry.duplicate()
					elif entry is Dictionary or entry is Array: copy[field] = entry.duplicate(true)
					else: copy[field] = entry
				residents[id] = copy
			result[key] = residents
		elif item is Dictionary or item is Array: result[key] = item.duplicate(true)
		else: result[key] = item
	return result

static func valid(value: Variant, world_id: String) -> bool:
	return CHECKPOINT.valid(value, world_id)

func restore(value: Dictionary) -> bool:
	if not valid(value,str(state.get("world_id",""))): return false
	state=value.duplicate(true)
	for key in ["seed", "serial", "revision"]: state[key] = int(state[key])
	_accumulator=float(state.get("pending_seconds",0)); state.erase("pending_seconds")
	_leases.clear(); _lease_serial+=1; _outcomes.clear(); _cursor=int(state.get("review_cursor",0))
	state.erase("review_cursor")
	# Runtime interaction ownership is reconstructed from live actors, never saved Node state.
	for r: Dictionary in state.residents.values(): r.paused=false
	# Older saves could admit an explicit regional walking visit through a live
	# navigator. Retire that intent rather than silently changing its transport.
	for activity:Dictionary in state.activities.values():
		if activity.kind=="explore":continue
		for id in activity.members:
			var resident:Dictionary=state.residents[id]
			if resident.region!=state.places[activity.place].region and not resident.journey.has("legs"):
				cancel(activity.id,"Regional visit needs a train connection");break
	return true

## Explicit long journeys traverse the certified coarse graph; local stroll selection
## keeps its leisure radius. Callers refine each returned leg through the live navigator.
func plan_journey(from: String, to: String, purpose := "explore") -> Dictionary:
	var planner := preload("res://world/navigation/journey_planner.gd").new()
	for id in state.places: planner.add_place(id, point(state.places[id].position))
	for id in state.routes:
		var edge: Dictionary = state.routes[id]
		var path := PackedVector3Array()
		for value in edge.points: path.append(point(value))
		planner.add_corridor(id, edge.from, edge.to, path, edge.get("mode","walk"), float(edge.get("seconds",maxf(.01,float(edge.length)/2.2))), edge.revision)
	return planner.plan(from,to,["walk"] if purpose=="explore" else ["walk","train"],"train" if purpose=="visit" else "")
