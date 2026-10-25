extends SceneTree
## Measure the actual two authored sleep poses; no production anatomy edits.
class PoseCapture extends SkeletonModifier3D:
	var poses: Array[Transform3D] = []
	func _process_modification() -> void:
		poses.clear()
		var skeleton := get_skeleton()
		for i in skeleton.get_bone_count(): poses.append(skeleton.get_bone_global_pose(i))

func _initialize() -> void: run.call_deferred()
func ticks(count: int) -> void:
	for i in count:
		await physics_frame
		await process_frame

func body_bounds(body: MeshInstance3D, capture: PoseCapture, torso_only := false) -> AABB:
	var frames: Array[Transform3D] = []
	var torso: Array[bool] = []
	if capture != null and body.skin != null:
		var skeleton := capture.get_skeleton()
		for bind in body.skin.get_bind_count():
			var bone := body.skin.get_bind_bone(bind)
			var name := String(body.skin.get_bind_name(bind))
			if not name.is_empty(): bone = skeleton.find_bone(name)
			name = skeleton.get_bone_name(bone)
			frames.append(skeleton.global_transform * capture.poses[bone] * body.skin.get_bind_pose(bind))
			torso.append(name == "pony_hips" or name.begins_with("pony_spine"))
	var bounds := AABB()
	var first := true
	for surface in body.mesh.get_surface_count():
		var data := body.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = data[Mesh.ARRAY_BONES] if data[Mesh.ARRAY_BONES] != null else PackedInt32Array()
		var weights: PackedFloat32Array = data[Mesh.ARRAY_WEIGHTS] if data[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
		var stride: int = bones.size() / vertices.size() if not frames.is_empty() else 0
		for vertex in vertices.size():
			var point := Vector3.ZERO if stride > 0 else body.global_transform * vertices[vertex]
			var relevant := not torso_only
			for influence in stride:
				var index := vertex * stride + influence
				point += frames[bones[index]] * vertices[vertex] * weights[index]
				if weights[index] > 0 and torso[bones[index]]: relevant = true
			if not relevant: continue
			if first: bounds = AABB(point, Vector3.ZERO); first = false
			else: bounds = bounds.expand(point)
	return bounds

func run() -> void:
	var output := OS.get_environment("EQ_LAB_CAPTURE_DIR")
	if output.is_empty(): quit(2); return
	DirAccess.make_dir_recursive_absolute(output)
	var world := Node3D.new(); root.add_child(world)
	var floor_body := StaticBody3D.new(); world.add_child(floor_body)
	var floor_shape := CollisionShape3D.new(); floor_shape.shape = BoxShape3D.new()
	floor_shape.shape.size = Vector3(8, .2, 8); floor_shape.position.y = -.1; floor_body.add_child(floor_shape)
	var bed: Node3D = load("res://world/props/ponyville/pony_bed.scn").instantiate()
	var centered := "--centered-compact" in OS.get_cmdline_user_args()
	var pony_scale := 1.7 if "--same-height" in OS.get_cmdline_user_args() else 1.0
	bed.scale.x = 1.05 / 2.042466 if centered else .41616
	bed.scale.z = 1.7 / 2.1 if centered else 1.0
	bed.scale *= pony_scale
	world.add_child(bed)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("9eae99")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = .6; world.add_child(environment)
	var light := DirectionalLight3D.new(); light.rotation_degrees = Vector3(-50, -30, 0); world.add_child(light)
	var camera := Camera3D.new(); camera.current = true; world.add_child(camera)
	root.size = Vector2i(1100, 800)
	var rows: Array[Dictionary] = []
	for style: String in ["head_down", "side"]:
		var pony: CharacterBody3D = load("res://world/characters/hybrid_mare/hybrid_mare.tscn").instantiate()
		pony.identity = load("res://world/characters/mane6/pinkie_pie.tres")
		pony.position = Vector3(.285 if centered else 0.0, float(bed.get_meta("mattress_top", .6)) + .025, -.20 if centered else .15) * pony_scale
		world.add_child(pony)
		pony.set_body_scale(pony_scale)
		pony.set_sim_tier(pony.SimTier.HERO)
		await ticks(30)
		var captures: Dictionary = {}
		for skeleton: Skeleton3D in pony.find_children("*", "Skeleton3D", true, false):
			var snapshot := PoseCapture.new(); skeleton.add_child(snapshot); captures[skeleton] = snapshot
		var capture: PoseCapture = captures[pony.skeleton]
		pony.sleep_style = style
		var accepted: bool = pony.request_posture("lie_down")
		pony.sleeping = accepted
		await ticks(300)
		var body := pony.find_child("MareBody", true, false) as MeshInstance3D
		var bounds := body_bounds(body, capture)
		var torso := body_bounds(body, capture, true)
		var full := bounds
		for mesh: MeshInstance3D in pony.find_children("*", "MeshInstance3D", true, false):
			if mesh.mesh == null or not mesh.is_visible_in_tree() or mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY: continue
			var snapshot: PoseCapture = captures.get(mesh.get_node_or_null(mesh.skeleton))
			full = full.merge(body_bounds(mesh, snapshot))
		var row := {"style":style, "pony_scale":pony.body_scale, "accepted":accepted, "settled":pony.posture.settled(),
			"actual_style":pony.posture._sleep_style, "sleep_blend":pony.posture._sleep_blend,
			"root":var_to_str(pony.global_position), "body_bounds":var_to_str(bounds),
			"body_width":bounds.size.x, "body_length":bounds.size.z,
			"full_bounds":var_to_str(full), "torso_bounds":var_to_str(torso),
			"mattress_width":1.88 * bed.scale.x, "frame_width":2.042466 * bed.scale.x}
		rows.append(row); print("PINKIE_BED_FIT ", JSON.stringify(row))
		if DisplayServer.get_name() != "headless":
			for view: Array in [["side", Vector3(2, 1.7, 2.8)], ["overhead", Vector3(.02, 3.4, .02)]]:
				camera.position = view[1] * pony_scale; camera.look_at(Vector3(0, .65, 0) * pony_scale, Vector3.FORWARD if view[0] == "overhead" else Vector3.UP)
				await ticks(3); await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(output.path_join(style + "-" + str(view[0]) + ".png"))
		for mesh: MeshInstance3D in pony.find_children("*", "MeshInstance3D", true, false): mesh.material_overlay = null
		pony.queue_free(); await ticks(4)
	FileAccess.open(output.path_join("fit.json"), FileAccess.WRITE).store_string(JSON.stringify(rows, "\t"))
	preload("res://world/characters/locomotion/baked_gaits.gd").forget()
	world.queue_free(); await ticks(4)
	# Match the game's teardown: finish LOD jobs before renderer destruction.
	preload("res://world/characters/hybrid_mare/hybrid_near_mesh.gd").discard_pending()
	preload("res://world/characters/hybrid_mare/hybrid_far_mesh.gd").discard_pending()
	print("PINKIE_BED_FIT_MEASURED")
	quit()
