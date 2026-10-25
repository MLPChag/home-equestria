extends RefCounted
## Reversible, per-instance opening of the surveyed RNL Hayburger prefab.
## All reported geometry is in building-local metres; +Z leads into the restaurant.
## The source has two door leaves on the details surface and two flat glass panes.
## Other windows, jambs, signs and roof remain byte-for-byte source geometry.
## The parent interior supplies its floor/ceiling and finished interior walls.
const STATE := &"hayburger_shell_prepared"
const WALL := "rnl_ponyville_burger_joint_pink_wall"
const DETAILS := "rnl_ponyville_burger_joint_details"
const GLASS := "rnl_ponyville_burger_joint_windows_01"

## street_holes: building-local Rect2s (x, y) of the restaurant's real street windows. The two
## painted front glass bands they lie in are rebuilt around clear holes (dev 2026-10-14: "add
## windows to the hayburger where the textured windows are right now"); without holes the
## shell is opened exactly as before.
static func prepare(building: Node3D, street_holes: Array = []) -> Dictionary:
	if not is_instance_valid(building): return {"ok": false, "error": "No building"}
	if building.has_meta(STATE): return (building.get_meta(STATE) as Dictionary).report
	var views: Array[MeshInstance3D] = []
	for node: Node in building.find_children("*", "MeshInstance3D", true, false):
		views.append(node as MeshInstance3D)
	# This is a measured adapter for this prefab, not a generic mesh cutter. Fail closed
	# on an unexpected model instead of disabling collision on an unrecognised shell.
	if views.size() != 1 or views[0].mesh == null or not views[0].transform.is_equal_approx(Transform3D.IDENTITY):
		return {"ok": false, "error": "Expected one untransformed Hayburger source mesh"}
	var view: MeshInstance3D = views[0]
	var source: ArrayMesh = view.mesh as ArrayMesh
	var solid: StaticBody3D = building.get_node_or_null("Solid") as StaticBody3D
	if source == null or solid == null: return {"ok": false, "error": "Missing source ArrayMesh or Solid"}
	var report: Dictionary = _measure(source)
	if not report.ok: return report
	var envelope: AABB = report.leaf_envelope
	var replacement := ArrayMesh.new()
	var stored: Array = source.get("_surfaces")
	var surfaces: Array = []
	var removed := PackedVector3Array()
	var changed_surfaces: Array[int] = []
	var bands: Array[Dictionary] = []   # painted front glass quads holding a street window
	for hole: Rect2 in street_holes: bands.append({"hole": hole, "points": PackedVector3Array(), "uvs": PackedVector2Array(), "material": null})
	for s: int in source.get_surface_count():
		var arrays: Array = source.surface_get_arrays(s)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var material: Material = source.surface_get_material(s)
		var kept := PackedInt32Array()
		var changed := false
		for i: int in range(0, indices.size(), 3):
			var a: Vector3 = vertices[indices[i]]
			var b: Vector3 = vertices[indices[i + 1]]
			var c: Vector3 = vertices[indices[i + 2]]
			var band: int = _street_band(bands, a, b, c) if material.resource_name == GLASS and not uvs.is_empty() else -1
			if band >= 0:
				bands[band].points.append_array([a, b, c])
				bands[band].uvs.append_array([uvs[indices[i]], uvs[indices[i + 1]], uvs[indices[i + 2]]])
				bands[band].material = material
				changed = true
			elif material.resource_name in [DETAILS, GLASS] and _contains(envelope, a) and _contains(envelope, b) and _contains(envelope, c):
				removed.append_array([a, b, c]); changed = true
			else:
				kept.append_array([indices[i], indices[i + 1], indices[i + 2]])
		if kept.is_empty(): return {"ok": false, "error": "Unexpected whole-surface removal"}
		if changed:
			changed_surfaces.append(s)
		# Re-encoding surface_get_arrays subtly changes packed normals/tangents. Preserve
		# the saved-resource buffers exactly, following hybrid_near_mesh.gd's byte path.
		var raw: Dictionary = (stored[s] as Dictionary).duplicate(true)
		if changed:
			var original_indices: PackedByteArray = raw.index_data
			var stride: int = original_indices.size() / indices.size()
			if stride not in [2, 4]: return {"ok": false, "error": "Unexpected source index width"}
			var bytes := PackedByteArray(); bytes.resize(kept.size() * stride)
			for index: int in kept.size():
				if stride == 2: bytes.encode_u16(index * stride, kept[index])
				else: bytes.encode_u32(index * stride, kept[index])
			raw.index_data = bytes; raw.index_count = kept.size()
			# These two source LODs still contain door leaves. Other surfaces keep their LODs.
			raw.erase("lods")
		surfaces.append(raw)
	replacement.set("_surfaces", surfaces)
	if changed_surfaces.size() != 2 or removed.is_empty():
		return {"ok": false, "error": "The two surveyed leaf surfaces were not found"}
	var leaves: AABB = _bounds(removed)
	var left: float = leaves.position.x
	var right: float = leaves.end.x
	for height: float in [report.floor_y + .05, report.floor_y + 1.5, report.ceiling_y - .1]:
		var span: Vector2 = _slice_x(removed, height)
		left = maxf(left, span.x); right = minf(right, span.y)
	var door := AABB(Vector3(left, report.floor_y, leaves.position.z - .02),
		Vector3(right - left, report.ceiling_y - report.floor_y, leaves.size.z + .04))
	var faces: PackedVector3Array = replacement.get_faces()
	# Do not remove giant wall triangles by centroid. If the source changes and leaves a
	# wall spanning this doorway, retain the original building and return an error.
	for fraction: float in [.05, .25, .5, .75, .95]:
		for height: float in [.1, 1.0, 2.0, 3.5]:
			var at := Vector3(lerpf(left, right, fraction), report.floor_y + height, leaves.position.z - .6)
			var hit: Vector3 = _ray(faces, at, Vector3.BACK)
			if hit.is_finite() and hit.z < leaves.end.z + .2:
				return {"ok": false, "error": "Source geometry still obstructs the measured doorway"}
	# Painted band around each clear street-window hole: same texture, same collision.
	var surround: MeshInstance3D = null
	for band: Dictionary in bands:
		if (band.points as PackedVector3Array).size() != 6:
			return {"ok": false, "error": "Street window band is not one painted glass quad"}
	if not bands.is_empty():
		var tool := SurfaceTool.new(); tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		tool.set_material(bands[0].material)
		for band: Dictionary in bands:
			faces.append_array(_glaze(tool, band.points, band.uvs, band.hole))
		surround = MeshInstance3D.new(); surround.name = "StreetWindowSurround"; surround.mesh = tool.commit()
		building.add_child(surround)
	var body := StaticBody3D.new(); body.name = "HayburgerShellCollision"; body.collision_mask = 0
	# Walk-grid floor collection skips this roof/sign shell; physical/headroom rays keep it.
	body.set_meta("navigation_ceiling", true)
	var shape := ConcavePolygonShape3D.new(); shape.set_faces(faces); shape.backface_collision = true
	var holder := CollisionShape3D.new(); holder.name = "Shell"; holder.shape = shape; body.add_child(holder)
	building.add_child(body)
	var original := {"view": view, "mesh": source, "solid": solid, "layer": solid.collision_layer,
		"mask": solid.collision_mask, "collider": body, "surround": surround}
	view.mesh = replacement
	solid.collision_layer = 0; solid.collision_mask = 0
	report["door_opening"] = door
	report["door_width"] = door.size.x
	report["door_height"] = door.size.y
	report["front_door_point"] = Vector3((left + right) * .5, report.floor_y, leaves.position.z)
	report["front_outward"] = Vector3.FORWARD
	report["removed_triangles"] = removed.size() / 3
	report["changed_surfaces"] = changed_surfaces
	report["collider"] = body
	report["street_holes"] = street_holes.duplicate()
	original["report"] = report
	building.set_meta(STATE, original)
	return report

