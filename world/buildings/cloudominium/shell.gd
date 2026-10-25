extends RefCounted
## Rainbow Dash's Cloudominium opened for a walk-in interior (dev 2026-09-28). Instance only:
## the packed RNL prefab stays untouched for rollback and reuse.
## - A real doorway through Mesh1 and its collision, closed by a purple swirl leaf on the shared
##   hinged_door.gd that carries the source's rainbow door mark.
## - The tower's own painted window panes become glazed openings. The painted panes come back
##   past the interior draw distance, so from afar the exterior reads exactly as before.
## - The cloud dome, cornice discs and window/door boxes that filled the tower are cleared, and
##   two lined storeys fill it: the hall in the lower tier, the bedroom in the narrower second one.
## Measurements: tools/cloudominium/probe_shell.gd (captures/cloudominium/source-shell.json) and
## the layout.gd header. prepare() returns {"frame", "layout", "door", "frame_node", "report"}.
const LAYOUT := preload("res://world/buildings/cloudominium/layout.gd")
const MATERIALS := preload("res://world/buildings/cloudominium/materials.gd")
const DOOR := preload("res://world/buildings/hinged_door.gd")
const STATE := &"cloudominium_shell"
## Room frame in prefab space: origin on the tower axis at the hall floor (the cloud top at the
## door, prefab y 6.36); frame +Z = prefab +X (the door side), frame +X = prefab -Z.
const FRAME := Transform3D(Basis(Vector3(0, 0, -1), Vector3.UP, Vector3(1, 0, 0)), Vector3(-5.723, 6.36, -1.282))
## Clearing prisms just inside each tier's source wall (48-gon apothems) and their heights.
const SIDES := 48
const HALL_CLEAR := 3.95
const UPPER_CLEAR := 3.49
const CLEAR_BOTTOM := -0.5
const TIER_Y := 6.13      # prefab 12.49: between the lower tier's cap and the second tier
const CLEAR_TOP := 11.14  # prefab 17.5: under the second tier's top slab
const LEAF_Z := 4.1845    # the source leaf's plane (prefab x -1.5385)
const LEAF_THICKNESS := 0.08
## Openings sit this far inside the source pane edges and door jambs (measured 1 mm and
## 5..21 mm inside them), so those faces stay whole behind the new reveals.
const INSET := 0.02
const DOOR_INSET := 0.03
## Interior draw distance and hysteresis (Golden Oak's cost choice).
const DRAW := 45.0
const DRAW_MARGIN := 2.0
const LEAF_SURFACE := 9
const PANE_SURFACE := 10
const KNOB_SURFACE := 12
const MARK_SURFACE := 13
## Source counts; a changed prefab must be remeasured before cutting.
const LEAF_TRIANGLES := 14
const WINDOW_COUNT := 17

static func prepare(existing: Node3D) -> Dictionary:
	if existing.has_meta(STATE):
		return existing.get_meta(STATE)
	var view: MeshInstance3D = existing.get_node("Mesh1")
	var source: ArrayMesh = view.mesh
	var to_frame: Transform3D = FRAME.affine_inverse() * view.transform
	if not existing.global_basis.get_scale().is_equal_approx(Vector3.ONE):
		push_warning("Cloudominium placement is scaled; the metre interior assumes scale 1.")
	var layout: Dictionary = LAYOUT.defaults()
	var hall := float(layout.radius)
	var upper := float(layout.upper_radius)
	# Measure the door leaf and every window pane on the real mesh.
	var leaf := _leaf_outline(source.surface_get_arrays(LEAF_SURFACE), to_frame)
	var windows := _windows(source.surface_get_arrays(PANE_SURFACE), to_frame, hall, upper)
	assert(windows.size() == WINDOW_COUNT, "Cloudominium panes changed; remeasure before cutting")
	var left := INF
	var right := -INF
	var apex := -INF
	for point: Vector2 in leaf:
		left = minf(left, point.x)
		right = maxf(right, point.x)
		apex = maxf(apex, point.y)
	var door_x := (left + right) * 0.5
	layout.door_position = Vector3(door_x, 0, LEAF_Z)
	layout.door_width = snappedf(right - left - DOOR_INSET * 2.0, 0.01)
	layout.door_height = snappedf(apex - DOOR_INSET, 0.01)
	var door_inside: Vector3 = layout.door_inside
	var door_approach: Vector3 = layout.door_approach
	layout.door_inside = Vector3(door_x, door_inside.y, door_inside.z)
	layout.door_approach = Vector3(door_x, door_approach.y, door_approach.z)
	var listed: Array = []
	for window: Dictionary in windows:
		listed.append({"angle": window.angle, "y": window.y, "width": window.width, "height": window.height, "level": window.level})
	listed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.level < b.level or (a.level == b.level and a.y < b.y))
	layout.windows = listed
	# Everything that must go: the tower's filled inside, the doorway, the window apertures.
	var doorway := _clip_bottom(leaf, -0.35)
	var door_region := _aperture(_inset(doorway, DOOR_INSET), Vector3.BACK, 3.0, LEAF_Z - 0.012)
	var regions: Array = [_prism(HALL_CLEAR, CLEAR_BOTTOM, TIER_Y), _prism(UPPER_CLEAR, TIER_Y, CLEAR_TOP), door_region]
	for window: Dictionary in windows:
		regions.append(window.region)
	# The door mark moves onto the leaf, whose hinge is the outside-left jamb.
	var hinge := Vector3(left, 0, LEAF_Z)
	var cut := _cut_mesh(source, to_frame, regions, hinge)
	var shell: ArrayMesh = cut.mesh
	view.mesh = shell
	# The Solid trimesh (cloud layer) filled the doorway and windows: rebuild it from the cut mesh.
	var solid: StaticBody3D = existing.get_node("Solid")
	for child: Node in solid.get_children():
		solid.remove_child(child)
		child.free()
	var collision := CollisionShape3D.new()
	collision.name = "OpenedShell"
	var shape: ConcavePolygonShape3D = shell.create_trimesh_shape()
	shape.backface_collision = true
	collision.shape = shape
	solid.add_child(collision)
	# Counter-scale before any body enters the tree: Jolt keeps the scale a body entered with.
	var world_frame := Transform3D(existing.global_basis.orthonormalized() * FRAME.basis, existing.to_global(FRAME.origin))
	MATERIALS.set_room(world_frame, layout)
	var frame := Node3D.new()
	frame.name = "CloudominiumShell"
	frame.transform = existing.global_transform.affine_inverse() * world_frame
	existing.add_child(frame)
	var ground_openings: Array = [door_region]
	var upper_openings: Array = []
	for window: Dictionary in windows:
		(ground_openings if window.level == "ground" else upper_openings).append(window.region)
	_build_floors(frame, layout, left, right)
	_lining(frame, "HallLining", hall, -0.05, float(layout.upper_y), ground_openings, MATERIALS.get_material("wall"))
	_lining(frame, "BedroomLining", upper, float(layout.upper_y), float(layout.ceiling_y) + 0.05, upper_openings, MATERIALS.get_material("wall_upper"))
	_build_openings(frame, windows, door_region, hall)
	_far_panes(existing, view.transform, cut.panes)
	var door := _build_door(frame, leaf, hinge, cut.mark)
	var report: Dictionary = cut.report
	report["leaf_bounds"] = Rect2(left, 0, right - left, apex)
	report["windows"] = windows.size()
	report["layout_radius"] = hall
	var result := {"frame": world_frame, "frame_node": frame, "layout": layout, "door": door, "report": report}
	existing.set_meta(STATE, result)
	return result

