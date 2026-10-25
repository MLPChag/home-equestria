extends Node3D
## Plain water, physically aimed from the nozzle; walls stop both spray and hits.
const SFX := preload("res://world/audio/interaction_sounds.gd")
var next_spray := 0.0
var reacted: Dictionary = {}
var nozzle: Node3D
var trigger: MeshInstance3D
func _ready() -> void:
	var bottle := CylinderMesh.new(); bottle.top_radius = .028; bottle.bottom_radius = .042; bottle.height = .15
	_part(bottle, Vector3(0, -.015, 0), Color("65bfd2"))
	var neck := CylinderMesh.new(); neck.top_radius = .016; neck.bottom_radius = .023; neck.height = .035
	_part(neck, Vector3(0, .075, 0), Color("eee3c4"))
	var pump := BoxMesh.new(); pump.size = Vector3(.035,.032,.075)
	_part(pump, Vector3(0,.105,-.018), Color("52567e"))
	var lever := BoxMesh.new(); lever.size = Vector3(.015,.046,.012)
	trigger = _part(lever, Vector3(0,.066,-.043), Color("eee3c4")); trigger.rotation.x = -.3
	nozzle = Node3D.new(); nozzle.position = Vector3(0,.105,-.057); add_child(nozzle)
func _part(mesh: Mesh, at: Vector3, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new(); node.mesh = mesh; node.position = at
	var material := StandardMaterial3D.new(); material.albedo_color = color; material.roughness = .7
	node.material_override = material; add_child(node); return node
func configure_body(_body: RigidBody3D, collision: CollisionShape3D) -> void:
	var shape := BoxShape3D.new(); shape.size = Vector3(.085,.23,.09); collision.shape = shape
	collision.position = Vector3(0,.02,-.005)
func spray() -> void:
	var now := Time.get_ticks_msec() * .001
	if now < next_spray or nozzle == null: return
	next_spray = now + .45
	SFX.play_at(self, "prop_spray", nozzle.global_position)
	var from := nozzle.global_position
	var to := from - nozzle.global_basis.z * 2.0
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from,to,1|2))
	if not hit.is_empty():
		to = hit.position
		var actor: Node = hit.collider
		while actor != null and not actor.has_signal("physical_reaction"): actor = actor.get_parent()
		if actor != null:
			var id: int = actor.get_instance_id()
			if now >= float(reacted.get(id, 0.0)):
				reacted[id] = now + 10.0
				actor.emit_signal("physical_reaction", "sprayed")
			if reacted.size() > 64: reacted.clear()
	# A short expanding mist; droplets stop at the first physical surface.
	var mist := Node3D.new(); get_tree().current_scene.add_child(mist) if get_tree().current_scene != null else get_tree().root.add_child(mist)
	for i in 10:
		var droplet := MeshInstance3D.new(); var sphere := SphereMesh.new()
		sphere.radius = .008; sphere.height = .016; sphere.radial_segments = 6; sphere.rings = 3
		droplet.mesh = sphere; mist.add_child(droplet); droplet.global_position = from
		var mat := StandardMaterial3D.new(); mat.albedo_color = Color(.65,.85,1,.65); mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		droplet.material_override = mat
		var spread: Vector3 = nozzle.global_basis.x * randf_range(-.045,.045) + nozzle.global_basis.y * randf_range(-.045,.045)
		var tween := droplet.create_tween(); tween.tween_property(droplet, "global_position", to + spread, .16 + i*.006)
	var cleanup := mist.create_tween(); cleanup.tween_interval(.25); cleanup.tween_callback(mist.queue_free)
	trigger.rotation.x = -.8
	var squeeze := create_tween(); squeeze.tween_property(trigger,"rotation:x",-.3,.2)
