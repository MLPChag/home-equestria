extends SceneTree
## Actual final prefab + Pinkie hybrid/controller + Navigator + HouseTravel.
## Only initial actor placement is fixture setup; every route leg uses normal go_to.
const ACTOR := preload("res://world/characters/hybrid_mare/hybrid_mare.tscn")
const NAV := preload("res://world/characters/navigation/pony_navigator.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
class BedPopulation extends Node:
	var home: Node3D
	func home_house(_id: String) -> Node3D: return home
var failures: Array[String] = []
var bed_hop_contacts: Array[String] = []
var mattress_contacts := 0
var rows: Array[Dictionary] = []
var world: Node3D
var pony: CharacterBody3D
var nav: Node
var tower: Node3D
var size_preset := ""
var actor_scale := 1.0
var ground_only := false
var lower_stairs_only := false
var join_probe := false
func _initialize() -> void: run.call_deferred()
func tick() -> void: await physics_frame; await process_frame
func check(ok: bool, label: String) -> void:
	if not ok: failures.append(label); print("TOWER_PONY_FAIL ", label)
func trace(label: String) -> void:
	var native: Dictionary = nav.native_follow_state() if nav.native_follow else {}
	var collisions: Array[String] = []
	var contacts: Array[Dictionary] = []
	for i in pony.get_slide_collision_count():
		var object: Object = pony.get_slide_collision(i).get_collider()
		collisions.append(str(object.get_path()) if object is Node else str(object))
		var contact: KinematicCollision3D = pony.get_slide_collision(i)
		for j in contact.get_collision_count():
			contacts.append({"point":str(contact.get_position(j)),"normal":str(contact.get_normal(j)),"depth":contact.get_depth(),"shape":str(contact.get_collider_shape(j))})
	var room: Node3D = HOUSE.at(self, pony.global_position)
	var row := {"leg":label, "time_ms":Time.get_ticks_msec(), "position":[pony.global_position.x,pony.global_position.y,pony.global_position.z],
		"state":nav.state, "reason":nav.reason, "room":str(room.get_path()) if room != null else "", "path_points":nav.path.size(),
		"phase":nav.house_travel.phase, "door_owned":nav.house_travel.active(), "collisions":collisions,
		"contacts":contacts,"on_floor":pony.is_on_floor(),"on_wall":pony.is_on_wall(),"floor_angle_limit":pony.floor_max_angle,"body_basis":str(pony.global_basis),"nav_wall_normal":str(pony.nav_wall_normal),"motor_blocked":pony._blocked, "command_speed":pony._command_speed, "corner_speed":pony._corner_speed,
		"native_reason":native.get("reason_name", native.get("reason", "")), "speed":native.get("speed",0.0),
		"progress":native.get("progress",0.0), "length":native.get("length",0.0)}
	rows.append(row); print("TOWER_PONY_TRACE ", JSON.stringify(row))
func route(label: String, destination: Vector3) -> bool:
	var started := Time.get_ticks_msec()
	var next_trace := started
	var wall_since := 0
	nav.go_to(destination)
	while Time.get_ticks_msec() - started < 75000:
		await tick()
		if Time.get_ticks_msec() >= next_trace:
			trace(label); next_trace = Time.get_ticks_msec() + 2000
		if join_probe and pony.is_on_wall() and pony.velocity.length() < .01:
			if wall_since == 0: wall_since = Time.get_ticks_msec()
			if Time.get_ticks_msec()-wall_since >= 1000:
				trace("join-wall-diagnostic"); break
		else: wall_since = 0
		if nav.state == nav.State.ARRIVED: break
		if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED] and not nav._has_target: break
		if pony.global_position.y < -2.0: break
	var distance := pony.global_position.distance_to(destination)
	var success: bool = nav.state == nav.State.ARRIVED and distance < .5
	check(success, label + " actual controller arrival: " + str(distance) + "m; " + nav.reason)
	print("TOWER_PONY_LEG ", label, " success=", success, " distance=", distance, " elapsed_ms=", Time.get_ticks_msec()-started)
	trace(label + "-final")
	nav.stay()
	return success
func observe_bed_hop(label: String) -> void:
	if not pony.motion_paused: return
	var collision: CollisionShape3D = pony._collision
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = collision.shape; query.transform = collision.global_transform
	query.collision_mask = 1; query.exclude = [pony.get_rid()]; query.margin = 0.0
	var mattress: Node = tower.bed.get_node_or_null("Solid")
	for hit: Dictionary in pony.get_world_3d().direct_space_state.intersect_shape(query,32):
		var collider: Object = hit.collider
		# Authored bed shape0 is mattress support; shape1 is the headboard and is NOT excluded.
		if collider == mattress and int(hit.shape) == 0:
			mattress_contacts += 1; continue
		# The hop begins/ends on the floor. Ignore only its first/last2cm vertical contact.
		if collider is Node and str(collider.name).contains("Floor") and absf(pony.global_position.y-tower.bed_side().y) < .02: continue
		var detail := label + ":" + (str(collider.get_path()) if collider is Node else str(collider)) + ":shape=" + str(hit.shape)
		if detail not in bed_hop_contacts: bed_hop_contacts.append(detail)