## The source leaf's outline in frame (x, y): the arched plane of LEAF_SURFACE at LEAF_Z.
static func _leaf_outline(arrays: Array, to_frame: Transform3D) -> PackedVector2Array:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var points := PackedVector2Array()
	var count := 0
	for i: int in range(0, indices.size(), 3):
		var tri: Array[Vector3] = [to_frame * vertices[indices[i]], to_frame * vertices[indices[i + 1]], to_frame * vertices[indices[i + 2]]]
		if _is_leaf(tri[0], tri[1], tri[2]):
			count += 1
			for p: Vector3 in tri:
				points.append(Vector2(p.x, p.y))
	assert(count == LEAF_TRIANGLES, "Cloudominium door leaf changed; remeasure before cutting")
	return _hull(points)

static func _is_leaf(a: Vector3, b: Vector3, c: Vector3) -> bool:
	return absf(a.z - LEAF_Z) < 0.01 and absf(b.z - LEAF_Z) < 0.01 and absf(c.z - LEAF_Z) < 0.01 and (a.y + b.y + c.y) < 8.7

static func _is_pane(a: Vector3, b: Vector3, c: Vector3) -> bool:
	return (a.y + b.y + c.y) / 3.0 < CLEAR_TOP

## Painted panes below the upper ceiling, grouped by shared corners: each becomes an opening
## pushed along its own (horizontal) normal from inside the lining to just behind the pane.
static func _windows(arrays: Array, to_frame: Transform3D, hall: float, upper: float) -> Array[Dictionary]:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var parents: Dictionary = {}
	var triangles: Array = []
	for i: int in range(0, indices.size(), 3):
		var tri: Array[Vector3] = [to_frame * vertices[indices[i]], to_frame * vertices[indices[i + 1]], to_frame * vertices[indices[i + 2]]]
		if not _is_pane(tri[0], tri[1], tri[2]):
			continue
		triangles.append(tri)
		var first := _key(tri[0])
		for p: Vector3 in tri:
			_union(parents, first, _key(p))
	var groups: Dictionary = {}
	for tri: Array in triangles:
		var root := _find(parents, _key(tri[0]))
		if not groups.has(root):
			groups[root] = []
		(groups[root] as Array).append(tri)
	var result: Array[Dictionary] = []
	for root: Vector3i in groups:
		var normal := Vector3.ZERO
		var middle := Vector3.ZERO
		var count := 0
		for tri: Array in groups[root]:
			var a: Vector3 = tri[0]
			var b: Vector3 = tri[1]
			var c: Vector3 = tri[2]
			normal += (b - a).cross(c - a)
			middle += a + b + c
			count += 3
		middle /= float(count)
		normal.y = 0.0
		normal = normal.normalized()
		if normal.dot(Vector3(middle.x, 0, middle.z)) < 0.0:
			normal = -normal
		var tangent := Vector3.UP.cross(normal)
		var flat := PackedVector2Array()
		var depth := 0.0
		for tri: Array in groups[root]:
			for p: Vector3 in tri:
				flat.append(Vector2(tangent.dot(p), p.y))
				depth += normal.dot(p) / float(count)
		var outline := _hull(flat)
		var bounds := Rect2(outline[0], Vector2.ZERO)
		for point: Vector2 in outline:
			bounds = bounds.expand(point)
		var level := "ground" if middle.y < TIER_Y else "upper"
		var radius := hall if level == "ground" else upper
		# Where the opening's centre line meets the lining: architecture trims centre there.
		var across := bounds.get_center().x
		var centre := tangent * across + normal * sqrt(radius * radius - across * across)
		result.append({"angle": snappedf(rad_to_deg(atan2(centre.x, centre.z)), 0.1), "y": snappedf(bounds.get_center().y, 0.01),
			"width": snappedf(bounds.size.x, 0.01), "height": snappedf(bounds.size.y, 0.01), "level": level, "depth": depth,
			"region": _aperture(_inset(outline, INSET), normal, radius - 0.35, depth - 0.012)})
	return result

