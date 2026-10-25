extends Node
## Visits change membership only beneath PlayerSleep's opaque cover. Bodies still use the
## ordinary population streamer; the saved life and permanent roster identity stay the same.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const CONFIG := preload("res://world/population/pony_population_config.gd")
const DISTRIBUTION := preload("res://world/population/population_distribution.gd")
const DESTINATION := "ponyville"
## These towns currently have no playable settlement. Remove an origin when it opens;
## an authored native zone also makes it ineligible, whether currently streamed in or not.
const ORIGINS := ["canterlot", "cloudsdale", "appleloosa", "los_pegasus", "dodge_city",
	"crystal_empire", "rock_farm", "starlights_village"]
const MAX_VISITORS := 3
const ARRIVAL_CHANCE := 0.4
const PLACEMENT_MSEC := 450
const KEY := "overnight_visitors"
var population: Node
var context: Node
var data: Dictionary = {}
var preparing := false
var _serial := 0
var _prepared: PackedScene
var _held: Array[Resource] = []
var _pending: Dictionary = {}
var _placement_owner: Node

func setup(people: Node) -> void:
	population = people
	context = population.host.get("world_context")
	if is_instance_valid(context) and context.has_signal("reopened"):
		context.reopened.connect(_reopened)
	_reopened()

func _reopened(_world_id := "") -> void:
	cancel_preparation()
	var value: Variant = context.state.get(KEY, {}) if is_instance_valid(context) else {}
	data = normalized(value)
	if is_instance_valid(context): context.state[KEY] = data
	if is_instance_valid(population.life): population.life._roster_stamp = 0

static func normalized(value: Variant) -> Dictionary:
	var result := {"version": 1, "last_day": -1, "active": {}, "cooldown": {}}
	if not value is Dictionary: return result
	var last_day: Variant = value.get("last_day", -1)
	if (last_day is int or last_day is float) and is_finite(float(last_day)): result.last_day = int(last_day)
	var rows: Variant = value.get("active", {})
	if rows is Dictionary:
		for id: String in rows:
			var row: Variant = rows[id]
			if not row is Dictionary or not row.get("home") is String: continue
			var point: Variant = row.get("lodging")
			if not point is Array or point.size() != 3: continue
			var valid := true
			for coordinate: Variant in point:
				if not (coordinate is float or coordinate is int) or not is_finite(float(coordinate)): valid = false
			if not valid: continue
			if not (row.get("arrived") is int or row.get("arrived") is float) or not (row.get("leaves") is int or row.get("leaves") is float): continue
			if not is_finite(float(row.arrived)) or not is_finite(float(row.leaves)): continue
			var start := int(row.get("arrived", -1)); var end := int(row.get("leaves", -1))
			if start < 0 or end <= start: continue
			result.active[id] = {"home": row.home, "arrived": start, "leaves": end, "lodging": point.duplicate()}
	var cooldown: Variant = value.get("cooldown", {})
	if cooldown is Dictionary:
		for id: String in cooldown:
			if (cooldown[id] is int or cooldown[id] is float) and is_finite(float(cooldown[id])): result.cooldown[id] = int(cooldown[id])
	return result

func active(id: String) -> bool:
	return data.get("active", {}).has(id)

func lodging(id: String) -> Vector3:
	var row: Dictionary = data.get("active", {}).get(id, {})
	if row.is_empty(): return Vector3.INF
	var point: Array = row.lodging
	return Vector3(float(point[0]), float(point[1]), float(point[2]))

static func unimplemented(region_id: String) -> bool:
	var region := WorldLayout.region(region_id)
	return region_id in ORIGINS and not region.is_empty() and str(region.get("zone", "")).is_empty()

func _protected(id: String) -> bool:
	if population.visiting.has(id) or population._spawning == id: return true
	var host: Node = population.host
	for transport: String in ["railway", "balloon"]:
		var transport_owner: Variant = host.get(transport) if transport in host else null
		if is_instance_valid(transport_owner) and transport_owner.owns(id): return true
	var day: Node = host.get_node_or_null("DayRunner")
	if day != null and day.held.has(id): return true
	# A checkpoint can carry a companion command before her body has streamed back in.
	if population.saved.get(id, {}).get("resume", {}).has("follow"): return true
	var actor: Node3D = population.live.get(id, {}).get("actor")
	if not is_instance_valid(actor): return false
	if host.has_method("_population_busy") and host._population_busy(actor): return true
	if actor.has_method("action_interruption_reason"):
		var reason: String = actor.action_interruption_reason()
		if reason != "" and reason != "Waiting for safe ground support": return true
	if actor.get("flight") != null and actor.flight.active(): return true
	if actor.has_meta("seated") or actor.get_node_or_null("SharedNapCompany") != null: return true
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null: return true
	if nav.get("reserved_by") != null and str(nav.reserved_by) != "": return true
	var owner := str(nav.command_owner)
	return not (owner.is_empty() or owner.begins_with("life:") or owner.begins_with("day:") or owner.begins_with("social:") or owner.begins_with("sleep:") or owner.begins_with("weather:"))

