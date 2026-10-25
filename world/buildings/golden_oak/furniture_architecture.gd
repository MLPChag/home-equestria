extends RefCounted
## Geometry in the shell's unit-scale room frame. The stair opening stays open overhead.
const KIT := preload("res://world/buildings/golden_oak/furniture_kit.gd")
const REFERENCE := preload("res://world/buildings/golden_oak/reference_furniture.gd")

static func polar(radius: float, angle: float, y: float) -> Vector3:
	return Vector3(sin(angle) * radius, y, cos(angle) * radius)

static func prism(parent: Node3D, label_text: String, polygon: PackedVector2Array, top: float, depth: float, finish: Material, collision: bool = true) -> MeshInstance3D:
	var triangles := Geometry2D.triangulate_polygon(polygon)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(finish)
	for offset in range(0, triangles.size(), 3):
		for index: int in [triangles[offset], triangles[offset + 1], triangles[offset + 2]]:
			var point := polygon[index]
			st.add_vertex(Vector3(point.x, top, point.y))
		for index: int in [triangles[offset + 2], triangles[offset + 1], triangles[offset]]:
			var point := polygon[index]
			st.add_vertex(Vector3(point.x, top - depth, point.y))
	for index: int in polygon.size():
		var a := polygon[index]
		var b := polygon[(index + 1) % polygon.size()]
		for point: Vector3 in [Vector3(a.x, top, a.y), Vector3(b.x, top - depth, b.y), Vector3(b.x, top, b.y), Vector3(a.x, top, a.y), Vector3(a.x, top - depth, a.y), Vector3(b.x, top - depth, b.y)]:
			st.add_vertex(point)
	st.generate_normals()
	var visual := MeshInstance3D.new()
	visual.name = label_text
	visual.mesh = st.commit()
	parent.add_child(visual)
	if collision:
		visual.create_trimesh_collision()
	return visual

static func rail(parent: Node3D, points: PackedVector3Array, finish: Material, label_text: String) -> void:
	var handrail := PackedVector3Array()
	for point: Vector3 in points:
		handrail.append(point + Vector3.UP * 1.02)
	KIT.tube(parent, label_text + "Handrail", handrail, 0.055, finish)
	var last_post := Vector3.INF
	for index: int in points.size():
		var point := points[index]
		if point.distance_to(last_post) > 0.7 or index == points.size() - 1:
			KIT.tube(parent, label_text + "Post", PackedVector3Array([point, point + Vector3.UP * 1.03]), 0.045, finish)
			last_post = point
		if index == 0:
			continue
		var a := points[index - 1]
		var delta := point - a
		var body := KIT.box_body(parent, label_text + "Guard", Vector3(0.075, 1.04, delta.length() + 0.015), (a + point) * 0.5 + Vector3.UP * 0.52)
		body.basis = Basis.looking_at(delta.normalized(), Vector3.UP)

