extends RefCounted
## Geometry for Rainbow Dash's Cloudominium furnishings (dev 2026-09-28), in real metres.
## One mesh per piece, one surface per material, true normals for the game's ink outline:
## cloud lobes and cushions (superellipsoids), turned parts (lathe), tubes, flat cut-outs
## (prisms), cloth sheets and rugs. materials.gd paints most surfaces in the mesh's own space
## (cloud swirls, fabric bolts, the quilt's rainbow bolt, the guitar's bands), so each piece is
## built in its own frame. Collision stays simple: boxes and cylinders on the world layer.
## Build a piece off-tree, set its transform, then add it: Jolt keeps the scale a body enters with.
const MATERIALS := preload("res://world/buildings/cloudominium/materials.gd")
const SEAT := preload("res://world/life/seat.gd")
const COUCH := preload("res://world/life/couch.gd")
const WORLD_LAYER := 1
## Interior draw distance; no furniture in the shadow pass (as the Golden Oak library).
const DRAW_DISTANCE := 45.0

static var _paints: Dictionary = {}
## Vertex colour for the next shapes ("book" tints its covers with it).
var tint := Color.WHITE
var _parts: Dictionary = {}

class Part:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	func vertex(at: Vector3, normal: Vector3, uv: Vector2, colour: Color) -> int:
		vertices.append(at)
		normals.append(normal)
		uvs.append(uv)
		colors.append(colour)
		return vertices.size() - 1

	## Godot's front faces wind clockwise: orient each triangle to its vertex normals.
	func triangle(a: int, b: int, c: int) -> void:
		var facing := normals[a] + normals[b] + normals[c]
		var cross := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
		if cross.dot(facing) > 0.0:
			indices.append(a); indices.append(c); indices.append(b)
		else:
			indices.append(a); indices.append(b); indices.append(c)

	func quad(a: int, b: int, c: int, d: int) -> void:
		triangle(a, b, c)
		triangle(a, c, d)

## A contract material from materials.gd, or "#rrggbb" plain paint for small accents
## ("#rrggbb!" glows a little, for a lit lamp shade).
static func material(key: String) -> Material:
	if key.begins_with("#"):
		return paint(key.substr(1))
	return MATERIALS.get_material(key)

static func paint(hex: String) -> StandardMaterial3D:
	if _paints.has(hex):
		return _paints[hex] as StandardMaterial3D
	var glow := hex.ends_with("!")
	var colour := Color(hex.trim_suffix("!"))
	var result := StandardMaterial3D.new()
	result.albedo_color = colour
	result.roughness = 0.8
	result.metallic_specular = 0.3
	if glow:
		result.emission_enabled = true
		result.emission = colour
		result.emission_energy_multiplier = 0.35
	_paints[hex] = result
	return result

static func place(at: Vector3, yaw: float = 0.0, pitch: float = 0.0, roll: float = 0.0) -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(pitch, yaw, roll)), at)

## Room frame: angles in degrees about +Y, 0 = +Z (the door), 90 = +X.
static func polar(distance: float, degrees: float, y: float) -> Vector3:
	var angle := deg_to_rad(degrees)
	return Vector3(sin(angle) * distance, y, cos(angle) * distance)

## A frame on the room circle whose local +Z faces the room centre (its back to the wall).
static func facing_centre(distance: float, degrees: float, y: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(degrees) + PI), polar(distance, degrees, y))

## Distance from the centre for a piece whose back corners (`back` behind its origin,
## `half_width` to each side) stay `gap` inside a round wall.
static func against_wall(wall_radius: float, half_width: float, back: float, gap: float = 0.06) -> float:
	var reach := wall_radius - gap
	return sqrt(maxf(reach * reach - half_width * half_width, 0.0)) - back

func _part(key: String) -> Part:
	if not _parts.has(key):
		_parts[key] = Part.new()
	return _parts[key] as Part