## At most one roll for a new calendar day, even after long skips or clock rollback.
## Expired protected guests may leave on a later nap; arriving still requires an overnight.
func plan(before_day: int, wake_day: int) -> Dictionary:
	var result := {"day": wake_day, "epoch": int(context.epoch) if is_instance_valid(context) else -1,
		"departures": [], "arrival": "", "home": "", "position": Vector3.INF, "stay": 0, "new_day": false}
	if not is_instance_valid(context): return result
	for id: String in data.active:
		var row: Dictionary = data.active[id]
		if (wake_day >= int(row.leaves) or population.config.assignments.get(id, "") != row.home) and not _protected(id):
			result.departures.append(id)
	result.new_day = wake_day > before_day and wake_day > int(data.last_day)
	if not result.new_day or data.active.size() - result.departures.size() >= MAX_VISITORS: return result
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(context.path) + ":overnight-visitors:" + str(wake_day))
	if rng.randf() >= ARRIVAL_CHANCE: return result
	var candidates: Array[String] = []
	for id: String in population.config.assignments:
		var home: String = population.config.assignments[id]
		if not unimplemented(home) or not population.available.has(id): continue
		if CONFIG.PRINCESSES.has(id) or CONFIG.FILLIES.has(id) or active(id) or population.live.has(id): continue
		if int(data.cooldown.get(id, -1)) >= wake_day or _protected(id): continue
		candidates.append(id)
	if candidates.is_empty(): return result
	candidates.sort()
	var id: String = candidates[rng.randi_range(0, candidates.size() - 1)]
	var positions: Dictionary = DISTRIBUTION.plan(WorldLayout.region(DESTINATION), [id])
	result.arrival = id; result.home = str(population.config.assignments[id])
	result.position = positions.get(id, Vector3.INF); result.stay = rng.randi_range(2, 4)
	if is_instance_valid(WorldTerrain.instance) and result.position.is_finite():
		var height: float = WorldTerrain.instance.height_at(result.position)
		if is_finite(height): result.position.y = height + .02
	return result

func _current(request: Dictionary, serial: int) -> bool:
	var host: Node = population.host if is_instance_valid(population) else null
	return serial == _serial and not SHUTDOWN.active and is_inside_tree() and not is_queued_for_deletion() and is_instance_valid(host) and host.is_inside_tree() and not host.is_queued_for_deletion() and is_instance_valid(context) and int(context.epoch) == int(request.epoch)