static func build(parent: Node3D, radius: float, loft_y: float) -> Array[Vector3]:
	var wood := KIT.material("be5755")
	var light_wood := KIT.material("f0a185")
	var tread_wood := KIT.material("b54d54")
	var outer := radius - 0.15
	var stair_outer := radius - 0.3
	var stair_inner := radius - 2.1
	var centre := (stair_outer + stair_inner) * 0.5
	var opening_radius := stair_inner - 0.18
	var start := deg_to_rad(-35.0)
	var end := deg_to_rad(-145.0)
	var loft_start := acos(-0.7 / outer)
	var loft_end := end + TAU
	var notch_end := TAU - acos(-0.7 / opening_radius)
	var outline := PackedVector2Array()
	for index: int in 41:
		var point := polar(outer, lerpf(loft_start, loft_end, index / 40.0), loft_y)
		outline.append(Vector2(point.x, point.z))
	for index: int in 17:
		var point := polar(opening_radius, lerpf(loft_end, notch_end, index / 16.0), loft_y)
		outline.append(Vector2(point.x, point.z))
	# Geometry2D expects a simple counterclockwise outline in its own 2D plane.
	if Geometry2D.is_polygon_clockwise(outline):
		outline.reverse()
	prism(parent, "CarvedLoftFloor", outline, loft_y, 0.24, wood)
	var front := PackedVector3Array()
	var front_left := polar(opening_radius, notch_end, loft_y)
	var front_right := polar(outer, loft_start, loft_y)
	for index: int in 21:
		front.append(front_left.lerp(front_right, index / 20.0))
	rail(parent, front, light_wood, "Balcony")
	var notch := PackedVector3Array()
	for index: int in 17:
		notch.append(polar(opening_radius, lerpf(notch_end, loft_end, index / 16.0), loft_y))
	rail(parent, notch, light_wood, "StairWell")
	# Keep the radial landing edge open: it is the sole transition onto the loft.
	# Reach loft height two treads early: the capsule needs a flat approach before
	# its rounded foot touches the landing prism and the loft's vertical edge.
	var steps := ceili(loft_y / 0.15)
	var path: Array[Vector3] = []
	var inner_rail := PackedVector3Array()
	var outer_rail := PackedVector3Array()
	var ramp := SurfaceTool.new()
	ramp.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index: int in steps + 1:
		var angle: float = lerpf(start, end, float(index) / steps)
		var height := minf(loft_y, loft_y * index / (steps - 2))
		path.append(polar(centre, angle, height))
		inner_rail.append(polar(stair_inner, angle, height))
		outer_rail.append(polar(stair_outer, angle, height))
		if index == steps:
			continue
		var next_angle := lerpf(start, end, float(index + 1) / steps)
		var next_height := minf(loft_y, loft_y * (index + 1) / (steps - 2))
		var footprint := PackedVector2Array()
		for point: Vector3 in [polar(stair_inner, angle, 0), polar(stair_outer, angle, 0), polar(stair_outer, next_angle, 0), polar(stair_inner, next_angle, 0)]:
			footprint.append(Vector2(point.x, point.z))
		if Geometry2D.is_polygon_clockwise(footprint):
			footprint.reverse()
		# Visible treads over one welded ramp surface; separate convex hulls round off
		# their touching edges in Jolt and left ray/capsule support gaps at the joints.
		prism(parent, "StairTread%02d" % index, footprint, next_height, 0.16, tread_wood, false)
		# A deep carved redwood riser and rounded peach nosing replace thin modern planks.
		# Both are visual only; the continuous ramp and exact original treads stay fixed.
		var riser := PackedVector3Array([polar(stair_inner + 0.03, angle, next_height - 0.105), polar(centre, angle, next_height - 0.105), polar(stair_outer - 0.03, angle, next_height - 0.105)])
		KIT.tube(parent, "CarvedStairRiser", riser, 0.105, tread_wood)
		KIT.tube(parent, "RoundedStairNosing", PackedVector3Array([polar(stair_inner + 0.04, angle, next_height - 0.02), polar(stair_outer - 0.04, angle, next_height - 0.02)]), 0.027, light_wood)
		var a := polar(stair_inner, angle, height)
		var b := polar(stair_outer, angle, height)
		var c := polar(stair_outer, next_angle, next_height)
		var d := polar(stair_inner, next_angle, next_height)
		for point: Vector3 in [a, b, c, a, c, d]:
			ramp.add_vertex(point)
	ramp.index()
	var body := StaticBody3D.new()
	body.name = "ContinuousStairRamp"
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	collision.shape = ramp.commit().create_trimesh_shape()
	body.add_child(collision)
	parent.add_child(body)
	# A real landing tread overlaps both the rising ramp and loft edge. Butt-joining
	# two independent triangle boundaries left no support at the transformed seam.
	var landing := PackedVector2Array()
	for point: Vector3 in [polar(stair_inner, end + 0.025, 0), polar(stair_outer, end + 0.025, 0), polar(stair_outer, end - 0.035, 0), polar(stair_inner, end - 0.035, 0)]:
		landing.append(Vector2(point.x, point.z))
	if Geometry2D.is_polygon_clockwise(landing):
		landing.reverse()
	prism(parent, "StairLandingTread", landing, loft_y, 0.24, tread_wood)
	rail(parent, inner_rail, light_wood, "StairInner")
	rail(parent, outer_rail, light_wood, "StairOuter")
	_carved_stringer(parent, outer_rail, wood)
	KIT.marker(parent, "StairFoot", path[0])
	KIT.marker(parent, "StairLanding", path[-1])
	# Branch-like supports articulate the loft underside without blocking its centre.
	for x: float in [-1.9, 3.9]:
		KIT.tube(parent, "LoftRootBrace", PackedVector3Array([Vector3(x, 0, -2.0), Vector3(x * 0.94, 1.4, -1.65), Vector3(x * 0.92, loft_y - 0.18, -0.9)]), 0.14, light_wood)
		REFERENCE.lathe(parent, "FlaredLivingRoot", PackedVector2Array([Vector2(0, 0), Vector2(0.23, 0.015), Vector2(0.18, 0.17), Vector2(0.14, 0.5), Vector2(0.11, 0.9), Vector2(0, 0.92)]), light_wood, Vector3(x, 0, -2.0))
		for direction: float in [-1.0, 1.0]:
			KIT.tube(parent, "LoftBranchFork", PackedVector3Array([Vector3(x * 0.94, 1.85, -1.4), Vector3(x * 0.92 + direction * 0.16, 2.55, -1.15), Vector3(x * 0.92 + direction * 0.52, loft_y - 0.15, -0.9)]), 0.10, light_wood)
	_loft_carving(parent, front, loft_y)
	return path

