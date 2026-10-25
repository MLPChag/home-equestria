extends RefCounted
## The blue cel outline on whatever a hand can use (dev 2026-09-30: replaces the dotted "vrchat"
## box and the door handle's glowing square). One shared overlay material; each outlined mesh
## fades on its own through the "outline_amount" instance uniform (shaders/interact_outline).
const SHADER := preload("res://shaders/interact_outline.gdshader")
## Anything larger than this (a whole house a door belongs to) is never outlined.
const MAX_EXTENT := 6.0
const MAX_MESHES := 48
static var _material: ShaderMaterial

static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
		_material.render_priority = 1
	return _material

## Fade the outline on one mesh; 0 removes it and restores any overlay it had before.
static func set_amount(mesh: GeometryInstance3D, amount: float) -> void:
	if not is_instance_valid(mesh): return
	if amount <= 0.0:
		if mesh.material_overlay == material():
			mesh.material_overlay = mesh.get_meta("outline_previous") if mesh.has_meta("outline_previous") else null
			if mesh.has_meta("outline_previous"): mesh.remove_meta("outline_previous")
		return
	if mesh.material_overlay != material():
		if mesh.material_overlay != null: mesh.set_meta("outline_previous", mesh.material_overlay)
		mesh.material_overlay = material()
	mesh.set_instance_shader_parameter("outline_amount", clampf(amount, 0.0, 1.0))

## The visible meshes that make up `target` (itself and its children), skipping huge ones.
static func meshes(target: Node3D) -> Array[GeometryInstance3D]:
	var result: Array[GeometryInstance3D] = []
	if not is_instance_valid(target): return result
	for node: Node in [target] + target.find_children("*", "GeometryInstance3D", true, false):
		if result.size() >= MAX_MESHES: break
		if not (node is MeshInstance3D) or not (node as Node3D).is_visible_in_tree(): continue
		var mesh: MeshInstance3D = node
		if mesh.mesh == null: continue
		var size: Vector3 = mesh.get_aabb().size * mesh.global_basis.get_scale().abs()
		if size.x > MAX_EXTENT or size.y > MAX_EXTENT or size.z > MAX_EXTENT: continue
		result.append(mesh)
	return result

static func set_target(target: Node3D, amount: float) -> void:
	for mesh: GeometryInstance3D in meshes(target): set_amount(mesh, amount)