func bed_cycle() -> bool:
	var population := BedPopulation.new(); population.home = tower; world.add_child(population)
	var rest := preload("res://world/life/night_rest.gd").new(); world.add_child(rest)
	rest.population = population; rest.set_physics_process(false)
	var entry := {"actor":pony,"phase":"going","shared_bed":false}
	rest._state["pinkie_pie"] = entry
	pony.set_meta("living_world",true); nav.command_owner = "sleep:pinkie_pie"
	rest._climb("pinkie_pie",entry,pony,tower)
	var deadline := Time.get_ticks_msec()+12000
	var settled_at := 0
	var retry_at := 0
	while Time.get_ticks_msec() < deadline:
		await tick(); observe_bed_hop("climb")
		if entry.phase == "settling" and Time.get_ticks_msec() >= retry_at:
			rest._begin_sleep(entry,pony); retry_at = Time.get_ticks_msec()+1000
		if entry.phase == "asleep" and pony.sleeping and pony.posture_status().settled:
			if settled_at == 0: settled_at = Time.get_ticks_msec()
			if Time.get_ticks_msec()-settled_at > 1800: break
	var sleeping: bool = entry.phase == "asleep" and pony.sleeping and pony.posture_status().settled and tower.on_mattress(pony.global_position)
	check(sleeping,"actual NightRest climb reaches settled sleep on assigned mattress")
	print("TOWER_PONY_SLEEP style=",pony.sleep_style," phase=",entry.phase," position=",pony.global_position)
	if not sleeping: return false
	check(rest.wake_up("pinkie_pie"),"existing wake_up accepts actual sleeping entry")
	deadline = Time.get_ticks_msec()+8000
	var woke := false
	while Time.get_ticks_msec() < deadline:
		await tick(); observe_bed_hop("wake")
		if not pony.sleeping and not pony.motion_paused and pony.posture_status().settled and pony.global_position.distance_to(tower.bed_side()) < .2:
			woke = true; break
	check(woke,"actual NightRest wake stands on assigned bedside floor")
	check(bed_hop_contacts.is_empty(),"bed hop controller clearance: "+str(bed_hop_contacts))
	print("TOWER_PONY_BED_CONTACTS mattress_support=",mattress_contacts," other=",bed_hop_contacts)
	rest.queue_free(); population.queue_free()
	return sleeping and woke and bed_hop_contacts.is_empty()
