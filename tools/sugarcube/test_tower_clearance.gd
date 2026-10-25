extends SceneTree
const TOWER := preload("res://world/buildings/sugarcube/tower_room.gd")
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var output := OS.get_environment("EQ_LAB_CAPTURE_DIR")
	if output.is_empty(): quit(2); return
	var prefab := ""
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--prefab="): prefab = argument.trim_prefix("--prefab=")
	var house: Node3D = load(prefab if not prefab.is_empty() else "res://world/towns/ponyville/sugarcube.scn").instantiate()
	house.scale = Vector3.ONE*14.0; root.add_child(house)
	if prefab.is_empty():
		var old_room := house.get_node_or_null("BakeryRoom")
		if old_room != null: old_room.free()
		preload("res://world/buildings/sugarcube/bakery_room.gd").build(house)
		if not TOWER.open_shaft(house):
			house.queue_free(); await process_frame; quit(1); return
		TOWER.build(house)
	await physics_frame; await physics_frame
	var space := house.get_world_3d().direct_space_state
	var rows: Array = []; var blocked := 0; var sweeps := 0
	var authored: Array[Vector3] = []
	var tower_home: Node3D
	for node: Node3D in house.find_children("*","Node3D",true,false):
		if node.get_script() == preload("res://world/buildings/sugarcube/tower_home.gd"):
			tower_home = node; break
	if tower_home != null:
		for point: Vector3 in tower_home.stair_path: authored.append(tower_home.to_global(point))
	else:
		var room := house.get_node_or_null("TowerRoom") as Node3D
		if room != null and room.has_meta("stair_path"):
			for point: Vector3 in room.get_meta("stair_path"): authored.append(room.to_global(point))
	var bed := house.get_node_or_null("TowerRoom/PinkieBed") as Node3D
	var bedside: Vector3 = tower_home.bed_side() if tower_home != null else \
		bed.to_global(bed.get_meta("side_local")) if bed != null and bed.has_meta("side_local") else Vector3.INF
	if authored.size() < 2 or not bedside.is_finite():
		print("SUGARCUBE_TOWER_CLEARANCE_FAIL missing actual route or bed approach"); house.queue_free(); await process_frame; quit(1); return
	if authored[-1].distance_to(bedside) > .001:
		print("SUGARCUBE_TOWER_CLEARANCE_FAIL authored route does not reach actual bed approach"); house.queue_free(); await process_frame; quit(1); return
	print("TOWER_CLEARANCE_INPUT packed=",not prefab.is_empty()," route_points=",authored.size()," bed_approach=",bedside)
	var path: Array[Vector3] = [authored[0]]
	for i in range(1,authored.size()):
		var divisions := maxi(1,ceili(authored[i-1].distance_to(authored[i]) / .1))
		for j in range(1,divisions+1): path.append(authored[i-1].lerp(authored[i],float(j)/divisions))
	# Human matches desktop_player.tscn. Pony is a representative physical envelope;
	# this geometry gate does not replace the actual quadruped motor traversal.
	for spec: Vector3 in [Vector3(.32,1.8,45.0),Vector3(.45,1.2,35.0),Vector3(.765,2.04,35.0)]:
		var shape := CapsuleShape3D.new(); shape.radius = spec.x; shape.height = spec.y
		var previous: Dictionary = {}
		for index in path.size():
			var point: Vector3 = path[index]
			var sample := settle(space,shape,point,spec.z)
			var row := {"profile":[spec.x,spec.y],"index":index,"point":vector(point),
				"status":sample.status,"hits":sample.get("hits",[])}
			if sample.has("center"): row.settled_foot_y = (sample.center as Vector3).y-spec.y*.5
			if sample.has("normal"): row.support_normal = vector(sample.normal)
			for detail: String in ["initial_hits","underfoot"]:
				if sample.has(detail): row[detail] = sample[detail]
			if sample.status != "clear": blocked += 1
			elif not previous.is_empty() and previous.status == "clear":
				var sweep := passage(space,shape,previous,sample,spec.z,0)
				sweeps += 1
				row.sweep = sweep
				if sweep.status != "clear": blocked += 1
			rows.append(row)
			previous = sample
	DirAccess.make_dir_recursive_absolute(output)
	FileAccess.open(output.path_join("clearance.json"),FileAccess.WRITE).store_string(JSON.stringify(rows,"\t"))
	if DisplayServer.get_name() != "headless":
		root.size = Vector2i(1400,900)
		var env := WorldEnvironment.new(); env.environment = Environment.new(); env.environment.background_mode = Environment.BG_COLOR
		env.environment.background_color = Color("a8cadb"); env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.environment.ambient_light_color = Color.WHITE; env.environment.ambient_light_energy = .7; root.add_child(env)
		var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-45,-30,0); root.add_child(sun)
		var camera := Camera3D.new(); root.add_child(camera); camera.current = true
		var floor_y := bedside.y
		var room_focus := Vector3(-.2,floor_y+1.0,-.3)
		for spec: Array in [["counter",Vector3(-5.5,2.5,.0),Vector3(-1,3,-2)], ["stairs",Vector3(-.2,7,-.3),Vector3(-1,7.5,0)], ["bed",Vector3(.5,floor_y+1.5,-1.2),room_focus], ["pony-room",bedside+Vector3(-1.8,1.7,-1.4),bed.global_position+Vector3(0,.8,0)], ["outside",Vector3(18,15,24),Vector3(0,8,0)], ["upper-front",Vector3(0,floor_y+1.2,10),Vector3(0,floor_y,0)], ["upper-back",Vector3(0,floor_y+1.2,-10),Vector3(0,floor_y,0)]]:
			camera.position = spec[1]; camera.look_at(spec[2])
			for frame in 3: await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output.path_join(str(spec[0])+".png"))
	var uid_path := "res://tools/sugarcube/test_tower_clearance.gd.uid"
	if not FileAccess.file_exists(uid_path):
		var uid_file := FileAccess.open(uid_path,FileAccess.WRITE)
		uid_file.store_string(ResourceUID.id_to_text(ResourceUID.create_id()) + "\n")
	print("SUGARCUBE_TOWER_CLEARANCE_" if not prefab.is_empty() else "SUGARCUBE_TOWER_GEOMETRY_", "PASS" if blocked == 0 else "FAIL", " samples=",rows.size()," sweeps=",sweeps," blocked=",blocked)
	house.queue_free(); await process_frame; quit(0 if blocked == 0 else 1)

