extends SceneTree
## Actual Pinkie controller dimensions for fitting the authored tower route.
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var ground := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(8, .2, 8)
	collision.shape = shape
	ground.position.y = -.1
	ground.add_child(collision)
	world.add_child(ground)
	var pony: CharacterBody3D = load("res://world/characters/hybrid_mare/hybrid_mare.tscn").instantiate()
	pony.identity = load("res://world/characters/mane6/pinkie_pie.tres")
	world.add_child(pony)
	for i in 30:
		await physics_frame
		await process_frame
	var profile: Resource = pony.profile
	print("TOWER_PINKIE_PROFILE radius=", profile.radius, " clearance=", profile.clearance,
		" step_height=", profile.step_height, " scale=", pony.global_basis.get_scale())
	for holder: CollisionShape3D in pony.find_children("*", "CollisionShape3D", true, false):
		if holder.disabled or holder.shape == null: continue
		print("TOWER_PINKIE_SHAPE name=", holder.name, " type=", holder.shape.get_class(),
			" debug_bounds=", holder.shape.get_debug_mesh().get_aabb(), " transform=", holder.global_transform)
	for mesh: MeshInstance3D in pony.find_children("*", "MeshInstance3D", true, false): mesh.material_overlay = null
	preload("res://world/characters/locomotion/baked_gaits.gd").forget()
	world.queue_free()
	await process_frame
	await process_frame
	print("TOWER_PROFILE_MEASURED")
	quit()