static func _key(p: Vector3) -> Vector3i:
	return Vector3i(roundi(p.x * 1000.0), roundi(p.y * 1000.0), roundi(p.z * 1000.0))

static func _find(parents: Dictionary, key: Vector3i) -> Vector3i:
	var at := key
	while parents.has(at) and parents[at] != at:
		at = parents[at]
	parents[key] = at
	return at

static func _union(parents: Dictionary, a: Vector3i, b: Vector3i) -> void:
	var ra := _find(parents, a)
	var rb := _find(parents, b)
	parents[ra] = ra
	parents[rb] = ra

## Counter-clockwise convex hull (y up), without the repeated closing point.
static func _hull(points: PackedVector2Array) -> PackedVector2Array:
	var hull := Geometry2D.convex_hull(points)
	if hull.size() > 1 and hull[0] == hull[hull.size() - 1]:
		hull.remove_at(hull.size() - 1)
	return _ccw(hull)

static func _ccw(polygon: PackedVector2Array) -> PackedVector2Array:
	var area := 0.0
	for i: int in polygon.size():
		var a := polygon[i]
		var b := polygon[(i + 1) % polygon.size()]
		area += a.x * b.y - b.x * a.y
	if area < 0.0:
		polygon.reverse()
	return polygon

static func _inset(polygon: PackedVector2Array, amount: float) -> PackedVector2Array:
	var shrunk: Array[PackedVector2Array] = Geometry2D.offset_polygon(polygon, -amount, Geometry2D.JOIN_MITER)
	return _ccw(shrunk[0])

## The part of a convex outline at or above `bottom`.
static func _clip_bottom(polygon: PackedVector2Array, bottom: float) -> PackedVector2Array:
	var above := PackedVector2Array([Vector2(-50, bottom), Vector2(50, bottom), Vector2(50, 50), Vector2(-50, 50)])
	var parts: Array[PackedVector2Array] = Geometry2D.intersect_polygons(polygon, above)
	return _ccw(parts[0])

## Convex region: an N-gon prism around the tower axis.
static func _prism(apothem: float, bottom: float, top: float) -> Dictionary:
	var planes: Array[Plane] = [Plane(Vector3.UP, top), Plane(Vector3.DOWN, -bottom)]
	for i: int in SIDES:
		var angle := TAU * i / SIDES
		planes.append(Plane(Vector3(sin(angle), 0, cos(angle)), apothem))
	var reach := apothem / cos(PI / SIDES)
	return {"planes": planes, "box": AABB(Vector3(-reach, bottom, -reach), Vector3(reach * 2.0, top - bottom, reach * 2.0)).grow(0.01),
		"apothem": apothem, "reach": reach, "bottom": bottom, "top": top}

## Convex region: a counter-clockwise outline in (tangent, height) pushed along a horizontal
## `normal` from depth `near` to `far`, measured from the tower axis.
static func _aperture(outline: PackedVector2Array, normal: Vector3, near: float, far: float) -> Dictionary:
	var tangent := Vector3.UP.cross(normal)
	var planes: Array[Plane] = [Plane(normal, far), Plane(-normal, -near)]
	var box := AABB(tangent * outline[0].x + Vector3.UP * outline[0].y + normal * near, Vector3.ZERO)
	for i: int in outline.size():
		var a := outline[i]
		var edge := outline[(i + 1) % outline.size()] - a
		var out := Vector2(edge.y, -edge.x).normalized()
		planes.append(Plane(tangent * out.x + Vector3.UP * out.y, out.dot(a)))
		for depth: float in [near, far]:
			box = box.expand(tangent * a.x + Vector3.UP * a.y + normal * depth)
	return {"planes": planes, "box": box.grow(0.01), "outline": outline, "normal": normal, "tangent": tangent, "near": near, "far": far}