static func restore(building: Node3D) -> void:
	if not is_instance_valid(building) or not building.has_meta(STATE): return
	var state: Dictionary = building.get_meta(STATE)
	if is_instance_valid(state.view): state.view.mesh = state.mesh
	if is_instance_valid(state.solid):
		state.solid.collision_layer = state.layer; state.solid.collision_mask = state.mask
	if is_instance_valid(state.collider):
		state.collider.collision_layer = 0; state.collider.collision_mask = 0
		building.remove_child(state.collider); state.collider.queue_free()
	var surround: Variant = state.get("surround")
	if surround is MeshInstance3D and is_instance_valid(surround):
		building.remove_child(surround); surround.queue_free()
	building.remove_meta(STATE)

static func _measure(mesh: ArrayMesh) -> Dictionary:
	var panes := PackedVector3Array()
	var wall := PackedVector3Array()
	for s: int in mesh.get_surface_count():
		var material: Material = mesh.surface_get_material(s)
		if material == null or material.resource_name not in [GLASS, WALL]: continue
		var arrays: Array = mesh.surface_get_arrays(s)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i: int in range(0, indices.size(), 3):
			var a: Vector3 = vertices[indices[i]]; var b: Vector3 = vertices[indices[i + 1]]; var c: Vector3 = vertices[indices[i + 2]]
			if material.resource_name == WALL: wall.append_array([a, b, c]); continue
			# Survey found the front-door panes are the only flat, central glass below 4 m.
			var centre: Vector3 = (a + b + c) / 3.0
			if absf(centre.x) < 2.0 and centre.y < 4.0 and centre.z < 0.0 and maxf(a.z, maxf(b.z, c.z)) - minf(a.z, minf(b.z, c.z)) < .001:
				panes.append_array([a, b, c])
	if panes.is_empty() or wall.is_empty(): return {"ok": false, "error": "Door panes or pink jamb geometry missing"}
	var glazing: AABB = _bounds(panes)
	if glazing.size.x < 2.0 or glazing.size.x > 3.0 or glazing.size.y < 2.0 or glazing.size.z > .002:
		return {"ok": false, "error": "Unexpected front door pane dimensions"}
	var ceiling := INF
	for i: int in range(0, wall.size(), 3):
		var tri := AABB(wall[i], Vector3.ZERO).expand(wall[i + 1]).expand(wall[i + 2])
		if tri.size.y < .002 and tri.position.y > glazing.end.y and tri.position.y < glazing.end.y + 1.0 \
				and tri.position.x <= glazing.get_center().x and tri.end.x >= glazing.get_center().x and tri.end.z < glazing.position.z:
			ceiling = minf(ceiling, tri.position.y)
	if not is_finite(ceiling): return {"ok": false, "error": "Measured pink lintel missing"}
	var source_bounds: AABB = mesh.get_aabb()
	var faces: PackedVector3Array = mesh.get_faces()
	var centre := Vector3(glazing.get_center().x, ceiling - .1, source_bounds.get_center().z)
	var floor_hit: Vector3 = _ray(faces, centre, Vector3.DOWN)
	var source_floor_found: bool = floor_hit.is_finite() and floor_hit.y < glazing.position.y
	# No floor in the exported shell: give the parent a near-ground finished-floor datum.
	var floor_y: float = floor_hit.y if source_floor_found else ceilf(source_bounds.position.y * 10.0) / 10.0
	var lo := Vector3(-INF, floor_y, -INF)
	var hi := Vector3(INF, ceiling, INF)
	# Inner-most source wall over three body heights and three transects; avoid counting
	# roof/sign bounds as usable room. The door is still closed during this measurement.
	for height: float in [.15, 1.5, 3.5]:
		for offset: float in [-3.0, 0.0, 3.0]:
			var at := Vector3(centre.x, floor_y + height, centre.z + offset)
			lo.x = maxf(lo.x, _ray(faces, at, Vector3.LEFT).x)
			hi.x = minf(hi.x, _ray(faces, at, Vector3.RIGHT).x)
		for offset: float in [-6.0, 0.0, 6.0]:
			var at := Vector3(centre.x + offset, floor_y + height, centre.z)
			lo.z = maxf(lo.z, _ray(faces, at, Vector3.FORWARD).z)
			hi.z = minf(hi.z, _ray(faces, at, Vector3.BACK).z)
	if not lo.is_finite() or not hi.is_finite() or hi.x <= lo.x or hi.z <= lo.z:
		return {"ok": false, "error": "Could not measure enclosed room"}
	lo += Vector3(.08, 0, .08); hi -= Vector3(.08, .05, .08)
	var interior := AABB(lo, hi - lo)
	var envelope := AABB(Vector3(glazing.position.x - .65, source_bounds.position.y - .01, glazing.position.z - .35),
		Vector3(glazing.size.x + 1.3, ceiling - source_bounds.position.y + .013, .37))
	return {"ok": true, "space": "building_local", "shell_aabb": source_bounds,
		"interior_aabb": interior, "floor_y": floor_y, "source_floor_found": source_floor_found,
		"ceiling_y": ceiling, "open_area": Rect2(lo.x, lo.z, interior.size.x, interior.size.z),
		"open_area_m2": interior.size.x * interior.size.z, "leaf_envelope": envelope}