func run() -> void:
	if not OS.get_environment("XDG_DATA_HOME").contains("handoff-review-tower"):
		print("TOWER_PONY_FAIL isolated fixture directory required"); quit(2); return
	var path := "res://world/towns/ponyville/sugarcube.scn"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--prefab="): path = arg.trim_prefix("--prefab=")
		if arg.begins_with("--pony-size="): size_preset = arg.trim_prefix("--pony-size=")
		if arg == "--ground-only": ground_only = true
		if arg == "--lower-stairs-only": lower_stairs_only = true
		if arg == "--join-probe": join_probe = true
	var settings := root.get_node("Settings")
	if size_preset.is_empty(): size_preset = str(settings.get_value("ponies/size"))
	var found_size := false
	for preset: Dictionary in settings.PONY_SIZES:
		if str(preset.name) == size_preset:
			actor_scale = float(preset.scale); found_size = true; break
	if not found_size:
		print("TOWER_PONY_FAIL unknown size preset"); quit(2); return
	if ground_only and lower_stairs_only:
		print("TOWER_PONY_FAIL incompatible fixture modes"); quit(2); return
	if not path.begins_with("res://") or not ResourceLoader.exists(path): quit(2); return
	world = Node3D.new(); root.add_child(world)
	var prefab: Node3D = (load(path) as PackedScene).instantiate()
	prefab.scale = Vector3.ONE * 14.0; world.add_child(prefab)
	if ground_only:
		# Source-only ground controller control: no tower geometry, packed writes or saves.
		prefab.get_node("BakeryRoom").free()
		preload("res://world/buildings/sugarcube/bakery_room.gd").build(prefab)
		var adapter := preload("res://world/buildings/sugarcube/tower_home.gd").new()
		adapter.name = "TowerHome"; adapter.scale = Vector3.ONE / 14.0
		adapter.floor_y = .9; adapter.room_floor = 13.05; adapter.ground_path_count = 5
		adapter.stair_path.assign([Vector3(.12,.9,1.6),Vector3(.12,.9,.62),Vector3(4.13,.9,.62),Vector3(4.13,.9,-2.29),Vector3(2.3,.9,-2.29)])
		prefab.add_child(adapter)
	tower = prefab.get_node_or_null("TowerHome") as Node3D
	var bakery := prefab.get_node_or_null("HouseInterior") as Node3D
	if tower == null or bakery == null or tower.stair_path.size() < 2:
		check(false, "final prefab includes actual tower adapter and complete authored route")
		await finish(); return
	for i in 3: await tick()
	var service: WalkGridService = WalkGridService.bake(world, {"id":"sugarcube-tower-pony-fixture"})
	pony = ACTOR.instantiate()
	pony.identity = load("res://world/characters/mane6/pinkie_pie.tres")
	pony.position = bakery.inside() + Vector3.UP * .05
	world.add_child(pony)
	# Match Game._wire_mare: scale the actual model, profile and collision before navigation.
	pony.set_body_scale(actor_scale)
	nav = NAV.new(); nav.name = "Navigator"; nav.wander_enabled = false; pony.add_child(nav)
	for i in 30: await tick()
	pony.set_sim_tier(pony.SimTier.HERO)
	print("TOWER_PONY_INPUT prefab=", path, " sha256=", FileAccess.get_sha256(path), " lower_stairs_only=", lower_stairs_only, " source_ground_only=", ground_only, " size_preset=", size_preset, " body_scale=", pony.body_scale, " profile_radius=", pony.profile.radius,
		" clearance=", pony.profile.clearance, " step_height=", pony.profile.step_height, " native=", nav.native_follow)
	check(is_equal_approx(pony.body_scale, actor_scale), "actual selected production body scale applied")
	check(nav.native_follow, "actual native follower available")
	if not ground_only: check(tower.fits(pony.profile), "unchanged Pinkie profile fits authored route")
	check(HOUSE.at(self, pony.global_position) == bakery, "initial actor settles on actual bakery floor")
	if ground_only:
		if failures.is_empty() and await route("ground-to-stair-foot", tower.to_global(tower.stair_path[-1])):
			await route("ground-return-to-bakery", bakery.inside())
		await finish(); return
	if lower_stairs_only:
		var lower_goal := Vector3.INF
		var highest: float = float(tower.floor_y)
		for point: Vector3 in tower.stair_path:
			if point.y <= 9.0 and point.y > highest:
				highest = point.y; lower_goal = tower.to_global(point)
		check(lower_goal.is_finite(),"candidate exposes actual lower stair waypoint below9m")
		print("TOWER_PONY_LOWER_GOAL ",lower_goal," authored_height=",highest)
		if failures.is_empty() and await route("lower-stairs-ascent",lower_goal):
			check(HOUSE.at(self,pony.global_position) == tower,"actual lower stair arrival belongs to tower")
			await route("lower-stairs-descent",bakery.inside())
		await finish(); return
	check(tower.ensure_bed("pinkie_pie") != null, "actual tower bed linked")
	var stair_ownership_checks := 0
	for point: Vector3 in tower.stair_path:
		if point.y <= tower.floor_y + .15 or point.y >= tower.room_floor - .15: continue
		stair_ownership_checks += 1
		check(HOUSE.at(self, tower.to_global(point) + Vector3.UP * .02) == tower,
			"intermediate stair belongs to tower, not bakery: " + str(point))
	check(stair_ownership_checks > 0, "actual prefab exposes intermediate stair ownership samples")
	print("TOWER_PONY_STAIR_OWNERSHIP samples=", stair_ownership_checks)
	if failures.is_empty():
		var bed_side: Vector3 = tower.bed_side("pinkie_pie")
		if await route("ascent-to-bed", bed_side):
			check(HOUSE.at(self, pony.global_position) == tower, "arrived approach belongs to upstairs home")
			check(tower.contains(bed_side), "bed approach is on usable bedroom floor")
			check(not tower.on_mattress(pony.global_position), "bed approach stays beside mattress")
			if not await bed_cycle():
				await finish(); return
			if await route("descent-to-bakery", bakery.inside()):
				check(HOUSE.at(self, pony.global_position) == bakery, "descent ends on actual bakery floor")
	await finish()
func finish() -> void:
	var output := OS.get_environment("EQ_LAB_CAPTURE_DIR")
	if not output.is_empty():
		DirAccess.make_dir_recursive_absolute(output)
		var file := FileAccess.open(output.path_join("pony-route.json"), FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify({"failures":failures,"lower_stairs_only":lower_stairs_only,"bed_hop_contacts":bed_hop_contacts,"mattress_contacts":mattress_contacts,"source_ground_only":ground_only,"size_preset":size_preset,"body_scale":actor_scale,"trace":rows}, "\t"))
	if is_instance_valid(nav): nav.stay()
	if is_instance_valid(pony):
		for mesh: MeshInstance3D in pony.find_children("*", "MeshInstance3D", true, false): mesh.material_overlay = null
	preload("res://world/characters/locomotion/baked_gaits.gd").forget()
	if is_instance_valid(world): world.queue_free()
	await tick(); await tick()
	preload("res://world/characters/hybrid_mare/hybrid_near_mesh.gd").discard_pending()
	preload("res://world/characters/hybrid_mare/hybrid_far_mesh.gd").discard_pending()
	if join_probe:
		Node.print_orphan_nodes()
		print("TOWER_JOIN_DIAGNOSTIC_DONE failures=",failures); quit(0); return
	print("TOWER_PONY_LOWER_" if lower_stairs_only else "TOWER_PONY_", "PASS" if failures.is_empty() else "FAIL", " failures=", failures)
	quit(0 if failures.is_empty() else 1)