## Pieces of a convex polygon ([position, normal, uv] vertices) outside a convex region.
## Returns [polygon] itself when some plane has it wholly outside.
static func _subtract(polygon: Array, planes: Array) -> Array:
	for plane: Plane in planes:
		var clear := true
		for vertex: Array in polygon:
			if plane.distance_to(vertex[0]) <= 0.0:
				clear = false
				break
		if clear:
			return [polygon]
	var outside: Array = []
	var remaining := polygon
	for plane: Plane in planes:
		var inside: Array = []
		var cut: Array = []
		for i: int in remaining.size():
			var a: Array = remaining[i]
			var b: Array = remaining[(i + 1) % remaining.size()]
			var da := plane.distance_to(a[0])
			var db := plane.distance_to(b[0])
			if da <= 0.0:
				inside.append(a)
			else:
				cut.append(a)
			if (da <= 0.0) != (db <= 0.0):
				var t := da / (da - db)
				var pa: Vector3 = a[0]
				var na: Vector3 = a[1]
				var ua: Vector2 = a[2]
				var middle: Array = [pa.lerp(b[0], t), na.lerp(b[1], t).normalized(), ua.lerp(b[2], t)]
				inside.append(middle)
				cut.append(middle)
		if cut.size() >= 3:
			outside.append(cut)
		remaining = inside
		if remaining.size() < 3:
			break
	return outside

## Pieces of a polygon outside every region. Prisms first test the polygon's distance from the
## tower axis, so the tower's own wall and far cloud skip their 50 planes.
static func _outside(polygon: Array, regions: Array) -> Array:
	var box := AABB(polygon[0][0], Vector3.ZERO)
	var far_axis := 0.0
	for vertex: Array in polygon:
		var p: Vector3 = vertex[0]
		box = box.expand(p)
		far_axis = maxf(far_axis, Vector2(p.x, p.z).length())
	box = box.grow(0.001)
	var near_axis := -1.0
	var pieces: Array = [polygon]
	for region: Dictionary in regions:
		var region_box: AABB = region.box
		if not region_box.intersects(box):
			continue
		if region.has("apothem") and pieces.size() == 1 and is_same(pieces[0], polygon):
			if near_axis < 0.0:
				near_axis = _axis_distance(polygon)
			if near_axis > float(region.reach):
				continue
			if far_axis <= float(region.apothem) and box.position.y >= float(region.bottom) and box.end.y <= float(region.top):
				return []
		var next: Array = []
		for piece: Array in pieces:
			next.append_array(_subtract(piece, region.planes))
		pieces = next
		if pieces.is_empty():
			break
	return pieces

## Horizontal distance from the tower axis to the nearest point of a polygon.
static func _axis_distance(polygon: Array) -> float:
	var flat := PackedVector2Array()
	for vertex: Array in polygon:
		var p: Vector3 = vertex[0]
		flat.append(Vector2(p.x, p.z))
	if flat.size() == 3 and Geometry2D.point_is_inside_triangle(Vector2.ZERO, flat[0], flat[1], flat[2]):
		return 0.0
	var nearest := INF
	for i: int in flat.size():
		nearest = minf(nearest, Geometry2D.get_closest_point_to_segment(Vector2.ZERO, flat[i], flat[(i + 1) % flat.size()]).length())
	return nearest

