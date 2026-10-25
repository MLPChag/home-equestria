extends RefCounted
## The --character / --roster lab path: scatter chosen ponies on the walk grid around the plaza instead of the population.
## Split out of game.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning game node; shared state stays there.

const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const ROSTER_PLACEMENT := preload("res://world/navigation/roster_placement.gd")
const PONY := preload("res://world/characters/pony.gd")
const NAVIGATOR := preload("res://world/characters/navigation/pony_navigator.gd")
## The Mane 6 (hybrid scenes) that stand in town by default; --roster a,b,c picks a subset,
## --character <path> spawns one legacy scene instead.
const ROSTER := {
	"rainbow_dash": "res://world/characters/hybrid_mare/hybrid_mare.tscn",
	"twilight_sparkle": "res://world/characters/mane6/twilight_sparkle.tscn",
	"rarity": "res://world/characters/mane6/rarity.tscn",
	"pinkie_pie": "res://world/characters/mane6/pinkie_pie.tscn",
	"applejack": "res://world/characters/mane6/applejack.tscn",
	"fluttershy": "res://world/characters/mane6/fluttershy.tscn",
}

var host: Node3D
var _roster_reserved: Array[Vector3] = []


func _init(owner_node: Node3D) -> void:
	host = owner_node


## Drops a character into the live world (not the capture harness) so she can be
## walked up to. Temporary staging for M2 -- once she has a controller and a
## schedule she will be placed by the zone, not by a command-line flag.
func _spawn_roster() -> void:
	_roster_reserved.clear()
	var args := preload("res://world/dev_tools.gd").user_args()
	var single: String = host._arg_value(args, "--character")
	if single != "":
		await _spawn_world_character(single, Vector2.ZERO)
		return
	var ids: Array = ROSTER.keys()
	# Background identities are generated and validated separately. Keep the
	# default six; explicit --roster ids can select any installed, tested avatar.
	var available: Dictionary = ROSTER.duplicate()
	var background_catalog := "res://world/characters/background/catalog.json"
	if FileAccess.file_exists(background_catalog):
		var extra = JSON.parse_string(FileAccess.get_file_as_string(background_catalog))
		if extra is Dictionary:
			for id in extra:
				if not available.has(id) and ResourceLoader.exists(str(extra[id])):
					available[id] = extra[id]
	var wanted: String = host._arg_value(args, "--roster")
	if wanted != "":
		ids = []
		for id in wanted.split(","):
			if available.has(id.strip_edges()):
				ids.append(id.strip_edges())
			else:
				push_warning("[game] unknown roster id %s" % id)
	# Scattered about the plaza (dev, 2026-09-09): reachable walk-grid spots up to 18 m from
	# the plaza ground, at least 4 m apart, random facing. Painted spawns still win.
	var spots: Array[Vector3] = []
	if ids.size() > 1:
		spots = await _scatter_spots(ids.size(), 18.0, 4.0)
	for i in ids.size():
		var offset := Vector2.ZERO
		if i < spots.size():
			offset = Vector2(spots[i].x, spots[i].z) - host.CHARACTER_SPOT
		await _spawn_world_character(available[ids[i]], offset)


## Reachable, mutually spaced spots on the walk grid around the plaza (the crowd lab's
## connected-cell idea through the planner's wander picker). Waits for the nearby chunks;
## returns fewer spots when the grid is not there in time.
func _spawn_navigation(at: Vector3) -> WalkGridService:
	var services: Array = []
	for id in ZoneManager.loaded_ids():
		var service := ZoneManager.get_zone_navigation(id)
		if service != null: services.append(service)
	var region := WorldLayout.nearest(at)
	return ROSTER_PLACEMENT.select_service(services, at, str(region.get("zone", ""))) as WalkGridService


func _scatter_spots(count: int, radius: float, spacing: float) -> Array[Vector3]:
	var spots: Array[Vector3] = []
	await ZoneManager.wait_until_idle()
	for i in 10:
		if not await SHUTDOWN.physics_frame(host): return spots
	var ground := Vector3(host.CHARACTER_SPOT.x, host._ground_y(host.CHARACTER_SPOT), host.CHARACTER_SPOT.y)
	var navigation := _spawn_navigation(ground)
	if navigation == null:
		print("[game] no navigation covering roster anchor %s; using validated physics fallback" % ground)
		return spots
	print("[game] roster navigation zone=%s bounds=%s anchor=%s ready=%s" % [navigation.zone_id, navigation.bounds, ground, navigation.ready_for_paths])
	var coords: Array[Vector2i] = navigation.ensure_near(ground, radius + 2.0)
	navigation.urgent = coords.duplicate()
	var deadline := Time.get_ticks_msec() + 10000
	while is_instance_valid(navigation) and Time.get_ticks_msec() < deadline:
		var ready := true
		for c in coords:
			if not navigation.grid.chunks.has(c) or navigation.grid.chunks[c].state != WalkChunk.State.READY:
				ready = false
				break
		if ready: break
		if not await SHUTDOWN.physics_frame(host): return spots
	if not is_instance_valid(navigation): return spots
	var planner := WalkPlanner.new()
	var settings := WalkGrid.profile(preload("res://world/characters/locomotion/pony_gait_profile.gd").new())
	settings.wade = 0.0; settings.swim = false # Spawn policy is stricter than travel through a ford.
	var snapshot: Dictionary = navigation.grid.snapshot()
	for i in count:
		# Each search is a synchronous grid walk; a 40-mare roster froze the window for
		# minutes when this loop ran without yielding.
		if not await SHUTDOWN.frame(host): return spots
		for attempt in 12:
			var spot: Vector3 = planner.wander(snapshot, ground, settings, radius, Vector3.INF, ground, radius)
			if not spot.is_finite(): break
			var clear := true
			for other in spots:
				if Vector2(other.x - spot.x, other.z - spot.z).length() < spacing: clear = false; break
			if clear:
				spots.append(spot)
				break
	print("[game] scattered %d of %d roster spots on the walk grid" % [spots.size(), count])
	return spots