## Cloud lobe or cushion: a superellipsoid (power 2 = ellipsoid, 3 to 5 = ever softer box).
func blob(xf: Transform3D, radii: Vector3, key: String, power: float = 2.0, rings: int = 10, sides: int = 16) -> void:
	var part := _part(key)
	var start := part.vertices.size()
	for ring in rings + 1:
		var theta := PI * float(ring) / float(rings)
		for side in sides + 1:
			var phi := TAU * float(side) / float(sides)
			var d := Vector3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
			var sum := pow(absf(d.x) / radii.x, power) + pow(absf(d.y) / radii.y, power) + pow(absf(d.z) / radii.z, power)
			var p := d * pow(sum, -1.0 / power)
			var g := Vector3(_slope(p.x, radii.x, power), _slope(p.y, radii.y, power), _slope(p.z, radii.z, power))
			if g.length_squared() < 1e-12:
				g = d
			part.vertex(xf * p, (xf.basis * g).normalized(), Vector2(float(side) / float(sides), float(ring) / float(rings)), tint)
	for ring in rings:
		for side in sides:
			var a := start + ring * (sides + 1) + side
			part.quad(a, a + sides + 1, a + sides + 2, a + 1)

static func _slope(value: float, radius: float, power: float) -> float:
	return signf(value) * pow(absf(value) / radius, power - 1.0) / radius

## A turned part about local +Y from (radius, height) points, bottom to top.
## Crisp by default (each profile segment flat); smooth for curved profiles such as vases.
func lathe(xf: Transform3D, profile: PackedVector2Array, key: String, sides: int = 24, smooth: bool = false) -> void:
	var count := profile.size()
	if count < 2:
		return
	var part := _part(key)
	var lengths := PackedFloat32Array([0.0])
	for i in count - 1:
		lengths.append(lengths[i] + profile[i].distance_to(profile[i + 1]))
	var total := maxf(lengths[count - 1], 1e-4)
	# One entry per ring: profile index and the outward profile normal (x = radial, y = up).
	var rings: Array[Vector3] = []
	if smooth:
		for i in count:
			var along := profile[mini(i + 1, count - 1)] - profile[maxi(i - 1, 0)]
			rings.append(Vector3(i, along.y, -along.x))
	else:
		for i in count - 1:
			var along := profile[i + 1] - profile[i]
			rings.append(Vector3(i, along.y, -along.x))
			rings.append(Vector3(i + 1, along.y, -along.x))
	var first := part.vertices.size()
	for ring: Vector3 in rings:
		var index := int(ring.x)
		var point := profile[index]
		var n2 := Vector2(ring.y, ring.z).normalized()
		for side in sides + 1:
			var phi := TAU * float(side) / float(sides)
			var out := Vector3(sin(phi), 0.0, cos(phi))
			var normal := (xf.basis * (out * n2.x + Vector3.UP * n2.y)).normalized()
			part.vertex(xf * (out * point.x + Vector3.UP * point.y), normal, Vector2(float(side) / float(sides), lengths[index] / total), tint)
	var step := 1 if smooth else 2
	for r in range(0, rings.size() - 1, step):
		for side in sides:
			var a := first + r * (sides + 1) + side
			part.quad(a, a + sides + 1, a + sides + 2, a + 1)

## A round tube through points (piece space); `radii`, one per point, tapers it.
func tube(points: PackedVector3Array, radius: float, key: String, sides: int = 10, radii: PackedFloat32Array = PackedFloat32Array(), round_ends: bool = true) -> void:
	var count := points.size()
	if count < 2:
		return
	var part := _part(key)
	var first := part.vertices.size()
	var previous_side := Vector3.ZERO
	var length := 0.0
	for i in count:
		if i > 0:
			length += points[i].distance_to(points[i - 1])
		var tangent := (points[mini(i + 1, count - 1)] - points[maxi(i - 1, 0)]).normalized()
		var side := previous_side - tangent * previous_side.dot(tangent)
		if side.length_squared() < 0.01:
			side = tangent.cross(Vector3.UP if absf(tangent.y) < 0.95 else Vector3.RIGHT)
		side = side.normalized()
		previous_side = side
		var other := tangent.cross(side).normalized()
		var r: float = radii[i] if i < radii.size() else radius
		for k in sides + 1:
			var angle := TAU * float(k) / float(sides)
			var normal := side * cos(angle) + other * sin(angle)
			part.vertex(points[i] + normal * r, normal, Vector2(float(k) / float(sides), length), tint)
	for i in count - 1:
		for k in sides:
			var a := first + i * (sides + 1) + k
			part.quad(a, a + sides + 1, a + sides + 2, a + 1)
	if round_ends:
		for i: int in [0, count - 1]:
			var r: float = radii[i] if i < radii.size() else radius
			blob(Transform3D(Basis.IDENTITY, points[i]), Vector3.ONE * r, key, 2.0, 6, sides)