## Cuts every source surface: unchanged surfaces keep their native buffers and LODs; changed
## ones regenerate LODs with the scenery builder's recipe, so no distant LOD restores a pane,
## the leaf or the cleared inside. Also returns the panes (far view, mesh space) and the door
## mark (relative to the hinge) as meshes.
static func _cut_mesh(source: ArrayMesh, to_frame: Transform3D, regions: Array, hinge: Vector3) -> Dictionary:
	var from_frame := to_frame.affine_inverse()
	var reach := AABB()
	for i: int in regions.size():
		var box: AABB = regions[i].box
		reach = box if i == 0 else reach.merge(box)
	var native: Array = source.get("_surfaces")
	var surfaces: Array = []
	var panes := SurfaceTool.new()
	panes.begin(Mesh.PRIMITIVE_TRIANGLES)
	panes.set_material(source.surface_get_material(PANE_SURFACE))
	var mark := SurfaceTool.new()
	mark.begin(Mesh.PRIMITIVE_TRIANGLES)
	mark.set_material(source.surface_get_material(MARK_SURFACE))
	var report := {"source_triangles": 0, "kept_triangles": 0, "cut_triangles": 0, "cleared_triangles": 0,
		"leaf_triangles": 0, "knob_triangles": 0, "mark_triangles": 0, "pane_triangles": 0, "rebuilt_surfaces": []}
	for s: int in source.get_surface_count():
		var arrays: Array = source.surface_get_arrays(s)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if uvs.size() != vertices.size():
			uvs.resize(vertices.size())
		var framed := PackedVector3Array()
		framed.resize(vertices.size())
		for i: int in vertices.size():
			framed[i] = to_frame * vertices[i]
		var out := SurfaceTool.new()
		out.begin(Mesh.PRIMITIVE_TRIANGLES)
		var written := 0
		var changed := false
		for i: int in range(0, indices.size(), 3):
			report.source_triangles += 1
			var corners: Array[int] = [indices[i], indices[i + 1], indices[i + 2]]
			var a := framed[corners[0]]
			var b := framed[corners[1]]
			var c := framed[corners[2]]
			if s == KNOB_SURFACE:
				# The new leaf has hinged_door.gd's real pulls.
				report.knob_triangles += 1
				changed = true
				continue
			if s == MARK_SURFACE:
				for k: int in corners:
					_emit(mark, framed[k] - hinge, to_frame.basis * normals[k], uvs[k])
				report.mark_triangles += 1
				changed = true
				continue
			if s == LEAF_SURFACE and _is_leaf(a, b, c):
				report.leaf_triangles += 1
				changed = true
				continue
			if s == PANE_SURFACE and _is_pane(a, b, c):
				for k: int in corners:
					_emit(panes, vertices[k], normals[k], uvs[k])
				report.pane_triangles += 1
				changed = true
				continue
			var polygon: Array = [[a, normals[corners[0]], uvs[corners[0]]], [b, normals[corners[1]], uvs[corners[1]]], [c, normals[corners[2]], uvs[corners[2]]]]
			var pieces: Array = [polygon]
			if reach.intersects(AABB(a, Vector3.ZERO).expand(b).expand(c).grow(0.001)):
				pieces = _outside(polygon, regions)
			if pieces.size() == 1 and is_same(pieces[0], polygon):
				for k: int in corners:
					_emit(out, vertices[k], normals[k], uvs[k])
				written += 1
				report.kept_triangles += 1
				continue
			changed = true
			if pieces.is_empty():
				report.cleared_triangles += 1
				continue
			report.cut_triangles += 1
			for piece: Array in pieces:
				for j: int in range(1, piece.size() - 1):
					for vertex: Array in [piece[0], piece[j], piece[j + 1]]:
						var at: Vector3 = vertex[0]
						_emit(out, from_frame * at, vertex[1], vertex[2])
					written += 1
		if not changed:
			surfaces.append(native[s])
			continue
		if written == 0:
			continue
		(report.rebuilt_surfaces as Array).append(s)
		out.index()
		var importer := ImporterMesh.new()
		importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, out.commit_to_arrays(), [], {}, source.surface_get_material(s))
		importer.generate_lods(60.0, 25.0, [])
		var optimized: ArrayMesh = importer.get_mesh()
		var generated: Array = optimized.get("_surfaces")
		surfaces.append(generated[0])
	var shell := ArrayMesh.new()
	shell.set("_surfaces", surfaces)
	var pane_mesh: ArrayMesh = panes.commit() if report.pane_triangles > 0 else null
	var mark_mesh: ArrayMesh = mark.commit() if report.mark_triangles > 0 else null
	return {"mesh": shell, "panes": pane_mesh, "mark": mark_mesh, "report": report}

static func _emit(st: SurfaceTool, position: Vector3, normal: Vector3, uv: Vector2) -> void:
	st.set_normal(normal)
	st.set_uv(uv)
	st.add_vertex(position)

## Interior pieces draw within DRAW metres and never join the outdoor shadow pass.
static func _indoor(visual: GeometryInstance3D) -> void:
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visual.visibility_range_end = DRAW
	visual.visibility_range_end_margin = DRAW_MARGIN

static func _visual(parent: Node3D, label: String, mesh: Mesh) -> MeshInstance3D:
	var visual := MeshInstance3D.new()
	visual.name = label
	visual.mesh = mesh
	_indoor(visual)
	parent.add_child(visual)
	return visual

## Layer-1 world body: walls block and floors carry Anon, ponies and loose objects.
static func _body(parent: Node3D, label: String, shape: Shape3D, at: Transform3D = Transform3D.IDENTITY) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = label
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.transform = at
	body.add_child(collision)
	parent.add_child(body)
	return body

static func _trimesh(parent: Node3D, label: String, mesh: Mesh) -> void:
	var shape: ConcavePolygonShape3D = mesh.create_trimesh_shape()
	shape.backface_collision = true
	_body(parent, label, shape)

static func _quad(st: SurfaceTool, points: Array, normal: Vector3) -> void:
	_triangle(st, [points[0], points[1], points[2]], normal)
	_triangle(st, [points[0], points[2], points[3]], normal)

static func _triangle(st: SurfaceTool, points: Array, normal: Vector3) -> void:
	for p: Vector3 in points:
		st.set_normal(normal)
		st.set_uv(Vector2(p.x, p.z))
		st.add_vertex(p)