## Index of the street-window band a front glass triangle belongs to: below the upper windows,
## on the street face (-Z), and spanning the band's hole in x. -1 for any other triangle.
static func _street_band(bands: Array[Dictionary], a: Vector3, b: Vector3, c: Vector3) -> int:
	var centre: Vector3 = (a + b + c) / 3.0
	if centre.z > -3.95 or centre.y > 4.0 or maxf(a.y, maxf(b.y, c.y)) > 4.05: return -1
	var low: float = minf(a.x, minf(b.x, c.x))
	var high: float = maxf(a.x, maxf(b.x, c.x))
	for index: int in bands.size():
		var hole: Rect2 = bands[index].hole
		if low < hole.position.x and high > hole.end.x: return index
	return -1

## Rebuilds one painted quad (two triangles) as eight cells around the hole, with bilinear
## positions and UVs, keeping the source winding. Returns the triangles for collision.
static func _glaze(tool: SurfaceTool, points: PackedVector3Array, uvs: PackedVector2Array, hole: Rect2) -> PackedVector3Array:
	var corner: Array[int] = [0, 0, 0, 0]   # (low x, low y), (high x, low y), (high x, high y), (low x, high y)
	var score: Array[float] = [INF, -INF, -INF, INF]
	for i: int in points.size():
		var p: Vector3 = points[i]
		for k: int in 4:
			var value: float = [p.x + p.y, p.x - p.y, p.x + p.y, p.x - p.y][k]
			if (k == 0 or k == 3) and value < score[k]: score[k] = value; corner[k] = i
			if (k == 1 or k == 2) and value > score[k]: score[k] = value; corner[k] = i
	var p00: Vector3 = points[corner[0]]; var p10: Vector3 = points[corner[1]]
	var p11: Vector3 = points[corner[2]]; var p01: Vector3 = points[corner[3]]
	var u00: Vector2 = uvs[corner[0]]; var u10: Vector2 = uvs[corner[1]]
	var u11: Vector2 = uvs[corner[2]]; var u01: Vector2 = uvs[corner[3]]
	var source_normal: Vector3 = (points[1] - points[0]).cross(points[2] - points[0]).normalized()
	var sx: Array[float] = [0.0, clampf((hole.position.x - p00.x) / (p10.x - p00.x), 0.0, 1.0), clampf((hole.end.x - p00.x) / (p10.x - p00.x), 0.0, 1.0), 1.0]
	var ty: Array[float] = [0.0, clampf((hole.position.y - p00.y) / (p01.y - p00.y), 0.0, 1.0), clampf((hole.end.y - p00.y) / (p01.y - p00.y), 0.0, 1.0), 1.0]
	var out := PackedVector3Array()
	for i: int in 3:
		for j: int in 3:
			if i == 1 and j == 1: continue
			var cell: Array[Vector2] = [Vector2(sx[i], ty[j]), Vector2(sx[i + 1], ty[j]), Vector2(sx[i + 1], ty[j + 1]), Vector2(sx[i], ty[j + 1])]
			var at: Array[Vector3] = []
			var uv: Array[Vector2] = []
			for st: Vector2 in cell:
				at.append(p00.lerp(p10, st.x).lerp(p01.lerp(p11, st.x), st.y))
				uv.append(u00.lerp(u10, st.x).lerp(u01.lerp(u11, st.x), st.y))
			for tri: Array in [[0, 1, 2], [0, 2, 3]]:
				var order: Array = tri
				if (at[tri[1]] - at[tri[0]]).cross(at[tri[2]] - at[tri[0]]).dot(source_normal) < 0.0: order = [tri[0], tri[2], tri[1]]
				for k: int in order:
					tool.set_normal(source_normal); tool.set_uv(uv[k]); tool.add_vertex(at[k])
					out.append(at[k])
	return out