func box(xf: Transform3D, size: Vector3, key: String) -> void:
	var part := _part(key)
	var half := size * 0.5
	for axis in 3:
		for direction: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = direction
			var u := Vector3.ZERO
			u[(axis + 1) % 3] = 1.0
			var v := Vector3.ZERO
			v[(axis + 2) % 3] = 1.0
			var hn: float = half[axis]
			var hu: float = half[(axis + 1) % 3]
			var hv: float = half[(axis + 2) % 3]
			var normal := (xf.basis * n).normalized()
			var corners: Array[int] = []
			for c: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				var p := n * hn + u * (c.x * hu) + v * (c.y * hv)
				corners.append(part.vertex(xf * p, normal, c * 0.5 + Vector2(0.5, 0.5), tint))
			part.quad(corners[0], corners[1], corners[2], corners[3])

## A flat cut-out: polygon in local XY (y up) extruded `depth` along local Z, front face +Z.
## Front and back map UV 0..1 over the outline's bounds (its top is v = 0), as pictures expect.
## `edge` paints the rim when given.
func prism(xf: Transform3D, polygon: PackedVector2Array, depth: float, key: String, edge: String = "") -> void:
	var outline := polygon.duplicate()
	if Geometry2D.is_polygon_clockwise(outline):
		outline.reverse()
	var triangles := Geometry2D.triangulate_polygon(outline)
	if triangles.is_empty():
		push_warning("Cloudominium furniture: a cut-out outline could not be triangulated.")
		return
	var bounds := Rect2(outline[0], Vector2.ZERO)
	for p: Vector2 in outline:
		bounds = bounds.expand(p)
	var size := Vector2(maxf(bounds.size.x, 1e-4), maxf(bounds.size.y, 1e-4))
	var part := _part(key)
	var half := depth * 0.5
	for face: float in [1.0, -1.0]:
		var normal := (xf.basis * Vector3(0, 0, face)).normalized()
		var first := part.vertices.size()
		for p: Vector2 in outline:
			var uv := Vector2((p.x - bounds.position.x) / size.x, 1.0 - (p.y - bounds.position.y) / size.y)
			part.vertex(xf * Vector3(p.x, p.y, half * face), normal, uv, tint)
		for t in range(0, triangles.size(), 3):
			part.triangle(first + triangles[t], first + triangles[t + 1], first + triangles[t + 2])
	var rim := _part(edge if not edge.is_empty() else key)
	for i in outline.size():
		var a := outline[i]
		var b := outline[(i + 1) % outline.size()]
		var along := b - a
		if along.length_squared() < 1e-10:
			continue
		var out := Vector2(along.y, -along.x).normalized()
		var normal := (xf.basis * Vector3(out.x, out.y, 0.0)).normalized()
		var corners: Array[int] = []
		for c: Vector3 in [Vector3(a.x, a.y, half), Vector3(b.x, b.y, half), Vector3(b.x, b.y, -half), Vector3(a.x, a.y, -half)]:
			corners.append(rim.vertex(xf * c, normal, Vector2(c.x + c.y, c.z), tint))
		rim.quad(corners[0], corners[1], corners[2], corners[3])

## Cloth through a grid of points (rows of equal length). UVs in metres, or 0..1 with `fit`.
## The contract cloth materials are double-sided; `back` adds a second face a hair behind.
func sheet(rows: Array[PackedVector3Array], key: String, fit: bool = false, back: bool = false) -> void:
	var height := rows.size()
	if height < 2:
		return
	var width := rows[0].size()
	var part := _part(key)
	var span_u := 0.0
	for c in width - 1:
		span_u += rows[0][c].distance_to(rows[0][c + 1])
	var span_v := 0.0
	for r in height - 1:
		span_v += rows[r][0].distance_to(rows[r + 1][0])
	for face in (2 if back else 1):
		var flip := -1.0 if face == 1 else 1.0
		var first := part.vertices.size()
		for r in height:
			for c in width:
				var du := rows[r][mini(c + 1, width - 1)] - rows[r][maxi(c - 1, 0)]
				var dv := rows[mini(r + 1, height - 1)][c] - rows[maxi(r - 1, 0)][c]
				var normal := du.cross(dv).normalized() * flip
				var uv := Vector2(float(c) / float(width - 1), float(r) / float(height - 1))
				if not fit:
					uv *= Vector2(span_u, span_v)
				part.vertex(rows[r][c] + normal * (0.003 if face == 1 else 0.0), normal, uv, tint)
		for r in height - 1:
			for c in width - 1:
				var a := first + r * width + c
				part.quad(a, a + width, a + width + 1, a + 1)

