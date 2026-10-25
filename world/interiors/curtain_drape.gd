extends RefCounted
## Cached source-mesh variants: the rod stays fixed while cloth hangs in front of
## a projecting reveal. No per-frame work, extra surface, hardware or source edit.
static var variants: Dictionary = {}
static func _clip(poly: Array[Dictionary], height: float, above: bool) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if poly.is_empty(): return result
	var previous: Dictionary = poly[-1]
	var previous_inside: bool = previous.p.y > height if above else previous.p.y <= height
	for current: Dictionary in poly:
		var inside: bool = current.p.y > height if above else current.p.y <= height
		if inside != previous_inside:
			var t: float = (height - previous.p.y) / (current.p.y - previous.p.y)
			result.append({"p": (previous.p as Vector3).lerp(current.p, t), "uv": (previous.uv as Vector2).lerp(current.uv, t)})
		if inside: result.append(current)
		previous = current; previous_inside = inside
	return result
static func _emit(builder: SurfaceTool, polygon: Array[Dictionary], distance: float, full_below: float, fixed: bool) -> void:
	for i in range(1, polygon.size() - 1):
		var a: Vector3 = polygon[0].p
		var b: Vector3 = polygon[i].p
		var c: Vector3 = polygon[i+1].p
		if (b-a).cross(c-a).length_squared() < 1e-16: continue
		for index in [0, i, i+1]:
			var data: Dictionary = polygon[index]
			var vertex: Vector3 = data.p
			if not fixed:
				var weight := clampf((.79 - vertex.y) / (.79 - full_below), 0.0, 1.0)
				vertex.z += distance * weight
			builder.set_uv(data.uv)
			builder.add_vertex(vertex)
static func install(model: Node3D, distance: float, full_below: float) -> void:
	if distance <= 0.0: return
	# Round outward so a reused variant retains the measured window clearance.
	var shift := ceili(distance / .025)
	var below := ceili(full_below / .025)
	var boundary := minf(float(below) * .025, .785)
	for view: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		var key := "%s:%d:%d" % [view.mesh.get_rid().get_id(), shift, below]
		if not variants.has(key):
			var mesh := ArrayMesh.new()
			for surface in view.mesh.get_surface_count():
				var arrays: Array = view.mesh.surface_get_arrays(surface)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				var builder := SurfaceTool.new(); builder.begin(Mesh.PRIMITIVE_TRIANGLES)
				var count := indices.size() if not indices.is_empty() else vertices.size()
				for i in range(0, count, 3):
					var triangle: Array[Dictionary] = []
					var finial := true
					for j in 3:
						var index := indices[i+j] if not indices.is_empty() else i+j
						var vertex := vertices[index]
						triangle.append({"p": vertex, "uv": uv[index]})
						finial = finial and vertex.y > .75 and absf(vertex.x) > .38
					if finial:
						_emit(builder, triangle, 0.0, boundary, true); continue
					# Split long source triangles at both bend heights. Merely moving
					# their endpoints cuts diagonally through the projecting reveal.
					_emit(builder, _clip(triangle, boundary, false), float(shift) * .025, boundary, false)
					var upper := _clip(triangle, boundary, true)
					_emit(builder, _clip(upper, .79, false), float(shift) * .025, boundary, false)
					_emit(builder, _clip(upper, .79, true), 0.0, boundary, true)
				builder.generate_normals(); builder.index(); builder.commit(mesh)
				mesh.surface_set_material(surface, view.mesh.surface_get_material(surface))
			variants[key] = mesh
		view.mesh = variants[key]
