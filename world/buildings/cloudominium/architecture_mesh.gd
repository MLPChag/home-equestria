extends RefCounted
## Batched procedural geometry for the Cloudominium architecture (dev 2026-09-28).
## One surface per material name, so the whole room costs one draw call per material.
## Every triangle is turned toward an outward hint (Godot draws clockwise triangles as front
## faces), normals are flat unless supplied, UVs are planar room metres. `xform` places local
## parts (a column, a lamp) in the room frame; push()/pop() nest it.
const MATERIALS := preload("res://world/buildings/cloudominium/materials.gd")

var xform := Transform3D.IDENTITY
## Vertex colour for the following faces; only vertex-painted materials show it.
var paint := Color.WHITE
## Material names of the last bake(), in surface order.
var baked_keys: Array[String] = []
var _tools: Dictionary = {}
var _local: Dictionary = {}
var _stack: Array[Transform3D] = []

## Registers a material that is not one of the shared names (rainbow paint, lamp glow).
func use_material(key: String, material: Material) -> void:
	_local[key] = material

func push(local: Transform3D) -> void:
	_stack.append(xform)
	xform = xform * local

func pop() -> void:
	xform = _stack.pop_back()

func _tool(key: String) -> SurfaceTool:
	var st: SurfaceTool = _tools.get(key)
	if st == null:
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_tools[key] = st
	return st

func _vertex(st: SurfaceTool, point: Vector3, normal: Vector3) -> void:
	var at := xform * point
	var facing := (xform.basis * normal).normalized()
	st.set_color(paint)
	st.set_normal(facing)
	st.set_uv(_planar(at, facing))
	st.add_vertex(at)

static func _planar(point: Vector3, normal: Vector3) -> Vector2:
	var n := normal.abs()
	if n.y >= n.x and n.y >= n.z:
		return Vector2(point.x, point.z)
	if n.x >= n.z:
		return Vector2(point.z, -point.y)
	return Vector2(point.x, -point.y)

## One triangle facing `outward`. Zero normals mean flat shading.
func tri(key: String, a: Vector3, b: Vector3, c: Vector3, outward: Vector3, na: Vector3 = Vector3.ZERO, nb: Vector3 = Vector3.ZERO, nc: Vector3 = Vector3.ZERO) -> void:
	var face := (c - a).cross(b - a)
	if face.length_squared() < 1e-14:
		return
	if face.dot(outward) < 0.0:
		var point := b
		b = c
		c = point
		var normal := nb
		nb = nc
		nc = normal
		face = -face
	face = face.normalized()
	var st := _tool(key)
	_vertex(st, a, face if na == Vector3.ZERO else na)
	_vertex(st, b, face if nb == Vector3.ZERO else nb)
	_vertex(st, c, face if nc == Vector3.ZERO else nc)

## Four corners in order around the quad (either winding).
func quad(key: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3) -> void:
	tri(key, a, b, c, outward)
	tri(key, a, c, d, outward)

func box(key: String, centre: Vector3, size: Vector3, basis: Basis = Basis.IDENTITY) -> void:
	var half := size * 0.5
	for axis: int in 3:
		for side: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = side
			var u := Vector3.ZERO
			u[(axis + 1) % 3] = half[(axis + 1) % 3]
			var v := Vector3.ZERO
			v[(axis + 2) % 3] = half[(axis + 2) % 3]
			var face := n * half[axis]
			quad(key, centre + basis * (face - u - v), centre + basis * (face + u - v), centre + basis * (face + u + v), centre + basis * (face - u + v), basis * n)

## Round tube through `points`; shared tangent frames keep joints closed. Optional taper.
func tube(key: String, points: PackedVector3Array, radius: float, sides: int = 8, end_radius: float = -1.0) -> void:
	var count := points.size()
	if count < 2:
		return
	var rings: Array[PackedVector3Array] = []
	var normals: Array[PackedVector3Array] = []
	var previous := Vector3.ZERO
	for index: int in count:
		var along := (points[mini(index + 1, count - 1)] - points[maxi(index - 1, 0)]).normalized()
		var side := previous - along * previous.dot(along)
		if side.length_squared() < 0.01:
			side = along.cross(Vector3.UP if absf(along.y) < 0.95 else Vector3.RIGHT)
		side = side.normalized()
		previous = side
		var other := along.cross(side).normalized()
		var r := radius if end_radius < 0.0 else lerpf(radius, end_radius, float(index) / (count - 1))
		var ring := PackedVector3Array()
		var ring_normals := PackedVector3Array()
		for k: int in sides:
			var angle := TAU * k / sides
			var normal := side * cos(angle) + other * sin(angle)
			ring.append(points[index] + normal * r)
			ring_normals.append(normal)
		rings.append(ring)
		normals.append(ring_normals)
	for index: int in count - 1:
		for k: int in sides:
			var next := (k + 1) % sides
			var n0 := normals[index][k]
			var n1 := normals[index][next]
			var n2 := normals[index + 1][next]
			var n3 := normals[index + 1][k]
			var outward := n0 + n1 + n2 + n3
			tri(key, rings[index][k], rings[index][next], rings[index + 1][next], outward, n0, n1, n2)
			tri(key, rings[index][k], rings[index + 1][next], rings[index + 1][k], outward, n0, n2, n3)
	for end: int in [0, count - 1]:
		var cap := (points[0] - points[1]).normalized() if end == 0 else (points[count - 1] - points[count - 2]).normalized()
		for k: int in sides:
			tri(key, points[end], rings[end][k], rings[end][(k + 1) % sides], cap)