func vector(value: Vector3) -> Array: return [value.x,value.y,value.z]

func query_at(shape: CapsuleShape3D,center: Vector3) -> PhysicsShapeQueryParameters3D:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape; query.collision_mask = 1; query.transform.origin = center
	return query

func names(hits: Array[Dictionary]) -> Array[String]:
	var result: Array[String] = []
	for hit: Dictionary in hits:
		var collider: Object = hit.get("collider")
		if collider == null and hit.has("collider_id"): collider = instance_from_id(int(hit.collider_id))
		var label := str((collider as Node).get_path()) if collider is Node else str(hit.get("rid","unknown"))
		if collider is Node3D: label += " at " + str((collider as Node3D).global_position)
		if collider is CollisionObject3D and hit.has("shape"):
			var object := collider as CollisionObject3D
			var owner_id := object.shape_find_owner(int(hit.shape))
			if object.shape_owner_get_shape_count(owner_id) > 0:
				var collision_shape := object.shape_owner_get_shape(owner_id,0)
				label += " " + collision_shape.get_class()
				if collision_shape is BoxShape3D: label += " " + str(collision_shape.size)
		result.append(label)
	return result

## Probe contact just beyond the cast's unsafe fraction to retrieve its actual
## normal. This microscopic overlap is diagnostic only, never an admitted pose.
func contact(space: PhysicsDirectSpaceState3D,query: PhysicsShapeQueryParameters3D,unsafe_fraction: float) -> Dictionary:
	var origin := query.transform.origin
	var motion := query.motion
	query.transform.origin += motion * unsafe_fraction + motion.normalized() * .001
	query.motion = Vector3.ZERO
	var result := space.get_rest_info(query)
	query.transform.origin = origin; query.motion = motion
	return result