## Hall floor disc, the threshold through the doorway, the upper floor with its stair hole
## (its underside is the hall ceiling) and the bedroom ceiling.
static func _build_floors(frame: Node3D, layout: Dictionary, left: float, right: float) -> void:
	var ground := SurfaceTool.new()
	ground.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segments := 96
	for i: int in segments:
		var a := TAU * i / segments
		var b := TAU * (i + 1) / segments
		var points: Array[Vector3] = [Vector3.ZERO, Vector3(sin(b), 0, cos(b)) * HALL_CLEAR, Vector3(sin(a), 0, cos(a)) * HALL_CLEAR]
		for p: Vector3 in points:
			ground.set_normal(Vector3.UP)
			ground.set_uv(Vector2(p.x, p.z))
			ground.add_vertex(p)
	# Threshold: level to the leaf, then easing down into the cloud outside (it stands 6.26..6.43
	# at the leaf), so no lip catches a hoof or foot. Slightly below the disc where they overlap.
	var x0 := left - INSET
	var x1 := right + INSET
	var inner := 3.75
	var outer := LEAF_Z + 0.48
	var top := -0.003
	var toe := -0.22
	var base := -0.3
	var sill: Array[Vector3] = [Vector3(x0, top, inner), Vector3(x1, top, inner), Vector3(x1, top, LEAF_Z), Vector3(x0, top, LEAF_Z),
		Vector3(x0, toe, outer), Vector3(x1, toe, outer), Vector3(x0, base, inner), Vector3(x1, base, inner), Vector3(x0, base, outer), Vector3(x1, base, outer)]
	_quad(ground, [sill[0], sill[1], sill[2], sill[3]], Vector3.UP)
	var slope := Vector3(0, outer - LEAF_Z, top - toe).normalized()
	_quad(ground, [sill[3], sill[2], sill[5], sill[4]], slope)
	_quad(ground, [sill[4], sill[5], sill[9], sill[8]], Vector3.BACK)
	ground.set_material(MATERIALS.get_material("floor_ground"))
	var hall_floor := _visual(frame, "HallFloor", ground.commit())
	var disc := CylinderShape3D.new()
	disc.radius = HALL_CLEAR
	disc.height = 0.3
	_body(hall_floor, "HallFloorBody", disc, Transform3D(Basis.IDENTITY, Vector3(0, -0.15, 0)))
	var step := ConvexPolygonShape3D.new()
	step.points = PackedVector3Array(sill)
	_body(hall_floor, "ThresholdBody", step)
	_upper_floor(frame, layout)
	var ceiling := SurfaceTool.new()
	ceiling.begin(Mesh.PRIMITIVE_TRIANGLES)
	var height := float(layout.ceiling_y)
	for i: int in segments:
		var a := TAU * i / segments
		var b := TAU * (i + 1) / segments
		var points: Array[Vector3] = [Vector3(0, height, 0), Vector3(sin(a) * UPPER_CLEAR, height, cos(a) * UPPER_CLEAR), Vector3(sin(b) * UPPER_CLEAR, height, cos(b) * UPPER_CLEAR)]
		for p: Vector3 in points:
			ceiling.set_normal(Vector3.DOWN)
			ceiling.set_uv(Vector2(p.x, p.z))
			ceiling.add_vertex(p)
	ceiling.set_material(MATERIALS.get_material("ceiling"))
	var bedroom_ceiling := _visual(frame, "BedroomCeiling", ceiling.commit())
	var lid := CylinderShape3D.new()
	lid.radius = UPPER_CLEAR
	lid.height = 0.1
	_body(bedroom_ceiling, "BedroomCeilingBody", lid, Transform3D(Basis.IDENTITY, Vector3(0, height + 0.05, 0)))

## Upper floor slab from the hall ceiling to the bedroom floor, under the bedroom wall to the
## hall wall, open over the stair (layout.stair_hole) with rims round the opening.
static func _upper_floor(frame: Node3D, layout: Dictionary) -> void:
	var hole: Dictionary = layout.stair_hole
	var top := float(layout.upper_y)
	var under := float(layout.ground_ceiling_y)
	var start := deg_to_rad(float(hole.start_angle))
	var finish := start + fposmod(deg_to_rad(float(hole.end_angle)) - start, TAU)
	var hole_in := float(hole.inner_radius)
	var hole_out := float(hole.outer_radius)
	var angles: Array[float] = []
	var steps := 72
	for i: int in steps + 1:
		angles.append(start + TAU * i / steps)
	var near := false
	for angle: float in angles:
		near = near or absf(angle - finish) < 0.0001
	if not near:
		angles.append(finish)
	angles.sort()
	var radii: Array[float] = [0.0, hole_in, hole_out, HALL_CLEAR]
	var floor_top := SurfaceTool.new()
	floor_top.begin(Mesh.PRIMITIVE_TRIANGLES)
	var soffit := SurfaceTool.new()
	soffit.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i: int in angles.size() - 1:
		var a := angles[i]
		var b := angles[i + 1]
		var in_hole := (a + b) * 0.5 < finish
		for k: int in radii.size() - 1:
			if in_hole and k == 1:
				continue
			var r0 := radii[k]
			var r1 := radii[k + 1]
			# Seen from above increasing angle turns anticlockwise, so r0a, r0b, r1b, r1a winds
			# clockwise: Godot's front face, upwards. The centre cell is a fan triangle.
			if r0 == 0.0:
				_triangle(floor_top, [_polar(0, a, top), _polar(r1, b, top), _polar(r1, a, top)], Vector3.UP)
				_triangle(soffit, [_polar(0, a, under), _polar(r1, a, under), _polar(r1, b, under)], Vector3.DOWN)
				continue
			_quad(floor_top, [_polar(r0, a, top), _polar(r0, b, top), _polar(r1, b, top), _polar(r1, a, top)], Vector3.UP)
			_quad(soffit, [_polar(r0, a, under), _polar(r1, a, under), _polar(r1, b, under), _polar(r0, b, under)], Vector3.DOWN)
		if in_hole:
			# Rims: inner and outer arcs of the opening.
			var mid := (a + b) * 0.5
			_quad(soffit, [_polar(hole_in, a, under), _polar(hole_in, b, under), _polar(hole_in, b, top), _polar(hole_in, a, top)], _polar(1.0, mid, 0))
			_quad(soffit, [_polar(hole_out, b, under), _polar(hole_out, a, under), _polar(hole_out, a, top), _polar(hole_out, b, top)], -_polar(1.0, mid, 0))
	for end: float in [start, finish]:
		var side := Vector3(cos(end), 0, -sin(end)) * (1.0 if end == start else -1.0)
		_quad(soffit, [_polar(hole_in, end, under), _polar(hole_out, end, under), _polar(hole_out, end, top), _polar(hole_in, end, top)], side)
	floor_top.set_material(MATERIALS.get_material("floor_upper"))
	soffit.set_material(MATERIALS.get_material("ceiling"))
	var mesh: ArrayMesh = floor_top.commit()
	soffit.commit(mesh)
	var view := _visual(frame, "UpperFloor", mesh)
	_trimesh(view, "UpperFloorBody", mesh)