## Surface of revolution about local +Y. Profile (radius, height) runs from the bottom up.
func lathe(key: String, profile: PackedVector2Array, sides: int = 28) -> void:
	for row: int in profile.size() - 1:
		var lower := profile[row]
		var upper := profile[row + 1]
		var slope := upper - lower
		var flat := Vector2(slope.y, -slope.x).normalized()
		for side: int in sides:
			var a0 := TAU * side / sides
			var a1 := TAU * (side + 1) / sides
			var p0 := Vector3(sin(a0) * lower.x, lower.y, cos(a0) * lower.x)
			var p1 := Vector3(sin(a1) * lower.x, lower.y, cos(a1) * lower.x)
			var p2 := Vector3(sin(a1) * upper.x, upper.y, cos(a1) * upper.x)
			var p3 := Vector3(sin(a0) * upper.x, upper.y, cos(a0) * upper.x)
			var n0 := Vector3(sin(a0) * flat.x, flat.y, cos(a0) * flat.x)
			var n1 := Vector3(sin(a1) * flat.x, flat.y, cos(a1) * flat.x)
			tri(key, p0, p1, p2, n0 + n1, n0, n1, n1)
			tri(key, p0, p2, p3, n0 + n1, n0, n1, n0)

## Ellipsoid whose basis columns are its three semi-axes.
func ellipsoid(key: String, centre: Vector3, axes: Basis, rings: int = 7, segments: int = 14) -> void:
	var normal_basis := axes.inverse().transposed()
	for ring: int in rings:
		for segment: int in segments:
			var corners: Array[Vector3] = []
			var normals: Array[Vector3] = []
			for uv: Vector2i in [Vector2i(ring, segment), Vector2i(ring, segment + 1), Vector2i(ring + 1, segment + 1), Vector2i(ring + 1, segment)]:
				var t := PI * uv.x / rings
				var p := TAU * uv.y / segments
				var unit := Vector3(sin(t) * cos(p), cos(t), sin(t) * sin(p))
				corners.append(centre + axes * unit)
				normals.append((normal_basis * unit).normalized())
			var outward := normals[0] + normals[1] + normals[2] + normals[3]
			tri(key, corners[0], corners[1], corners[2], outward, normals[0], normals[1], normals[2])
			tri(key, corners[0], corners[2], corners[3], outward, normals[0], normals[2], normals[3])

## Flat 2D shape (local XY) extruded `depth` along local +Z, placed by `place`.
func extrude(key: String, polygon: PackedVector2Array, place: Transform3D, depth: float) -> void:
	var shape := polygon.duplicate()
	if Geometry2D.is_polygon_clockwise(shape):
		shape.reverse()
	var ids := Geometry2D.triangulate_polygon(shape)
	for offset: int in range(0, ids.size(), 3):
		var corners: Array[Vector2] = [shape[ids[offset]], shape[ids[offset + 1]], shape[ids[offset + 2]]]
		for z: float in [0.0, depth]:
			tri(key, place * Vector3(corners[0].x, corners[0].y, z), place * Vector3(corners[1].x, corners[1].y, z), place * Vector3(corners[2].x, corners[2].y, z), place.basis * Vector3(0, 0, 1.0 if z > 0.0 else -1.0))
	for index: int in shape.size():
		var a := shape[index]
		var b := shape[(index + 1) % shape.size()]
		var edge := b - a
		quad(key, place * Vector3(a.x, a.y, 0), place * Vector3(b.x, b.y, 0), place * Vector3(b.x, b.y, depth), place * Vector3(a.x, a.y, depth), place.basis * Vector3(edge.y, -edge.x, 0))

## Commits every material surface into one mesh (keys recorded in baked_keys) and clears.
## Parts meant for append() stay unindexed: append_from() would otherwise index only them.
func bake(indexed: bool = true) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	baked_keys.clear()
	for key: String in _tools:
		var st: SurfaceTool = _tools[key]
		if indexed:
			st.index()
		st.set_material(_local[key] if _local.has(key) else MATERIALS.get_material(key))
		st.commit(mesh)
		baked_keys.append(key)
	_tools.clear()
	return mesh

## Copies a part baked with bake(false) (keys from its builder) into this builder at `place`,
## natively. Local materials the part uses must be registered here too.
func append(part: ArrayMesh, keys: Array[String], place: Transform3D) -> void:
	for surface: int in part.get_surface_count():
		_tool(keys[surface]).append_from(part, surface, xform * place)

## Bakes into one MeshInstance3D under `parent`. Interior only: no outdoor shadow pass and a
## bounded draw distance, as in Golden Oak.
func commit(parent: Node3D, label: String) -> MeshInstance3D:
	var view := MeshInstance3D.new()
	view.name = label
	view.mesh = bake()
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	view.visibility_range_end = 45.0
	parent.add_child(view)
	return view