func settle(space: PhysicsDirectSpaceState3D,shape: CapsuleShape3D,point: Vector3,max_slope: float) -> Dictionary:
	# The foot hemisphere is exactly the capsule's lower envelope. A full capsule
	# lifted for a downward probe may start through an upper turn; the engine then
	# ignores that whole collider, including its floor. Find support with the foot,
	# then require the original full capsule to be empty at the resulting pose.
	var foot := CapsuleShape3D.new(); foot.radius = shape.radius; foot.height = shape.radius * 2.0
	var query := query_at(foot,point + Vector3.UP * (shape.radius + .50))
	query.motion = Vector3.DOWN * .70
	var cast := space.cast_motion(query)
	if cast[0] >= 1.0:
		var initial := space.intersect_shape(query_at(foot,query.transform.origin),8)
		var ray := PhysicsRayQueryParameters3D.create(point + Vector3.UP*.11,point-Vector3.UP*2.0,1)
		var underfoot := space.intersect_ray(ray)
		var detail := {"hit":not underfoot.is_empty()}
		if not underfoot.is_empty():
			detail.position = vector(underfoot.position); detail.normal = vector(underfoot.normal); detail.collider = names([underfoot])
		return {"status":"missing_support","point":point,"initial_hits":names(initial),"underfoot":detail}
	var support := contact(space,query,cast[1])
	if support.is_empty(): return {"status":"missing_support_normal","point":point}
	var normal: Vector3 = support.normal
	if normal.dot(Vector3.UP) < cos(deg_to_rad(max_slope)):
		return {"status":"steep_or_nonfloor_support","point":point,"normal":normal,"hits":names([support])}
	query.transform.origin += query.motion * cast[0] + Vector3.UP * .005
	query.motion = Vector3.ZERO
	query.transform.origin += Vector3.UP * (shape.height * .5 - shape.radius)
	query.shape = shape
	var foot_height := query.transform.origin.y - shape.height * .5
	# A walkable surface can rise within the capsule footprint, but a rail or an
	# unrelated floor far above the authored path is not an admissible support.
	if foot_height - point.y > shape.radius * tan(deg_to_rad(max_slope)) + .005:
		return {"status":"support_above_route","point":point,"center":query.transform.origin,"normal":normal,"hits":names([support])}
	var hits := space.intersect_shape(query,8)
	return {"status":"clear" if hits.is_empty() else "overlap","point":point,
		"center":query.transform.origin,"normal":normal,"hits":names(hits)}

## Every interval is a full capsule sweep. At a convex ramp join its straight
## chord may touch the floor; refine supported midpoints instead of ignoring the
## stair collider (which also owns the dangerous underside of the next turn).
func passage(space: PhysicsDirectSpaceState3D,shape: CapsuleShape3D,first: Dictionary,last: Dictionary,max_slope: float,depth: int) -> Dictionary:
	var query := query_at(shape,first.center)
	query.motion = (last.center as Vector3) - (first.center as Vector3)
	if query.motion.length_squared() < 1e-12: return {"status":"clear"}
	var cast := space.cast_motion(query)
	if cast[0] >= 1.0: return {"status":"clear"}
	var hit := contact(space,query,cast[1])
	var normal: Vector3 = hit.get("normal",Vector3.ZERO)
	var center_at_contact := query.transform.origin + query.motion * cast[0]
	var floor_contact := not hit.is_empty() and normal.dot(Vector3.UP) >= cos(deg_to_rad(max_slope)) \
		and (hit.point as Vector3).y <= center_at_contact.y - shape.height * .5 + shape.radius
	if floor_contact and depth < 4:
		var midpoint: Vector3 = (first.point as Vector3).lerp(last.point,.5)
		var middle := settle(space,shape,midpoint,max_slope)
		if middle.status != "clear": return {"status":"midpoint_" + str(middle.status),"point":vector(midpoint),"hits":middle.get("hits",[])}
		var before := passage(space,shape,first,middle,max_slope,depth+1)
		if before.status != "clear": return before
		return passage(space,shape,middle,last,max_slope,depth+1)
	return {"status":"unresolved_floor_sweep" if floor_contact else "blocked_sweep",
		"normal":vector(normal),"fraction":cast[0],"hits":names([hit]) if not hit.is_empty() else [],"depth":depth}
