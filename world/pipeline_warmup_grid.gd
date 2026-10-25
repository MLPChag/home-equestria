extends RefCounted
## Camera-local rectangle at z=-depth, inside the central view of every XR eye.
## XRCamera3D.project_position in Godot 4.5 leaves XY at near-plane size, regardless
## of requested depth. Use each actual eye projection instead; no headset polling.
const VIEW_FRACTION := 0.6

static func footprint(camera: Camera3D, depth: float) -> Rect2:
	var viewport_size := camera.get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(1.0, viewport_size.y)
	var interface := XRServer.primary_interface
	if not camera is XRCamera3D or interface == null:
		var corner := camera.to_local(camera.project_position(viewport_size * 0.2, depth))
		var opposite := camera.to_local(camera.project_position(viewport_size * 0.8, depth))
		return Rect2(Vector2(corner.x, corner.y), Vector2(opposite.x-corner.x, opposite.y-corner.y)).abs()
	var projections: Array[Projection] = []
	var eyes: Array[Transform3D] = []
	for view: int in interface.get_view_count():
		projections.append(interface.get_projection_for_view(view, aspect, camera.near, camera.far))
		var world_eye := interface.get_transform_for_view(view, XRServer.world_origin)
		eyes.append(camera.global_transform.affine_inverse() * world_eye)
	return shared_footprint(projections, eyes, depth, aspect)

## Project the common plane into clip space. Each cropped frustum contributes
## linear XY constraints; their intersection also handles asymmetric/canted eyes.
static func shared_footprint(projections: Array[Projection], eyes: Array[Transform3D], depth: float, aspect: float) -> Rect2:
	if projections.is_empty() or projections.size() != eyes.size() or depth <= 0.0 or aspect <= 0.0: return Rect2()
	var planes: Array[Vector3] = []
	for index: int in projections.size():
		var clip := projections[index] * Projection(eyes[index].affine_inverse())
		var x := Vector4(clip.x.x, clip.y.x, clip.z.x, clip.w.x)
		var y := Vector4(clip.x.y, clip.y.y, clip.z.y, clip.w.y)
		var z := Vector4(clip.x.z, clip.y.z, clip.z.z, clip.w.z)
		var w := Vector4(clip.x.w, clip.y.w, clip.z.w, clip.w.w)
		for row: Vector4 in [w * VIEW_FRACTION + x, w * VIEW_FRACTION - x, w * VIEW_FRACTION + y, w * VIEW_FRACTION - y, w + z, w - z, w]:
			var plane := Vector3(row.x, row.y, row.w - row.z * depth)
			var length := Vector2(plane.x, plane.y).length()
			if length < 0.000001:
				if plane.z < 0.0: return Rect2()
				continue
			planes.append(plane / length)
	var vertices: Array[Vector2] = []
	for i: int in planes.size():
		for j: int in range(i + 1, planes.size()):
			var a := planes[i]; var b := planes[j]
			var determinant := a.x*b.y - b.x*a.y
			if absf(determinant) < 0.000001: continue
			var point := Vector2(a.y*b.z - b.y*a.z, a.z*b.x - b.z*a.x) / determinant
			var inside := point.is_finite()
			for plane: Vector3 in planes:
				if plane.dot(Vector3(point.x, point.y, 1.0)) < -0.00001: inside = false; break
			if inside: vertices.append(point)
	if vertices.is_empty(): return Rect2()
	var centre := Vector2.ZERO
	for point: Vector2 in vertices: centre += point
	centre /= vertices.size()
	var radius := INF
	for plane: Vector3 in planes:
		var denominator := absf(plane.x) * aspect + absf(plane.y)
		if denominator > 0.000001:
			radius = minf(radius, plane.dot(Vector3(centre.x, centre.y, 1.0)) / denominator)
	if not is_finite(radius) or radius <= 0.0: return Rect2()
	var half := Vector2(aspect, 1.0) * radius * 0.99
	return Rect2(centre - half, half * 2.0)