## A ring about local Y, in the local XZ plane.
func torus(xf: Transform3D, major: float, minor: float, key: String, rings: int = 24, sides: int = 8) -> void:
	var part := _part(key)
	var first := part.vertices.size()
	for i in rings + 1:
		var u := TAU * float(i) / float(rings)
		var out := Vector3(cos(u), 0.0, sin(u))
		for k in sides + 1:
			var v := TAU * float(k) / float(sides)
			var normal := out * cos(v) + Vector3.UP * sin(v)
			part.vertex(xf * (out * major + normal * minor), (xf.basis * normal).normalized(), Vector2(float(i) / float(rings), float(k) / float(sides)), tint)
	for i in rings:
		for k in sides:
			var a := first + i * (sides + 1) + k
			part.quad(a, a + sides + 1, a + sides + 2, a + 1)

## A flat oval lying on local y = 0, `height` thick, UV 0..1 across its top.
func rug(xf: Transform3D, radii: Vector2, height: float, key: String, sides: int = 48) -> void:
	var part := _part(key)
	var up := (xf.basis * Vector3.UP).normalized()
	var centre := part.vertex(xf * Vector3(0, height, 0), up, Vector2(0.5, 0.5), tint)
	var first := part.vertices.size()
	for k in sides + 1:
		var angle := TAU * float(k) / float(sides)
		var p := Vector3(cos(angle) * radii.x, height, sin(angle) * radii.y)
		part.vertex(xf * p, up, Vector2(0.5 + p.x / (2.0 * radii.x), 0.5 + p.z / (2.0 * radii.y)), tint)
	for k in sides:
		part.triangle(centre, first + k, first + k + 1)
	var band := part.vertices.size()
	for k in sides + 1:
		var angle := TAU * float(k) / float(sides)
		var p := Vector3(cos(angle) * radii.x, 0.0, sin(angle) * radii.y)
		var normal := (xf.basis * Vector3(cos(angle) / radii.x, 0.0, sin(angle) / radii.y)).normalized()
		part.vertex(xf * (p + Vector3.UP * height), normal, Vector2(float(k) / float(sides), 0.0), tint)
		part.vertex(xf * p, normal, Vector2(float(k) / float(sides), 1.0), tint)
	for k in sides:
		var a := band + k * 2
		part.quad(a, a + 1, a + 3, a + 2)

## A swirl line wrapped onto a sphere's cap (the scroll ends of arms and rolls).
func swirl(centre: Vector3, sphere_radius: float, facing: Basis, key: String, turns: float = 1.6, reach: float = 0.75, line: float = 0.01) -> void:
	var points := PackedVector3Array()
	var count := 28
	for i in count:
		var t := float(i) / float(count - 1)
		var angle := TAU * turns * t
		var r := lerpf(0.12, reach, t) * sphere_radius
		var u := cos(angle) * r
		var v := sin(angle) * r
		var direction := (facing.x * u + facing.y * v + facing.z * sqrt(maxf(sphere_radius * sphere_radius - u * u - v * v, 0.0))).normalized()
		points.append(centre + direction * (sphere_radius + line * 0.4))
	tube(points, line, key, 6)

## A closed book lying flat, origin under its centre: covers and spine in `cover`
## ("book" takes the current tint), cream page block.
func book(at: Transform3D, size: Vector3, cover: String) -> void:
	var board := 0.006
	box(at * place(Vector3(0, board * 0.5, 0)), Vector3(size.x, board, size.z), cover)
	box(at * place(Vector3(0, size.y - board * 0.5, 0)), Vector3(size.x, board, size.z), cover)
	box(at * place(Vector3(-size.x * 0.5 + board * 0.5, size.y * 0.5, 0)), Vector3(board, size.y, size.z), cover)
	var pages := tint
	tint = Color.WHITE
	box(at * place(Vector3(0.004, size.y * 0.5, 0)), Vector3(size.x - 0.016, size.y - board * 2.0, size.z - 0.012), "#f2e2a4")
	tint = pages

