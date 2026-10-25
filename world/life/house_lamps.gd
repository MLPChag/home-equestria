extends Node
## Household lamps (dev 2026-10-17: "add the ability for ponies to turn off/on their lamps at
## times in the day/night that are apt randomly if they're home and if their lamp is on it'll have
## a light in the window and they like to shut it off before going to bed").
## Every few seconds each Ponyville house works out whether somepony who lives there wants a lamp
## on: she is home, awake, it is getting dark (each pony has her own threshold each evening, so
## lamps come on one by one through the dusk) and it is not yet her time to shut it off, a little
## before her bedtime (night_rest.gd bedtime). An early riser lights it again before dawn until the
## morning is bright enough. Houses nopony lives in stay dark.
## A house's state shows two ways: far away its window cards glow or not (window_glow.gd), close
## up its real indoor lamps (kit_lamp.gd household mode) switch. When the change happens with one
## of its ponies loaded at home and free, she walks to a lamp and switches it herself (a unicorn's
## magic glows on it); otherwise the lamps just click over.

const ESSENCE := preload("res://world/life/essence.gd")
const NIGHT_REST := preload("res://world/life/night_rest.gd")
const GLOW := preload("res://world/buildings/window_glow/window_glow.gd")
const MAGIC := preload("res://world/characters/magic/unicorn_magic.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const CHECK := 2.0
const OWNER := "lamp:"
## Each pony's daylight level for lighting up this evening is drawn from this range (sky daylight:
## 1 day, 0 night); the morning switch-off uses the same draw.
const DUSK_RANGE := Vector2(0.22, 0.6)
## She shuts her lamps off this many hours before her bedtime (drawn per pony per night).
const BEFORE_BED := Vector2(0.08, 0.45)
## Essence counts as home within this distance of her remembered house.
const HOME_RADIUS := 7.0
## The walk to a lamp gives up after this long and the lamp switches anyway.
const WALK_SECONDS := 20.0

var population: Node
var night_rest: Node
var clock: Node
var _timer := 0.0
var _beat := 0.0
var _lit: Dictionary = {}       # place id -> bool (current household state)
var _walks: Dictionary = {}     # resident id -> {place, lit, lamp, t}
var _synced: Dictionary = {}    # lamp -> true once it has taken its household's state

func setup(people: Node, rest: Node) -> void:
	population = people
	night_rest = rest
	clock = get_node_or_null("/root/TimeOfDay")
	add_to_group("house_lamps")

func _process(delta: float) -> void:
	# A quarter-second beat: lamp walks are checked on it, household state every CHECK.
	_beat += delta
	if _beat < 0.25: return
	delta = _beat; _beat = 0.0
	if not _walks.is_empty(): _step_walks(delta)
	_timer -= delta
	if _timer > 0.0 or not is_instance_valid(population) or clock == null: return
	_timer = CHECK
	var wanted := {}
	for id: String in population.houses:
		if not population.config.assignments.has(id): continue
		var place: String = population.houses[id]
		if place.is_empty(): continue
		if not wanted.has(place): wanted[place] = false
		if not wanted[place] and wants_light(id, place): wanted[place] = true
	for place: String in wanted:
		var on: bool = wanted[place]
		if _lit.has(place) and _lit[place] == on: continue
		var first := not _lit.has(place)
		_lit[place] = on
		_switch(place, on, first)
	# Lamps that came in with a house since the last look take its current state.
	for lamp: Node in get_tree().get_nodes_in_group("household_lamps"):
		if lamp is Node3D and not _synced.has(lamp):
			_synced[lamp] = true
			sync_lamp(lamp as Node3D)
	if _synced.size() > 4096: _synced.clear()

## True while the house's state is known and lit (window_glow.gd and new lamps ask).
func lit(place: String) -> bool:
	return bool(_lit.get(place, false))

## A pony wants a lamp on: home, awake, after her own dusk and before her shut-off time, or up
## before a dark dawn.
func wants_light(id: String, place: String) -> bool:
	if not _home(id, place) or _asleep(id): return false
	var h := float(clock.hours)
	var day := int(clock.day)
	var daylight: float = float(clock.daylight()) if clock.has_method("daylight") else 1.0
	var dusk := lerpf(DUSK_RANGE.x, DUSK_RANGE.y, _roll(id, day, "dusk"))
	if daylight >= dusk: return false
	# Evening: off a little before bed. A night counts from 16:00 to 16:00 (night_rest.gd).
	var night := day - (1 if h < 16.0 else 0)
	var times: Vector2 = NIGHT_REST.bedtime(id, night)
	var off_at := times.x - lerpf(BEFORE_BED.x, BEFORE_BED.y, _roll(id, night, "bed"))
	var bed_evening: bool = times.x > times.y   # an ordinary evening bedtime, wake next morning
	if bed_evening:
		if h >= 16.0: return h < off_at
		return h >= times.y   # up before dawn
	# A night owl sleeps after midnight: lamps on through the evening until just before bed.
	if h >= 16.0: return true
	return h < off_at or h >= times.y

## Deterministic per pony and day: the same evening plays the same way after a reload.
static func _roll(id: String, day: int, what: String) -> float:
	return float(absi(hash("lamps:%s:%d:%s" % [id, day, what])) % 1000) / 1000.0

func _asleep(id: String) -> bool:
	if is_instance_valid(night_rest) and night_rest.is_asleep(id): return true
	return bool(ESSENCE.record(population, id).get("asleep", false))

func _home(id: String, place: String) -> bool:
	var actor := _body(id)
	if actor != null:
		if str(actor.get_meta("house_id", "")) == place: return true
		var house: Node3D = population.home_house(id)
		return house != null and house.contains(actor.global_position)
	if not ESSENCE.unloaded(population, id): return false   # visiting, on the train
	var resident := ESSENCE.record(population, id)
	if resident.is_empty(): return false
	var at := ESSENCE.position(resident)
	var home := ESSENCE.home(population, id)
	return at.is_finite() and home.is_finite() and at.distance_to(home) < HOME_RADIUS

func _body(id: String) -> Node3D:
	var actor: Variant = population.live.get(id, {}).get("actor")
	return actor if actor is Node3D and is_instance_valid(actor) and (actor as Node3D).is_inside_tree() else null

func _house(place: String) -> Node3D:
	for house: Node3D in get_tree().get_nodes_in_group("house_interiors"):
		if house.place_id() == place: return house
	return null

## Household lamps of a loaded house (kit_lamp.gd joins "household_lamps").
func _lamps(house: Node3D) -> Array[Node3D]:
	var out: Array[Node3D] = []
	if house == null: return out
	for lamp: Node in get_tree().get_nodes_in_group("household_lamps"):
		if lamp is Node3D and house.is_ancestor_of(lamp): out.append(lamp as Node3D)
	return out

## The house changes state. Far: its windows. Near: a pony at home goes and switches a lamp, or
## the lamps click over by themselves when nopony can (first reading at load: no clicks).
func _switch(place: String, on: bool, first: bool) -> void:
	GLOW.set_house_lit(place, on)
	var house := _house(place)
	var lamps := _lamps(house)
	if lamps.is_empty() or first:
		for lamp: Node3D in lamps: lamp.call("set_household", on)
		return
	for id: String in population.residents_of(place):
		if _walks.has(id): continue
		var actor := _body(id)
		if actor == null or not house.contains(actor.global_position) or not _free(actor): continue
		var lamp := _nearest(lamps, actor.global_position)
		var nav: Node = actor.get_node_or_null("Navigator")
		nav.stay()
		nav.command_owner = OWNER + id
		nav.go_to(_beside(lamp, actor.global_position), nav.Gait.WALK)
		_walks[id] = {"place": place, "lit": on, "lamp": lamp, "t": 0.0, "actor": actor}
		return
	_apply(lamps, on, null)

func _nearest(lamps: Array[Node3D], at: Vector3) -> Node3D:
	var best: Node3D = lamps[0]
	for lamp: Node3D in lamps:
		if lamp.global_position.distance_to(at) < best.global_position.distance_to(at): best = lamp
	return best

## A floor point a pony's length from the lamp, on her side of it.
static func _beside(lamp: Node3D, from: Vector3) -> Vector3:
	var at := lamp.global_position
	var away := Vector3(from.x - at.x, 0.0, from.z - at.z)
	away = away.normalized() if away.length() > 0.1 else Vector3.FORWARD
	var p := at + away * 0.8
	p.y = from.y
	return p

## Free to go and switch a lamp: only her own routine has her (day plan, living world, idle).
static func _free(actor: Node3D) -> bool:
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null or str(nav.get("reserved_by")) != "" or is_instance_valid(nav.get("_follow_target")): return false
	var owner := str(nav.command_owner)
	if owner != "" and not (owner.begins_with("day:") or owner.begins_with("life:") or owner.begins_with("social:")): return false
	if bool(actor.get("sleeping")) or bool(actor.get("motion_paused")) or actor.is_held(): return false
	if is_instance_valid(actor.get("conversation_target")) or (actor.has_method("is_speaking") and actor.is_speaking()): return false
	return true

func _step_walks(delta: float) -> void:
	for id: String in _walks.keys():
		var walk: Dictionary = _walks[id]
		walk.t = float(walk.t) + delta
		var actor: Node3D = walk.actor if is_instance_valid(walk.actor) else null
		var nav: Node = actor.get_node_or_null("Navigator") if actor != null else null
		var lamp: Node3D = walk.lamp if is_instance_valid(walk.lamp) else null
		var mine: bool = nav != null and str(nav.command_owner) == OWNER + id
		var there: bool = mine and lamp != null and Vector2(actor.global_position.x - lamp.global_position.x, actor.global_position.z - lamp.global_position.z).length() < 1.3
		if not (there or not mine or lamp == null or float(walk.t) > WALK_SECONDS or nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]): continue
		_walks.erase(id)
		# The house may have changed its mind meanwhile (she went to bed, somepony came home):
		# the newest state wins.
		_apply(_lamps(_house(str(walk.place))), lit(str(walk.place)), actor if there else null)
		if mine:
			nav.stay()
			nav.command_owner = ""

## Switches the lamps; `by` is the pony who reached one (a unicorn's magic glows on it).
func _apply(lamps: Array[Node3D], on: bool, by: Node3D) -> void:
	var horn: bool = by != null and by.get("identity") != null and by.identity.has_method("has_horn") and by.identity.has_horn()
	for lamp: Node3D in lamps:
		if bool(lamp.get("lit")) == on: continue
		lamp.call("set_household", on)
		SOUNDS.play_at(lamp, "prop_lamp")
		if horn: MAGIC.burst(lamp, Vector3.UP * 0.3, MAGIC.color_for(by.identity), 0.8, 0.15)

## A lamp that just loaded with its house takes the household's current state.
func sync_lamp(lamp: Node3D) -> void:
	var house := lamp.get_parent() as Node
	while house != null and not house.is_in_group("house_interiors"): house = house.get_parent()
	if house == null: return
	var place: String = house.place_id()
	# Nopony lives here: dark unless the player switches a lamp on.
	if population.residents_of(place).is_empty(): lamp.call("set_household", false)
	elif _lit.has(place): lamp.call("set_household", bool(_lit[place]))
