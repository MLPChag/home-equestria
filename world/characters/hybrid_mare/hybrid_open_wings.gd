extends Node
## Optional original open wing meshes on the EXISTING body skeleton; no second rig.
## Shared by the flight review and lazy gameplay takeoff.
const SCENE := "res://world/characters/body_shapes/mare_wings.scn"
var meshes: Array[MeshInstance3D] = []
var folded: Array[MeshInstance3D] = []
var opened := false
var bind_error := 0.0

func bind(pony: CharacterBody3D) -> bool:
	if not meshes.is_empty() or not pony.identity.has_wings(): return false
	var source: Node3D = load(pony.get_meta("open_wing_scene", SCENE)).instantiate()
	add_child(source)
	var source_sk: Skeleton3D = source.find_children("*", "Skeleton3D", true, false)[0]
	var target: Skeleton3D = pony.skeleton
	for node in target.find_children("*", "MeshInstance3D", true, false):
		if String(node.name).begins_with("wing folded"): folded.append(node)
	if folded.size() != 2: source.free(); return false
	for original: MeshInstance3D in source.find_children("*", "MeshInstance3D", true, false):
		if not String(original.name).begins_with("wing open"): continue
		var skin: Skin = original.skin.duplicate()
		for i in skin.get_bind_count():
			var bone_name := skin.get_bind_name(i)
			if bone_name == &"": bone_name = source_sk.get_bone_name(skin.get_bind_bone(i))
			var b := target.find_bone(bone_name)
			if b < 0: source.free(); return false
			var original_b := source_sk.find_bone(bone_name)
			var a := source_sk.get_bone_global_rest(original_b)
			var expected := target.get_bone_global_rest(b)
			bind_error = maxf(bind_error, a.origin.distance_to(expected.origin))
			for axis in 3: bind_error = maxf(bind_error, a.basis[axis].distance_to(expected.basis[axis]))
			skin.set_bind_name(i, bone_name); skin.set_bind_bone(i, b)
		if bind_error > .00001: source.free(); return false
		var mi := MeshInstance3D.new(); mi.name = original.name
		mi.mesh = original.mesh; mi.skin = skin
		target.add_child(mi); mi.skeleton = NodePath("..")
		mi.transform = source_sk.global_transform.affine_inverse() * original.global_transform
		# Exactly the existing folded-wing coat/shadow/outline material, no new shader.
		for surface in mi.mesh.get_surface_count(): mi.set_surface_override_material(surface, folded[0].get_active_material(0))
		mi.extra_cull_margin = 1.0
		meshes.append(mi)
	source.free()
	set_open(false)
	return meshes.size() == 2

func set_open(value: bool) -> void:
	opened = value
	for mi in meshes: mi.visible = value
	for mi in folded: mi.visible = not value

func _exit_tree() -> void:
	for mi in meshes:
		if is_instance_valid(mi) and not mi.is_queued_for_deletion(): mi.queue_free()
	for mi in folded:
		if is_instance_valid(mi): mi.visible = true