static func _contains(box: AABB, point: Vector3) -> bool:
	return point.x >= box.position.x and point.x <= box.end.x and point.y >= box.position.y and point.y <= box.end.y and point.z >= box.position.z and point.z <= box.end.z

static func _bounds(points: PackedVector3Array) -> AABB:
	var box := AABB(points[0], Vector3.ZERO)
	for point: Vector3 in points: box = box.expand(point)
	return box

static func _ray(faces: PackedVector3Array, origin: Vector3, direction: Vector3) -> Vector3:
	var closest := Vector3.INF
	var distance := INF
	for i: int in range(0, faces.size(), 3):
		var hit: Variant = Geometry3D.ray_intersects_triangle(origin, direction, faces[i], faces[i + 1], faces[i + 2])
		if hit is Vector3 and origin.distance_squared_to(hit) < distance:
			closest = hit; distance = origin.distance_squared_to(hit)
	return closest

static func _slice_x(faces: PackedVector3Array, height: float) -> Vector2:
	var result := Vector2(INF, -INF)
	for i: int in range(0, faces.size(), 3):
		for edge: int in 3:
			var a: Vector3 = faces[i + edge]; var b: Vector3 = faces[i + (edge + 1) % 3]
			if absf(a.y - b.y) < .000001 or height < minf(a.y, b.y) or height > maxf(a.y, b.y): continue
			var x: float = lerpf(a.x, b.x, (height - a.y) / (b.y - a.y))
			result.x = minf(result.x, x); result.y = maxf(result.y, x)
	return result