static func _carved_stringer(parent: Node3D, points: PackedVector3Array, finish: Material) -> void:
	# Continuous solid-looking outer stair cheek, grown with the wall rather than
	# separate handrail pickets. Existing guard boxes and route are untouched.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(finish)
	for index: int in points.size() - 1:
		var a := points[index]
		var b := points[index + 1]
		var vertices: Array[Vector3] = []
		for point: Vector3 in [a, b]:
			var outward := Vector3(point.x, 0, point.z).normalized()
			for offset: float in [-0.032, 0.10]:
				vertices.append(point + outward * offset + Vector3.UP * 0.88)
				vertices.append(point + outward * offset - Vector3.UP * minf(0.36, point.y))
		for face: Array in [[0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]:
			for corner: int in [0, 1, 2, 0, 2, 3]:
				st.add_vertex(vertices[face[corner]])
	st.generate_normals()
	var visual := MeshInstance3D.new()
	visual.name = "SolidCurvingStairStringer"
	visual.mesh = st.commit()
	parent.add_child(visual)

static func _loft_carving(parent: Node3D, front: PackedVector3Array, loft_y: float) -> void:
	var pale := KIT.material("f6b795")
	var grain := KIT.material("97454c")
	# Flowing apron bough and a few broad carved spirals, not tiny surface noise.
	var bough := PackedVector3Array()
	for index: int in front.size():
		var point := front[index]
		point.y = loft_y - 0.14 + sin(index * 0.35) * 0.055
		point.z += 0.025
		bough.append(point)
	KIT.tube(parent, "LoftApronBough", bough, 0.12, pale)
	for x: float in [-1.7, -0.3, 1.1, 2.5, 3.9]:
		var scroll := PackedVector3Array()
		for index: int in 33:
			var t: float = index / 32.0
			var angle: float = t * TAU * 1.15
			var r: float = lerpf(0.13, 0.02, t)
			scroll.append(Vector3(x + cos(angle) * r, loft_y - 0.14 + sin(angle) * r * 0.5, -0.55))
		KIT.tube(parent, "CarvedLoftScroll", scroll, 0.012, grain)
