extends RefCounted
## Resident spawning for the population: regional navigation services, supported spawn placement, despawn and release.
## Split out of game.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning game node; shared state stays there.

const ROSTER_PLACEMENT := preload("res://world/navigation/roster_placement.gd")
const NAVIGATOR := preload("res://world/characters/navigation/pony_navigator.gd")

var host: Node3D


func _init(owner_node: Node3D) -> void:
	host = owner_node


func _population_busy(actor: Node3D) -> bool:
	if actor.has_meta("balloon_passenger"):return true
	var identity: Resource = actor.get("identity")
	return host.director != null and identity != null and host.director.engaged(String(identity.id))


func _resident_service(region_id: String, at: Vector3) -> WalkGridService:
	var region := WorldLayout.region(region_id)
	var zone_id := str(region.get("zone", ""))
	if zone_id != "":
		# Wait for the real zone's collision/water and navigation staging.
		return ZoneManager.get_zone_navigation(zone_id)
	if host._resident_navigation.has(region_id) and is_instance_valid(host._resident_navigation[region_id]):
		return host._resident_navigation[region_id].get_node("Navigation") as WalkGridService
	if not is_instance_valid(WorldTerrain.instance): return null
	var content := Node3D.new()
	content.name = "ResidentNavigation_" + region_id
	host.add_child(content)
	var footprint := WorldLayout.footprint(region)
	var bounds := AABB(Vector3(footprint.position.x, -1000, footprint.position.y), Vector3(footprint.size.x, 6000, footprint.size.y))
	var service := WalkGridService.bake(content, {"id": region_id}, {"bounds": bounds, "hashes": ["resident-terrain-v1", region_id]}) as WalkGridService
	# Regional services can be recreated after travel; their preset cache signature
	# does not include the opened restaurant shell or its new interior.
	if is_instance_valid(host.hayburger): host.hayburger.refresh_navigation(service)
	host._resident_navigation[region_id] = content
	service.ensure_near(at, 2.0)
	return service


func _resident_authored_home(id: String, region_id: String, index: int) -> Vector3:
	var zone_id := str(WorldLayout.region(region_id).get("zone", ""))
	var service: WalkGridService
	if zone_id != "": service = ZoneManager.get_zone_navigation(zone_id)
	elif host._resident_navigation.has(region_id) and is_instance_valid(host._resident_navigation[region_id]):
		service = host._resident_navigation[region_id].get_node("Navigation") as WalkGridService
	return service.spawn_world(id, index) if service != null and service.layers != null else Vector3.INF