## Drops a character into the live world (not the capture harness) so she can be
## walked up to. `offset` shifts her from CHARACTER_SPOT (the roster ring).
func _spawn_world_character(path: String, offset: Vector2) -> void:
	var packed: PackedScene = load(path)
	if packed == null:
		push_error("[game] could not load character %s" % path)
		return

	await ZoneManager.wait_until_idle()
	# Ground-snapping needs collision in the physics space, which only exists
	# after physics has stepped.
	for i in 10:
		if not await SHUTDOWN.physics_frame(host): return

	var spot: Vector2 = host.CHARACTER_SPOT + offset
	var pos := Vector3(spot.x, host._ground_y(spot), spot.y)

	# A .tscn character is self-contained (the physics pony drives her own
	# body). A bare model gets wrapped in a Pony so she pathfinds and reacts
	# rather than standing as scenery.
	if path.ends_with(".tscn"):
		var rig: Node3D = packed.instantiate()
		var identity: Resource = rig.get("identity")
		var navigation := _spawn_navigation(pos)
		var authored_selected := false
		if identity != null and navigation != null:
			var authored := navigation.spawn_world(String(identity.id), host.mares.size())
			if authored.is_finite():
				authored_selected = true
				var xz := Vector2(authored.x, authored.z)
				pos = Vector3(xz.x, host._ground_y(xz), xz.y)
		var spawn_profile: Resource = rig.get("profile")
		if spawn_profile == null: spawn_profile = ROSTER_PLACEMENT.PROFILE.new()
		var spawn_spacing: float = spawn_profile.radius * 2.0 + .1 if authored_selected else 4.0
		var validated := ROSTER_PLACEMENT.support(host.get_world_3d().direct_space_state, pos, spawn_profile)
		if not validated.is_finite() or not ROSTER_PLACEMENT.separated(validated, _roster_reserved, spawn_spacing):
			validated = ROSTER_PLACEMENT.fallback(host.get_world_3d().direct_space_state, pos, _roster_reserved, 18.0, 4.0, spawn_profile)
		if not validated.is_finite():
			push_warning("[game] no supported, separated roster placement for %s near %s; skipping unsafe spawn" % [path.get_file(), pos])
			rig.free()
			return
		pos = validated
		_roster_reserved.append(pos)
		rig.position = pos
		# Face the player spawn (a scattered pony faces wherever she likes). Set BEFORE
		# add_child: the ragdoll bakes its body transforms from the root the moment it enters the tree.
		var d: Vector3 = host.spawn.global_position - pos
		rig.basis = Basis(Vector3.UP, randf() * TAU if offset != Vector2.ZERO else atan2(-d.x, -d.z))
		if rig.has_method("begin_grab"):
			# Locomotion mare: give her the navigator so she wanders town.
			rig.name = String(identity.id).to_pascal_case() if identity != null else "RainbowDash"
			var navigator: Node = NAVIGATOR.new()
			navigator.name = "Navigator"
			navigator.wander_enabled = true
			navigator.attention_target = host._find_camera(host.player)
			navigator.debug_log = true
			rig.add_child(navigator)
			# The player is an obstacle her avoidance steers around.
			var body: Node3D = host.player.find_child("Body", true, false)
			if body != null and body.find_child("NavObstacle", false, false) == null:
				var obstacle := NavigationObstacle3D.new()
				obstacle.name = "NavObstacle"
				obstacle.radius = 0.4
				obstacle.height = 1.8
				obstacle.avoidance_enabled = true
				body.add_child(obstacle)
		host.add_child(rig)
		host.character = null
		print("[game] spawned physics character %s at %s" % [path.get_file(), pos.round()])
		if rig.has_method("begin_grab"):
			host._wire_mare(rig)
			host.mares.append(rig)
		if host._pending_spectator != null:
			host._pending_spectator.add_mare(rig)
		return

	# The legacy bare-model route follows the same dry, supported spawn policy.
	var legacy_profile := ROSTER_PLACEMENT.PROFILE.new()
	pos = ROSTER_PLACEMENT.fallback(host.get_world_3d().direct_space_state, pos, _roster_reserved, 18.0, 4.0, legacy_profile)
	if not pos.is_finite():
		push_warning("[game] no dry supported placement for " + path.get_file())
		return
	_roster_reserved.append(pos)
	var pony: CharacterBody3D = PONY.new()
	pony.name = "RainbowDash"
	pony.model_scene = packed
	host.add_child(pony)
	pony.global_position = pos
	pony.player = host.player
	pony.debug_motion = "--debug-pony" in preload("res://world/dev_tools.gd").user_args()
	pony.look_at(Vector3(host.spawn.global_position.x, pos.y, host.spawn.global_position.z),
		Vector3.UP)
	host.character = pony
	print("[game] spawned pony %s at %s" % [path.get_file(), pos.round()])
