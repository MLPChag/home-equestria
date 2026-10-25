extends RefCounted
## Save-file trust boundary. Validate the complete graph before changing live state.
## Format of the living-world section inside save documents. Bump it when the shape
## changes and add MIGRATIONS[old] = func(state) -> state that returns version old+1.
const VERSION := 1
static var MIGRATIONS: Dictionary = {}
const MAX_EVENTS := 8192
const MAX_MEMORIES := 64
const KINDS := preload("res://world/life/activities.gd").KINDS
const STAGES := ["travelling", "spending_time"]

## Upgrade an older checkpoint one version at a time; anything else is returned as is.
static func migrate(value: Variant) -> Variant:
	if not value is Dictionary: return value
	var result: Dictionary = value
	while _number(result.get("version"), 0, VERSION - 1) and MIGRATIONS.has(int(result.version)):
		var from := int(result.version)
		result = MIGRATIONS[from].call(result.duplicate(true))
		if not _number(result.get("version"), from + 1, VERSION): break
	return result


static func point(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])

static func finite_position(value: Variant) -> bool:
	return value is Array and value.size() == 3 and value.all(func(n): return _number(n, -99999, 99999))

static func _number(value: Variant, low := 0.0, high := 1.0e15) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value >= low and value <= high

static func _name(value: Variant) -> bool:
	return value is String and not value.is_empty() and value.length() <= 160

static func _event_valid(event: Variant) -> bool:
	if not event is Dictionary:
		return false
	for key in ["id", "kind", "activity", "place"]:
		if not _name(event.get(key)):
			return false
	if not _number(event.get("time")) or not event.get("detail") is String:
		return false
	for key in ["members", "witnesses"]:
		if not event.get(key) is Array or event[key].size() > 6:
			return false
		for id in event[key]:
			if not _name(id):
				return false
	return true

static func _profile_valid(profile: Variant) -> bool:
	if not profile is Dictionary:
		return false
	if not _number(profile.get("sociability", .65), 0, 1) or not _number(profile.get("travel_speed", 2.2), .1, 20):
		return false
	if not _number(profile.get("group_size", 3), 2, 6):
		return false
	if not profile.get("favorites", []) is Array or not profile.get("friends", {}) is Dictionary:
		return false
	for kind in profile.get("favorites", []):
		if not KINDS.has(kind):
			return false
	for id in profile.get("friends", {}):
		if not _name(id) or not _number(profile.friends[id], -1, 1):
			return false
	return true