## `navigation_region` overrides where she is simulated to be (a visiting princess walks on
## the navigation of the region she is visiting, not her home's).
func _spawn_resident(id: String, region_id: String, at: Vector3, packed: PackedScene, navigation_region := "", requester: Node = null) -> Node3D:
	host.spawn_failure = ""
	if is_instance_valid(host.railway) and host.railway.owns(id): return host.railway.spawn_resident(id, packed)
	var current_region:String=host.life.core.state.residents.get(id,{}).get("region",region_id) if is_instance_valid(host.life) else region_id
	if navigation_region != "": current_region = navigation_region
	var navigation: WalkGridService = host._resident_service(current_region, at)
	if navigation == null or not navigation.ready_for_paths:
		host.spawn_failure = "no navigation for %s yet" % current_region
		return null
	preload("res://world/debug/hitch_monitor.gd").mark("pony spawn " + id)
	var rig: Node3D = packed.instantiate()
	var spawn_scope := preload("res://world/population/resident_spawn_scope.gd").new(host, rig, requester)
	var profile: Resource = rig.get("profile")
	if profile == null: profile = ROSTER_PLACEMENT.PROFILE.new()
	var selected := Vector3.INF
	var wanted := at
	var authored := navigation.layers != null and (not navigation.layers.spawns.is_empty() or not navigation.layers.hot_spots.is_empty())
	var camera: Node3D = host._find_camera(host.player)
	# Rainbow Dash's home is the Cloudominium: she starts at its door on the cloud floor (the
	# pegasus-only layer), which the ground rays below do not see and which may be past their
	# 260 m reach; streamed back in from inside it, she appears at that door too.
	var rest: Node = host.get_node_or_null("NightRest")
	if rest != null and preload("res://world/life/night_rest.gd").SKY_HOMES.has(id):
		selected = rest.sky_spawn_at(id, at)
	if is_instance_valid(host.balloon) and host.balloon.owns(id):selected=host.balloon.position_for(id)
	# Each attempt is bounded (nine support rays plus clearance), spread over frames.
	var misses := {"too far": 0, "no ground hit": 0, "no support": 0, "crowded": 0}
	for attempt in (0 if selected.is_finite() else 36):
		if not is_instance_valid(navigation): break
		if camera != null and Vector2(at.x - camera.global_position.x, at.z - camera.global_position.z).length() > 260.0: misses["too far"] += 1; break
		var radius := sqrt(float(attempt)) * 2.8
		var angle := attempt * 2.399963 + float(absi(id.hash()) % 100) * .0628
		var point := wanted + Vector3(cos(angle), 0, sin(angle)) * radius
		var space := host.get_world_3d().direct_space_state
		var home:Node3D=preload("res://world/buildings/house_interior.gd").at(host.get_tree(),point)
		# The heightmap is the terrain reference, not a roof found by a ray from
		# the top of the entire zone. Exact support/clearance still uses physics.
		var terrain_y := WorldTerrain.instance.height_at(point) if is_instance_valid(WorldTerrain.instance) else NAN
		# Saved positions can sit on native plazas/bridges above the heightmap.
		# Starting below that floor spawned Canterlot residents underneath it.
		# The existing support check still rejects buildings, roofs and water.
		var from_y := maxf(terrain_y + 1.5, wanted.y + 3.0) if is_finite(terrain_y) and not authored else maxf(wanted.y + 100.0, navigation.bounds.end.y + 2.0)
		if home!=null:from_y=point.y+.35
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
			Vector3(point.x, from_y, point.z),
			Vector3(point.x, navigation.bounds.position.y - 2.0, point.z), 1))
		if not hit.is_empty():
			point = hit.position
			selected = ROSTER_PLACEMENT.support(space, point, profile,home)
			var occupied: Array[Vector3] = []
			for other in host.mares:
				if is_instance_valid(other): occupied.append(other.global_position)
			if selected.is_finite() and ROSTER_PLACEMENT.separated(selected, occupied, profile.radius*2+.1 if home!=null else 3.0): break
			misses["no support" if not selected.is_finite() else "crowded"] += 1
		elif home == null and is_finite(terrain_y) and terrain_y > WorldLayout.sea_level() + 0.5:
			# Terrain collision only exists in a window around the camera: past it (the loading
			# screen spawns the whole town) she stands on the heightmap. Out there she is on the
			# FAR clip tier, which needs no collision; the window reaches her before she is close.
			selected = Vector3(point.x, terrain_y, point.z)
			var taken: Array[Vector3] = []
			for other in host.mares:
				if is_instance_valid(other): taken.append(other.global_position)
			if ROSTER_PLACEMENT.separated(selected, taken, 3.0): break
			misses["crowded"] += 1
		else: misses["no ground hit"] += 1
		selected = Vector3.INF
		if not await spawn_scope.wait_physics_frame():
			host._release_cancelled_resident_service.call_deferred(current_region)
			return null
	if not selected.is_finite():
		host.spawn_failure = str(misses) + (" camera %s" % camera.global_position if camera != null else "")
		spawn_scope.finish(false); host._release_resident_service(current_region); return null
	# A fast successful ray still must not commit an expired/cancelled requester.
	if not spawn_scope.current():
		spawn_scope.finish(false)
		host._release_cancelled_resident_service.call_deferred(current_region)
		return null
	rig.name = id.to_pascal_case()
	rig.position = selected
	rig.rotation.y = randf() * TAU
	rig.set_meta("home_region", region_id)
	rig.set_meta("navigation_region", current_region)
	var navigator: Node = NAVIGATOR.new()
	navigator.name = "Navigator"
	navigator.attention_target = camera
	navigator._service = navigation
	rig.add_child(navigator)
	host.add_child(rig)
	spawn_scope.finish(true)
	host.mares.append(rig)
	host._wire_mare(rig)
	if is_instance_valid(host.balloon) and host.balloon.owns(id):host.balloon.board(rig,id)
	if host._pending_spectator != null: host._pending_spectator.add_mare(rig)
	print("[population] spawned %s in %s at %s" % [id, region_id, selected])
	return rig


func _despawn_resident(id: String, actor: Node3D) -> void:
	if is_instance_valid(host.life): host.life.detach(id)
	if is_instance_valid(host.social): host.social.forget(id)
	if is_instance_valid(host.director): host.director.unregister_character(id)
	host.mares.erase(actor)
	if is_instance_valid(host.grabber):
		host.grabber.ponies.erase(actor)
		if host.grabber.pony == actor: host.grabber.pony = null
	if is_instance_valid(host.kisser): host.kisser.ponies.erase(actor)
	if is_instance_valid(host._pending_spectator): host._pending_spectator.ponies.erase(actor)
	var region_id := str(actor.get_meta("navigation_region",actor.get_meta("home_region", "")))
	# Release the per-instance stencil pass before retiring shared mesh resources.
	for mesh: MeshInstance3D in actor.find_children("*", "MeshInstance3D", true, false): mesh.material_overlay = null
	actor.queue_free()
	host._release_resident_service(region_id)


func _release_cancelled_resident_service(region_id: String) -> void:
	# Cancellation can resume us synchronously during a parent's tree exit.
	# Only a surviving host should retire navigation after that exit completes.
	if host.is_inside_tree() and not host.is_queued_for_deletion():
		host._release_resident_service(region_id)


func _release_resident_service(region_id: String) -> void:
	for actor in host.mares:
		if is_instance_valid(actor) and actor.get_meta("navigation_region",actor.get_meta("home_region", "")) == region_id: return
	if host._resident_navigation.has(region_id):
		if is_instance_valid(host._resident_navigation[region_id]): host._resident_navigation[region_id].queue_free()
		host._resident_navigation.erase(region_id)