static func _polar(radius: float, angle: float, y: float) -> Vector3:
	return Vector3(sin(angle) * radius, y, cos(angle) * radius)

## One storey's inward-facing lining between `bottom` and `top`, holed by `openings`.
## The painted room material maps it by position, so its UVs are only arc/height metres.
static func _lining(frame: Node3D, label: String, radius: float, bottom: float, top: float, openings: Array, material: Material) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(material)
	var segments := 96
	var rows := maxi(1, ceili((top - bottom) / 0.5))
	for i: int in segments:
		var a0 := TAU * i / segments
		var a1 := TAU * (i + 1) / segments
		for j: int in rows:
			var y0 := lerpf(bottom, top, float(j) / rows)
			var y1 := lerpf(bottom, top, float(j + 1) / rows)
			var p00 := _polar(radius, a0, y0)
			var p10 := _polar(radius, a1, y0)
			var p11 := _polar(radius, a1, y1)
			var p01 := _polar(radius, a0, y1)
			# Increasing angle runs to the left of a viewer inside: a, b, c wind towards them.
			for tri: Array in [[p00, p10, p11], [p00, p11, p01]]:
				var polygon: Array = []
				for p: Vector3 in tri:
					polygon.append([p, Vector3(-p.x, 0, -p.z).normalized(), Vector2(atan2(p.x, p.z) * radius, -p.y)])
				for piece: Array in _outside(polygon, openings):
					for k: int in range(1, piece.size() - 1):
						for vertex: Array in [piece[0], piece[k], piece[k + 1]]:
							st.set_normal(vertex[1])
							st.set_uv(vertex[2])
							st.add_vertex(vertex[0])
	var mesh := st.commit()
	var view := _visual(frame, label, mesh)
	_trimesh(view, label + "Body", mesh)

## Reveals from the lining to the glass or the leaf in wall paint, and the clear panes.
static func _build_openings(frame: Node3D, windows: Array[Dictionary], door: Dictionary, hall: float) -> void:
	var reveals := SurfaceTool.new()
	reveals.begin(Mesh.PRIMITIVE_TRIANGLES)
	var upper_reveals := SurfaceTool.new()
	upper_reveals.begin(Mesh.PRIMITIVE_TRIANGLES)
	var glass := SurfaceTool.new()
	glass.begin(Mesh.PRIMITIVE_TRIANGLES)
	_reveal(reveals, door, hall, LEAF_Z)
	for window: Dictionary in windows:
		var region: Dictionary = window.region
		var ground: bool = window.level == "ground"
		_reveal(reveals if ground else upper_reveals, region, float(region.near) + 0.35, float(window.depth) - 0.012)
		var outline: PackedVector2Array = region.outline
		var tangent: Vector3 = region.tangent
		var normal: Vector3 = region.normal
		var depth := float(window.depth) - 0.012
		var middle := Vector2.ZERO
		for point: Vector2 in outline:
			middle += point / float(outline.size())
		for i: int in outline.size():
			for point: Vector2 in [middle, outline[i], outline[(i + 1) % outline.size()]]:
				glass.set_normal(normal)
				glass.set_uv(point)
				glass.add_vertex(tangent * point.x + Vector3.UP * point.y + normal * depth)
	reveals.set_material(MATERIALS.get_material("wall"))
	upper_reveals.set_material(MATERIALS.get_material("wall_upper"))
	var mesh: ArrayMesh = reveals.commit()
	upper_reveals.commit(mesh)
	var view := _visual(frame, "OpeningReveals", mesh)
	_trimesh(view, "OpeningRevealsBody", mesh)
	glass.set_material(MATERIALS.get_material("glass"))
	var panes: ArrayMesh = glass.commit()
	var pane_view := _visual(frame, "WindowGlass", panes)
	_trimesh(pane_view, "WindowGlassBody", panes)