static func valid(value: Variant, world_id: String) -> bool:
	if not value is Dictionary or value.get("version") != VERSION or value.get("world_id") != world_id:
		return false
	if value.has("travel_clock"):
		var clock:Variant=value.travel_clock
		if not clock is Dictionary or not _number(clock.get("hours")) or not _number(clock.get("daylight"),0,1):return false
	for key in ["residents", "places", "routes", "activities"]:
		if not value.get(key) is Dictionary or value[key].size() > 4096:
			return false
	for key in ["elapsed", "seed", "revision", "serial", "pending_seconds", "review_cursor"]:
		if not _number(value.get(key)):
			return false
	for key in ["seed", "revision", "serial", "review_cursor"]:
		if value[key] != floor(value[key]):
			return false
	if not value.get("events") is Array or value.events.size() > MAX_EVENTS:
		return false
	for event in value.events:
		if not _event_valid(event):
			return false
	for id in value.places:
		var place: Variant = value.places[id]
		if not _name(id) or not place is Dictionary or place.get("id") != id:
			return false
		if not _name(place.get("region")) or not finite_position(place.get("position")):
			return false
		if not _number(place.get("capacity"), 1, 6) or place.capacity != floor(place.capacity):
			return false
		if not _number(place.get("radius"), 0, 20):
			return false
		if not place.get("enabled") is bool or not place.get("tags") is Array:
			return false
		if not place.get("reserved") is Array or place.reserved.size() > place.capacity:
			return false
		if not place.get("slots") is Array or not place.slots.all(finite_position):
			return false
		if not place.slots.is_empty() and place.slots.size() != place.capacity:
			return false
		for member in place.reserved:
			if not value.residents.has(member):
				return false
	for id in value.routes:
		var route: Variant = value.routes[id]
		if not route is Dictionary or not value.places.has(route.get("from")) or not value.places.has(route.get("to")):
			return false
		if id != str(route.from) + ">" + str(route.to) or not _name(route.get("revision")):
			return false
		if route.get("mode","walk") not in ["walk","train"]:return false
		if route.get("mode")=="train" and (not _name(route.get("service")) or not _number(route.get("seconds"),.01,100000)):return false
		if not route.get("points") is Array or route.points.size() < 2 or route.points.size() > 8192:
			return false
		if not route.points.all(finite_position) or not _number(route.get("length"), 0, 100000):
			return false
		var length := 0.0
		for i in range(1, route.points.size()):
			length += point(route.points[i - 1]).distance_to(point(route.points[i]))
		if absf(length - float(route.length)) > .01:
			return false
		if point(route.points[0]).distance_to(point(value.places[route.from].position)) > 2:
			return false
		if point(route.points[-1]).distance_to(point(value.places[route.to].position)) > 2:
			return false
	for id in value.residents:
		var resident: Variant = value.residents[id]
		if not _name(id) or not resident is Dictionary or resident.get("id") != id:
			return false
		for key in ["home_region", "region"]:
			if not _name(resident.get(key)):
				return false
		if not finite_position(resident.get("position")) or not finite_position(resident.get("rotation")):
			return false
		if not _profile_valid(resident.get("profile")) or not resident.get("wants") is Dictionary:
			return false
		for need in ["social", "energy", "curiosity"]:
			if not _number(resident.wants.get(need), 0, 1):
				return false
		for key in ["next_review", "decisions", "choice_cursor"]:
			if not _number(resident.get(key)):
				return false
		if not _number(resident.get("wander_stops",0),0,100000) or resident.get("wander_stops",0)!=floor(resident.get("wander_stops",0)):return false
		if resident.has("last_train_arrival") and not _number(resident.last_train_arrival):return false
		if not resident.get("paused") is bool or not resident.get("last_reason") is String:
			return false
		if not resident.get("recent_kinds") is Array or resident.recent_kinds.size() > 4:
			return false
		if not resident.get("memories") is Array or resident.memories.size() > MAX_MEMORIES:
			return false
		for event in resident.memories:
			if not _event_valid(event):
				return false
		if not resident.get("activity") is String or not resident.get("place") is String:
			return false
		if not resident.activity.is_empty() and not value.activities.has(resident.activity):
			return false
		if not resident.place.is_empty() and not value.places.has(resident.place):
			return false
		var journey: Variant = resident.get("journey")
		if not journey is Dictionary:
			return false
		if journey.get("direct", false):
			# Offscreen straight-line walk (living_world.direct_journey).
			if resident.activity.is_empty() or not finite_position(journey.get("from")) or not finite_position(journey.get("to")):
				return false
			if not _number(journey.get("length"), .01, 100000) or not _number(journey.get("progress"), 0, float(journey.length)) or not _number(journey.get("speed"), .1, 20):
				return false
		elif not journey.is_empty():
			if resident.activity.is_empty() or not value.routes.has(journey.get("route")):
				return false
			if not _number(journey.get("progress"), 0, float(value.routes[journey.route].length)) or not _number(journey.get("speed"), .1, 20):
				return false
			if journey.has("legs"):
				if not journey.legs is Array or journey.legs.is_empty() or journey.legs.size()>128:return false
				if not _number(journey.get("leg"),0,journey.legs.size()-1) or journey.leg!=floor(journey.leg):return false
				if not journey.get("aboard") is bool or journey.legs[int(journey.leg)]!=journey.route:return false
				for i in journey.legs.size():
					if not value.routes.has(journey.legs[i]):return false
					if i>0 and value.routes[journey.legs[i-1]].to!=value.routes[journey.legs[i]].from:return false
				var planned:Variant=value.activities[resident.activity]
				if not planned is Dictionary or value.routes[journey.legs[-1]].to!=planned.get("place"):return false
				if journey.aboard and value.routes[journey.route].get("mode")!="train":return false
	for id in value.activities:
		var activity: Variant = value.activities[id]
		if not activity is Dictionary or activity.get("id") != id or not KINDS.has(activity.get("kind")):
			return false
		if not value.places.has(activity.get("place")) or activity.get("stage") not in STAGES:
			return false
		if not activity.get("members") is Array or activity.members.is_empty() or activity.members.size() > 6:
			return false
		if not activity.get("arrived") is Array or not activity.get("targets") is Dictionary:
			return false
		for key in ["created", "remaining", "deadline"]:
			if not _number(activity.get(key)):
				return false
		if not _number(activity.get("started"), -1):
			return false
		if activity.members != value.places[activity.place].reserved:
			return false
		var unique := {}
		for member in activity.members:
			if unique.has(member) or not value.residents.has(member):
				return false
			unique[member] = true
			if value.residents[member].activity != id or not finite_position(activity.targets.get(member)):
				return false
		if not activity.arrived.all(func(member): return unique.has(member)):
			return false
	for resident in value.residents.values():
		if not resident.activity.is_empty() and resident.id not in value.activities[resident.activity].members:
			return false
	for id in value.places:
		for member in value.places[id].reserved:
			var ticket: String = value.residents[member].activity
			if ticket.is_empty() or value.activities[ticket].place != id:
				return false
	return true