## Runs concurrently with the fade. Only ready resources are retrieved; a slow disk merely
## means no arrival this night. Population owns any unfinished request until its usual cleanup.
func prepare(request: Dictionary, deadline_msec: int) -> void:
	cancel_preparation()
	preparing = true
	var serial := _serial
	var id := str(request.arrival)
	if id.is_empty() or not _near(request.position) or population._spawning != "": return
	var path: String = population.available.get(id, "")
	if path.is_empty(): return
	var queue: Array[String] = [path]
	while not queue.is_empty() and Time.get_ticks_msec() < deadline_msec:
		var current_path: String = queue.pop_front()
		var error := OK if population._prefetch.has(current_path) else ResourceLoader.load_threaded_request(current_path)
		if error != OK: return
		population._prefetch.erase(current_path)
		_pending[current_path] = true
		while ResourceLoader.load_threaded_get_status(current_path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			if not _current(request, serial) or Time.get_ticks_msec() >= deadline_msec: return
			if not await SHUTDOWN.frame(self): return
		if not _current(request, serial): return
		if ResourceLoader.load_threaded_get_status(current_path) != ResourceLoader.THREAD_LOAD_LOADED: return
		var resource: Resource = ResourceLoader.load_threaded_get(current_path)
		_pending.erase(current_path)
		if current_path == path:
			if not resource is PackedScene: return
			_prepared = resource
			queue.append_array(population._rig_dependencies(_prepared))
		else: _held.append(resource)
	if not queue.is_empty(): _prepared = null
	request["ready"] = queue.is_empty() and _pending.is_empty() and _prepared != null

func _near(at: Vector3) -> bool:
	return is_instance_valid(population.anchor) and population.flat_distance(at, population.anchor.global_position) < population.ACTIVATE_DISTANCE

## PlayerSleep calls this only while fully opaque, and awaits placement before reopening.
## The caller's cover is checked here as well so unrelated scripts cannot silently move guests.
func commit(request: Dictionary, cover: Node) -> void:
	var serial := _serial
	if not _current(request, serial) or not population.host.get("player_sleeping") or not is_instance_valid(cover) or float(cover.get("_closed")) < 1.0: return
	var fresh_day := bool(request.new_day) and int(request.day) > int(data.last_day)
	if request.new_day: data.last_day = maxi(int(data.last_day), int(request.day))
	for id: String in request.departures:
		if not data.active.has(id) or _protected(id): continue
		if int(data.active[id].leaves) > int(request.day) and population.config.assignments.get(id, "") == data.active[id].home: continue
		_reset_routine(id)
		var actor: Node3D = population.live.get(id, {}).get("actor")
		if is_instance_valid(actor): population.host._despawn_resident(id, actor)
		population.live.erase(id); population.saved.erase(id)
		data.active.erase(id); data.cooldown[id] = int(request.day) + 3
		_relocate_life(id)
		context.record("visit", "You finished your visit to Ponyville and went home overnight.", [id], [id], "overnight-depart:%d:%s" % [int(request.day), id])
	var id := str(request.arrival)
	if fresh_day and data.active.size() < MAX_VISITORS and not id.is_empty() and not active(id) and not population.live.has(id) and not _protected(id) and population.config.assignments.get(id, "") == request.home and unimplemented(request.home):
		var actor: Node3D
		var near := _near(request.position)
		var cap: int = population.nearby_limit()
		if near and request.get("ready", false) and (cap == 0 or population.live.size() < cap):
			var owner := Node.new(); owner.name = "CoveredVisitorArrival"; add_child(owner)
			_placement_owner = owner
			owner.set_meta("resident_spawn_deadline_msec", Time.get_ticks_msec() + PLACEMENT_MSEC)
			actor = await population.host._spawn_resident(id, request.home, request.position, _prepared, DESTINATION, owner)
			if is_instance_valid(owner): owner.queue_free()
			_placement_owner = null
		if not _current(request, serial):
			if is_instance_valid(actor) and is_instance_valid(population.host): population.host._despawn_resident(id, actor)
			return
		if not near or is_instance_valid(actor):
			_reset_routine(id)
			var at: Vector3 = actor.global_position if is_instance_valid(actor) else request.position
			data.active[id] = {"home": request.home, "arrived": int(request.day), "leaves": int(request.day) + int(request.stay), "lodging": [at.x, at.y, at.z]}
			population.saved.erase(id)
			_relocate_life(id)
			var origin := str(WorldLayout.region(request.home).get("name", request.home))
			context.record("visit", "You came from %s to visit Ponyville for a few days, arriving overnight." % origin, [id], [id], "overnight-arrive:%d:%s" % [int(request.day), id])
			if is_instance_valid(actor):
				population.live[id] = {"actor": actor, "region": DESTINATION}
				if is_instance_valid(population.life): population.life.attach(id, actor)
	context._changed()
	cancel_preparation()

func _reset_routine(id: String) -> void:
	population.resumed_plans.erase(id)
	var day: Node = population.host.get_node_or_null("DayRunner")
	if day != null: day.changed_residence(id)
	var night: Node = population.host.get_node_or_null("NightRest")
	var actor: Node3D = population.live.get(id, {}).get("actor")
	if night != null and is_instance_valid(actor): night.release_for_recovery(id, actor)

func _relocate_life(_id: String) -> void:
	if not is_instance_valid(population.life): return
	population.life._roster_stamp = 0
	population.life._sync_roster()

func cancel_preparation() -> void:
	_serial += 1
	preparing = false
	if is_instance_valid(_placement_owner): _placement_owner.queue_free()
	_placement_owner = null
	_prepared = null; _held.clear()
	if is_instance_valid(population):
		for path: String in _pending:
			if population._closing:
				var state := ResourceLoader.load_threaded_get_status(path)
				if state in [ResourceLoader.THREAD_LOAD_IN_PROGRESS, ResourceLoader.THREAD_LOAD_LOADED]: ResourceLoader.load_threaded_get(path)
			else: population._prefetch[path] = true
	_pending.clear()

func _exit_tree() -> void:
	cancel_preparation()