## Band round an opening's outline from the lining cylinder out to depth `far`, lit as seen
## from inside the opening (smooth round the arch).
static func _reveal(st: SurfaceTool, region: Dictionary, radius: float, far: float) -> void:
	var outline: PackedVector2Array = region.outline
	var tangent: Vector3 = region.tangent
	var normal: Vector3 = region.normal
	var count := outline.size()
	var facing: Array[Vector3] = []
	for i: int in count:
		var before := outline[i] - outline[(i + count - 1) % count]
		var after := outline[(i + 1) % count] - outline[i]
		var into := (Vector2(-before.y, before.x).normalized() + Vector2(-after.y, after.x).normalized()).normalized()
		facing.append(tangent * into.x + Vector3.UP * into.y)
	for i: int in count:
		var j := (i + 1) % count
		var a := outline[i]
		var b := outline[j]
		var corners: Array[Vector3] = [
			tangent * a.x + Vector3.UP * a.y + normal * sqrt(maxf(radius * radius - a.x * a.x, 0.0)),
			tangent * a.x + Vector3.UP * a.y + normal * far,
			tangent * b.x + Vector3.UP * b.y + normal * far,
			tangent * b.x + Vector3.UP * b.y + normal * sqrt(maxf(radius * radius - b.x * b.x, 0.0))]
		var shading: Array[Vector3] = [facing[i], facing[i], facing[j], facing[j]]
		for k: int in [0, 1, 2, 0, 2, 3]:
			st.set_normal(shading[k])
			st.set_uv(Vector2(corners[k].y, normal.dot(corners[k])))
			st.add_vertex(corners[k])

## The removed painted panes, shown only beyond the interior draw distance.
static func _far_panes(existing: Node3D, placement: Transform3D, panes: ArrayMesh) -> void:
	if panes == null:
		return
	var view := MeshInstance3D.new()
	view.name = "FarWindowPanes"
	view.mesh = panes
	view.transform = placement
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	view.visibility_range_begin = DRAW
	view.visibility_range_begin_margin = DRAW_MARGIN
	existing.add_child(view)

## Purple swirl leaf in the source leaf's arch, hinged at the outside-left jamb and swinging
## into the hall, carrying the source's rainbow door mark (it overhangs the leaf top, so it
## must move with it). The swirl panels tile from the leaf's centre line, reading as the
## reference's pair of tall doors.
static func _build_door(frame: Node3D, leaf: PackedVector2Array, at: Vector3, mark: ArrayMesh) -> AnimatableBody3D:
	var outline := _clip_bottom(leaf, 0.012)
	var left := INF
	var right := -INF
	var apex := -INF
	for point: Vector2 in outline:
		left = minf(left, point.x)
		right = maxf(right, point.x)
		apex = maxf(apex, point.y)
	var width := right - left
	var hinge := Node3D.new()
	hinge.name = "DoorHinge"
	hinge.position = at
	frame.add_child(hinge)
	var door: AnimatableBody3D = DOOR.new()
	door.name = "CloudominiumDoor"
	door.swing_direction = 1.0
	var centred := PackedVector2Array()
	for point: Vector2 in outline:
		centred.append(Vector2(point.x - left - width * 0.5, point.y))
	var art := MeshInstance3D.new()
	art.name = "OriginalDoorArtwork"
	art.mesh = _slab(centred, LEAF_THICKNESS, MATERIALS.get_material("door_purple"))
	art.position = Vector3(width * 0.5, 0, 0)
	door.add_child(art)
	if mark != null:
		var badge := MeshInstance3D.new()
		badge.name = "DoorMark"
		badge.mesh = mark
		door.add_child(badge)
	var collision := CollisionShape3D.new()
	collision.name = "LeafCollision"
	var shape := ConvexPolygonShape3D.new()
	var points := PackedVector3Array()
	for point: Vector2 in outline:
		points.append(Vector3(point.x - left, point.y, 0))
		points.append(Vector3(point.x - left, point.y, -LEAF_THICKNESS))
	shape.points = points
	collision.shape = shape
	door.add_child(collision)
	door.handle = Vector3(width - 0.24, 1.05, 0)
	door.navigation_box = AABB(Vector3(-0.15, -0.1, -width), Vector3(width + 0.3, apex + 0.2, width * 2.0))
	hinge.add_child(door)
	return door

## Closed slab from a convex outline: front face on z 0 (outside), back on -depth.
static func _slab(outline: PackedVector2Array, depth: float, material: Material) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(material)
	var count := outline.size()
	var bounds := Rect2(outline[0], Vector2.ZERO)
	for point: Vector2 in outline:
		bounds = bounds.expand(point)
	for face: float in [0.0, -depth]:
		var normal := Vector3.BACK if face == 0.0 else Vector3.FORWARD
		for i: int in range(1, count - 1):
			for point: Vector2 in [outline[0], outline[i], outline[i + 1]]:
				st.set_normal(normal)
				st.set_uv((point - bounds.position) / bounds.size * Vector2(1, -1) + Vector2(0, 1))
				st.add_vertex(Vector3(point.x, point.y, face))
	for i: int in count:
		var a := outline[i]
		var b := outline[(i + 1) % count]
		var edge := b - a
		var normal := Vector3(edge.y, -edge.x, 0).normalized()
		var corners: Array[Vector3] = [Vector3(a.x, a.y, 0), Vector3(a.x, a.y, -depth), Vector3(b.x, b.y, -depth), Vector3(b.x, b.y, 0)]
		for k: int in [0, 1, 2, 0, 2, 3]:
			st.set_normal(normal)
			st.set_uv(Vector2(corners[k].x, corners[k].z))
			st.add_vertex(corners[k])
	return st.commit()
