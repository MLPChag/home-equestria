extends RefCounted
## A resident's essence (dev 2026-09-26: "their MODEL should unload but their essence continues to
## live and exist without costing gpu"). Her record in the living world core (position, outing,
## day plan, sleep) keeps going while no body is loaded: world/life/day/day_runner.gd runs her day
## plan on it, world/life/night_rest.gd puts it to bed, the core walks it to outings. When she
## comes back into range, the population spawns her body where the essence has got to.
## Nothing here touches the scene or the GPU.

const CORE := preload("res://world/life/living_world.gd")
const WALK_SPEED := 1.8      # m/s along the ground, before the detour allowance
const FLY_SPEED := 12.0      # m/s for a pegasus going somewhere far or up to a cloud

static func core(population: Node) -> RefCounted:
	if not is_instance_valid(population): return null
	var life: Variant = population.get("life")
	if not is_instance_valid(life) or not "core" in life: return null
	return life.core

## Her record in the living world, or {} (no life simulation / unknown resident).
static func record(population: Node, id: String) -> Dictionary:
	var c: RefCounted = core(population)
	return c.state.get("residents", {}).get(id, {}) if c != null else {}

static func position(resident: Dictionary) -> Vector3:
	return CORE.point(resident.position) if not resident.is_empty() else Vector3.INF

## No body in the scene: not out as a live actor, not away on a princess visit, not on the train
## (those two own her while they last). Nor about to come back where a loaded save had her
## (pony_population.resuming): her essence waits rather than walking off before she spawns.
static func unloaded(population: Node, id: String) -> bool:
	if population.live.has(id) or population.visiting.has(id): return false
	if population.has_method("resuming") and population.resuming(id): return false
	var host: Variant = population.get("host")
	if is_instance_valid(host) and "railway" in host and is_instance_valid(host.railway) and host.railway.owns(id): return false
	return true

## Move her essence toward `to` for `dt` seconds (straight line with the core's detour allowance,
## kept on the terrain); true once she is there.
static func walk(resident: Dictionary, to: Vector3, speed: float, dt: float) -> bool:
	var from := CORE.point(resident.position)
	var flat := Vector2(to.x - from.x, to.z - from.z)
	var step := speed * dt / CORE.DETOUR
	if flat.length() <= step:
		resident.position = CORE.vector(to)
		return true
	var ahead := flat.normalized() * step
	var at := Vector3(from.x + ahead.x, to.y, from.z + ahead.y)
	if is_instance_valid(WorldTerrain.instance):
		var h: float = WorldTerrain.instance.height_at(at)
		if is_finite(h): at.y = h
	resident.position = CORE.vector(at)
	return false

## End whatever living-world outing she is on (her plan or bedtime comes first).
static func leave_outing(population: Node, id: String, reason: String) -> void:
	var c: RefCounted = core(population)
	var resident := record(population, id)
	if c != null and not resident.is_empty() and not str(resident.activity).is_empty():
		c.cancel(resident.activity, reason)

## Places seen while their zone was loaded, so an unloaded pony can still head for Sugarcube
## Corner or her house while the player is in Canterlot. Saved with the living world.
static func remember(population: Node, key: String, at: Vector3) -> void:
	var c: RefCounted = core(population)
	if c == null or not at.is_finite(): return
	if not c.state.has("known_places"): c.state["known_places"] = {}
	c.state.known_places[key] = CORE.vector(at)

static func known(population: Node, key: String) -> Vector3:
	var c: RefCounted = core(population)
	if c == null: return Vector3.INF
	var value: Variant = c.state.get("known_places", {}).get(key)
	return CORE.point(value) if CORE.finite_position(value) else Vector3.INF

## Where she sleeps: inside her house (remembered once it has been loaded), else her home spot.
static func home(population: Node, id: String) -> Vector3:
	if population.has_method("is_overnight_visitor") and population.is_overnight_visitor(id):
		return population.home_position(id, true)
	var house: Node3D = population.home_house(id) if population.has_method("home_house") else null
	if house != null:
		remember(population, "home:" + id, house.center())
		return house.center()
	var at := known(population, "home:" + id)
	if at.is_finite(): return at
	return population.home_position(id, true) if population.has_method("home_position") else Vector3.INF