## Every shape so far as one MeshInstance3D under `parent`, at `at` (shapes are in its space).
func commit(parent: Node3D, label_text: String, at: Transform3D = Transform3D.IDENTITY) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	for key: String in _parts:
		var part: Part = _parts[key]
		if part.indices.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = part.vertices
		arrays[Mesh.ARRAY_NORMAL] = part.normals
		arrays[Mesh.ARRAY_TEX_UV] = part.uvs
		arrays[Mesh.ARRAY_COLOR] = part.colors
		arrays[Mesh.ARRAY_INDEX] = part.indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material(key))
	_parts.clear()
	var visual := MeshInstance3D.new()
	visual.name = label_text
	visual.mesh = mesh
	visual.transform = at
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visual.visibility_range_end = DRAW_DISTANCE
	parent.add_child(visual)
	return visual

## A plain BoxMesh (amp_face.gdshader reads BoxMesh's 3 x 2 UV atlas).
static func box_mesh(parent: Node3D, label_text: String, size: Vector3, at: Transform3D, key: String) -> MeshInstance3D:
	var visual := MeshInstance3D.new()
	visual.name = label_text
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material(key)
	visual.mesh = mesh
	visual.transform = at
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visual.visibility_range_end = DRAW_DISTANCE
	parent.add_child(visual)
	return visual

static func body(parent: Node3D, label_text: String) -> StaticBody3D:
	var result := StaticBody3D.new()
	result.name = label_text
	result.collision_layer = WORLD_LAYER
	result.collision_mask = 0
	parent.add_child(result)
	return result

static func box_shape(solid: StaticBody3D, size: Vector3, at: Transform3D) -> void:
	var holder := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	holder.shape = shape
	holder.transform = at
	solid.add_child(holder)

static func cylinder_shape(solid: StaticBody3D, radius: float, height: float, at: Vector3) -> void:
	var holder := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	holder.shape = shape
	holder.position = at
	solid.add_child(holder)

static func span(centre: Vector3, size: Vector3) -> AABB:
	return AABB(centre - size * 0.5, size)

## The seats Seating and couch.gd already use (interior_furnisher._add_seating): SeatSolid
## under the cushions, SeatUpper for back and arms (a sitting pony may overlap it), seats
## facing the piece's front (+Z). couch = true (two seats) adds the reclining Couch.
## Every body sits under the Seating node so an aimed seat ray may hit any part of it.
static func seating(piece: Node3D, seats: Array[Vector3], solid: Array[AABB], upper: Array[AABB], couch: bool, depth: float = 0.5) -> Node3D:
	var frame := Node3D.new()
	frame.name = "Seating"
	piece.add_child(frame)
	for label_text: String in ["SeatSolid", "SeatUpper"]:
		var boxes: Array[AABB] = solid if label_text == "SeatSolid" else upper
		if boxes.is_empty():
			continue
		var holder := body(frame, label_text)
		for box_span: AABB in boxes:
			box_shape(holder, box_span.size, Transform3D(Basis.IDENTITY, box_span.get_center()))
	for index in seats.size():
		var seat := SEAT.new() as Node3D
		seat.name = "Seat%d" % index
		seat.set("depth", depth)
		seat.transform = Transform3D(Basis(Vector3.UP, PI), seats[index])
		frame.add_child(seat)
	if couch:
		COUCH.install(frame)
	return frame

## Outline helpers (local XY, y up).
static func star(points: int, outer: float, inner: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	for i in points * 2:
		var angle := PI * float(i) / float(points) + PI * 0.5
		var r: float = outer if i % 2 == 0 else inner
		result.append(Vector2(cos(angle), sin(angle)) * r)
	return result

## One lightning bolt, tip down, `height` tall and centred on the origin.
static func bolt(height: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	for p: Vector2 in [Vector2(-0.05, 0.5), Vector2(0.25, 0.5), Vector2(0.08, 0.08), Vector2(0.24, 0.08), Vector2(-0.2, -0.5), Vector2(-0.02, -0.04), Vector2(-0.18, -0.04)]:
		result.append(p * height)
	return result
