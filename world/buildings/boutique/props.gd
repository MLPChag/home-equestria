extends RefCounted
## Imported artwork stays untouched; each prop gets a metre-scale placement frame.
const KIT := preload("res://world/buildings/golden_oak/furniture_kit.gd")
static func meshes(root: Node3D) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if root is MeshInstance3D: result.append(root)
	for child: Node in root.find_children("*", "MeshInstance3D", true, false): result.append(child)
	return result
static func bounds(root: Node3D) -> AABB:
	var result := AABB(); var first := true
	for mesh: MeshInstance3D in meshes(root):
		if mesh.mesh == null: continue
		var box: AABB = root.global_transform.affine_inverse() * mesh.global_transform * mesh.mesh.get_aabb()
		result = box if first else result.merge(box); first = false
	return result
static func place(parent: Node3D, id: String, at: Vector3, maximum: Vector3, yaw: float = 0.0) -> Node3D:
	var frame := Node3D.new(); frame.name = id.to_pascal_case()
	frame.transform = Transform3D(Basis(Vector3.UP, yaw), at); parent.add_child(frame)
	var model: Node3D = load("res://world/buildings/shop_furnishings/models/" + id + ".scn").instantiate()
	frame.add_child(model)
	var box := bounds(model)
	var factor := minf(maximum.x / box.size.x, minf(maximum.y / box.size.y, maximum.z / box.size.z))
	# Imported scenes contain an authored scale; apply the additional fit around their current bounds.
	model.scale *= factor
	model.position -= Vector3(box.get_center().x, box.position.y, box.get_center().z) * factor
	frame.set_meta("size", box.size * factor)
	for body: Node in model.find_children("*", "CollisionObject3D", true, false):
		body.collision_layer = 0; body.collision_mask = 0
	for mesh: MeshInstance3D in meshes(model):
		mesh.visibility_range_end = 45.0
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return frame
## Real triangle intersections at the mattress centre, excluding the overhead canopy.
static func mattress_top(bed: Node3D) -> float:
	var samples: Array[float] = []
	for at: Vector2 in [Vector2.ZERO, Vector2(-.2, .2), Vector2(.2, -.2)]:
		var top := -INF
		for mesh: MeshInstance3D in meshes(bed):
			if mesh.mesh == null: continue
			var frame := bed.global_transform.affine_inverse() * mesh.global_transform
			var faces := mesh.mesh.get_faces()
			for i in range(0, faces.size(), 3):
				var hit: Variant = Geometry3D.ray_intersects_triangle(Vector3(at.x, 1.05, at.y), Vector3.DOWN, frame * faces[i], frame * faces[i+1], frame * faces[i+2])
				if hit != null and hit.y > .15: top = maxf(top, hit.y)
		if is_finite(top): samples.append(top)
	assert(not samples.is_empty(), "Imported bed has no central mattress surface")
	samples.sort()
	return samples[samples.size()/2] if not samples.is_empty() else .5
