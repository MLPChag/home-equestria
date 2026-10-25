extends RefCounted
## Instance-only opening of the measured RNL Golden Oak shell.
## The placement override owns the 2x scale; furnishings use the returned metre frame.
const PAINT := preload("res://world/buildings/golden_oak/reference_materials.gd")
const SHELVES := preload("res://world/buildings/golden_oak/furniture_shelves.gd")
const WINDOWS := preload("res://world/buildings/golden_oak/windows.gd")
const DOOR := preload("res://world/buildings/hinged_door.gd")
const STATE := &"golden_oak_shell"
const ROOM_ORIGIN := Vector3(.8, .39, 2.5)
const LEAF := AABB(Vector3(-.02, .38, 6.87), Vector3(1.80, 3.40, .30))
const BACK_CAP_Z := 5.26995
const EXTERIOR_WIDTH := .74
const ENVELOPE_RADIUS := 5.65 # shelves reach 5.4 m; keep bark outside them
const ENVELOPE_TOP := 7.6 # ceiling top is 7.36 m
## The authored root rim floats 0.10–0.52 m above the placed terrain. Extend only
## retained bark down 0.60 world metres, fading out above the base; the leaf/frame stay put.
const ROOT_EXTENSION := .30 # source metres, at the existing 2x placement

static func prepare(tree: Node3D) -> Dictionary:
	if tree.has_meta(STATE):
		return tree.get_meta(STATE)
	var view: MeshInstance3D = tree.get_node("Mesh1")
	var source: ArrayMesh = view.mesh
	var shell := ArrayMesh.new()
	var leaf := ArrayMesh.new()
	var surfaces: Array = []
	WINDOWS.begin_shell()
	var report := {"source_triangles": 0, "door_triangles": 0, "cap_triangles": 0, "kept_triangles": 0}
	for s: int in source.get_surface_count():
		var arrays: Array = source.surface_get_arrays(s)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var kept := PackedInt32Array()
		var moving := PackedInt32Array()
		for i: int in range(0, indices.size(), 3):
			var a: Vector3 = vertices[indices[i]]
			var b: Vector3 = vertices[indices[i + 1]]
			var c: Vector3 = vertices[indices[i + 2]]
			var face := PackedInt32Array([indices[i], indices[i + 1], indices[i + 2]])
			report.source_triangles += 1
			if s == 0 and LEAF.has_point(a) and LEAF.has_point(b) and LEAF.has_point(c):
				moving.append_array(face)
				report.door_triangles += 1
			elif s == 0 and _back_cap(a) and _back_cap(b) and _back_cap(c):
				report.cap_triangles += 1
			else:
				kept.append_array(face)
				report.kept_triangles += 1
		if not kept.is_empty():
			var retained: Array = arrays.duplicate()
			retained[Mesh.ARRAY_INDEX] = kept
			retained[Mesh.ARRAY_VERTEX] = _compact_vertices(vertices)
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL].duplicate()
			for i in vertices.size():
				var p := vertices[i]
				var at := _shell_vertex(p)
				var jacobian := Basis((_shell_vertex(p + Vector3.RIGHT * .001) - at) / .001,
					(_shell_vertex(p + Vector3.UP * .001) - at) / .001,
					(_shell_vertex(p + Vector3.BACK * .001) - at) / .001)
				if absf(jacobian.determinant()) > .00001:
					normals[i] = (jacobian.inverse().transposed() * normals[i]).normalized()
			retained[Mesh.ARRAY_NORMAL] = normals
			retained = WINDOWS.cut_surface(retained, ROOM_ORIGIN)
			var importer := ImporterMesh.new()
			importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, retained, [], {}, source.surface_get_material(s))
			importer.generate_lods(60.0, 25.0, [])
			var optimized: ArrayMesh = importer.get_mesh()
			var generated: Array = optimized.get("_surfaces")
			surfaces.append(generated[0])
		if not moving.is_empty():
			# Compact the selected faces, keeping original normals and texture UVs.
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			var surface := SurfaceTool.new()
			surface.begin(Mesh.PRIMITIVE_TRIANGLES)
			surface.set_material(source.surface_get_material(s))
			for index: int in moving:
				surface.set_normal(normals[index])
				surface.set_uv(uvs[index])
				surface.add_vertex(_compact_vertex(vertices[index]))
			surface.index()
			surface.commit(leaf)
	assert(report.door_triangles == 68, "Golden Oak source leaf changed; remeasure before cutting")
	assert(report.cap_triangles == 12, "Golden Oak tunnel cap changed; remeasure before cutting")
	shell.set("_surfaces", surfaces)
	view.mesh = shell
	# The original 16 boxes intentionally approximate a solid tree. They cannot
	# coexist with an enterable interior. Keep only the actual remaining surfaces.
	var solid: StaticBody3D = tree.get_node("Solid")
	for child: Node in solid.get_children():
		solid.remove_child(child)
		child.free()
	var collision := CollisionShape3D.new()
	collision.name = "MeasuredHollowShell"
	var shape: ConcavePolygonShape3D = shell.create_trimesh_shape()
	shape.backface_collision = true
	collision.shape = shape
	solid.add_child(collision)
	# Counter-scale BEFORE parenting: Jolt must receive metre-sized bodies.
	var frame := Node3D.new()
	frame.name = "GoldenOakRoomFrame"
	var world_frame := Transform3D(tree.global_basis.orthonormalized(), tree.to_global(ROOM_ORIGIN))
	frame.transform = tree.global_transform.affine_inverse() * world_frame
	tree.add_child(frame)
	_build_room(frame)
	WINDOWS.build(frame)
	var door: Node3D = _build_door(frame, tree, leaf)
	var layout := {"radius": 5.0, "floor_y": 0.0, "loft_y": 3.4, "ceiling_y": 7.2,
		"door_position": Vector3(.16 * EXTERIOR_WIDTH, 0, 9.04 * EXTERIOR_WIDTH), "door_width": 3.2 * EXTERIOR_WIDTH,
		"door_approach": Vector3(.16 * EXTERIOR_WIDTH, -.19126, 11.0), "door_inside": Vector3(.16, 0, 4.5),
		"doorway": Vector3(.16 * EXTERIOR_WIDTH, 0, 9.04 * EXTERIOR_WIDTH), "door_height": 6.75, "approach": Vector3(.16 * EXTERIOR_WIDTH, -.19126, 11.0)}
	report["source_bounds"] = source.get_aabb()
	report["compact_bounds"] = shell.get_aabb()
	report["exterior_width_factor"] = EXTERIOR_WIDTH
	report["leaf_bounds"] = leaf.get_aabb()
	report["removed_box_colliders"] = 16
	var result := {"frame": world_frame, "frame_node": frame, "layout": layout, "door": door, "report": report}
	tree.set_meta(STATE, result)
	return result


## Compact around the room, not around the source pivot. Below the ceiling the
## bark stops outside the furniture envelope; branches/canopy above it contract.
## Door triangles use the same mapping, so artwork and physical opening agree.
static func _compact_vertex(vertex: Vector3) -> Vector3:
	var p := (vertex - ROOM_ORIGIN) * 2.0
	var radius := Vector2(p.x, p.z).length()
	var envelope := ENVELOPE_RADIUS * (1.0 - smoothstep(ENVELOPE_TOP, ENVELOPE_TOP + 2.0, p.y))
	if radius > .001:
		var factor := maxf(radius * EXTERIOR_WIDTH, minf(radius, envelope)) / radius
		p.x *= factor
		p.z *= factor
	if p.y > ENVELOPE_TOP: p.y = ENVELOPE_TOP + (p.y - ENVELOPE_TOP) * .80
	return ROOM_ORIGIN + p * .5

static func _compact_vertices(vertices: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	result.resize(vertices.size())
	for i in vertices.size(): result[i] = _shell_vertex(vertices[i])
	return result

static func _shell_vertex(vertex: Vector3) -> Vector3:
	var compact := _compact_vertex(vertex)
	compact.y -= ROOT_EXTENSION * (1.0 - smoothstep(.40, 1.0, vertex.y))
	return compact

static func _back_cap(point: Vector3) -> bool:
	return absf(point.z - BACK_CAP_Z) < .002 and point.x > .03 and point.x < 1.79 and point.y > .38 and point.y < 3.78

static func _build_door(frame: Node3D, tree: Node3D, source: ArrayMesh) -> Node3D:
	var hinge := Node3D.new()
	hinge.name = "OriginalDoorHinge"
	var bounds: AABB = source.get_aabb()
	var source_hinge := Vector3(bounds.position.x, ROOM_ORIGIN.y, bounds.end.z)
	hinge.position = frame.to_local(tree.to_global(source_hinge))
	frame.add_child(hinge)
	var door: AnimatableBody3D = DOOR.new()
	door.name = "GoldenOakDoor"
	# Swing outwards; the preserved tunnel jamb is too narrow for an inward leaf.
	door.swing_direction = -1.0
	var conversion: Transform3D = hinge.global_transform.affine_inverse() * tree.global_transform
	var mesh := ArrayMesh.new()
	for s: int in source.get_surface_count():
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		surface.set_material(source.surface_get_material(s))
		surface.append_from(source, s, conversion)
		surface.commit(mesh)
	var artwork := MeshInstance3D.new()
	artwork.name = "OriginalDoorArtwork"
	artwork.mesh = mesh
	door.add_child(artwork)
	var leaf_bounds: AABB = mesh.get_aabb()
	door.handle = Vector3(leaf_bounds.size.x - .30, 1.08, 0)
	var collision := CollisionShape3D.new()
	collision.name = "LeafCollision"
	# Convex points follow the original pointed arch instead of a full-height box.
	var shape := ConvexPolygonShape3D.new()
	shape.points = mesh.get_faces()
	collision.shape = shape
	door.add_child(collision)
	door.navigation_box = AABB(Vector3(-.15, -.1, -leaf_bounds.size.x), Vector3(leaf_bounds.size.x + .3, leaf_bounds.size.y + .2, leaf_bounds.size.x * 2))
	hinge.add_child(door)
	return door

static func _wood(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = .92
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

static func _build_room(frame: Node3D) -> void:
	var floor_mat: Material = PAINT.floor_material(frame.global_transform)
	var wall_mat: Material = PAINT.wall(frame.global_transform)
	var ceiling_mat: Material = PAINT.ceiling(frame.global_transform)
	var floor := CylinderMesh.new()
	floor.top_radius = 5.13
	floor.bottom_radius = 5.13
	floor.height = .20
	floor.radial_segments = 80
	_solid(frame, "LibraryFloor", floor, Vector3(0, -.10, 0), floor_mat)
	var ceiling := CylinderMesh.new()
	ceiling.top_radius = 5.14
	ceiling.bottom_radius = 5.14
	ceiling.height = .16
	ceiling.radial_segments = 80
	_solid(frame, "LibraryCeiling", ceiling, Vector3(0, 7.28, 0), ceiling_mat)
	_build_carved_lining(frame, wall_mat)
	var bridge := BoxMesh.new()
	bridge.size = Vector3(3.68 * EXTERIOR_WIDTH, .20, 3.0)
	_solid(frame, "EntranceFloor", bridge, Vector3(.16 * EXTERIOR_WIDTH, -.10, 5.88), floor_mat)
	# Close the small join between the round lining and source tunnel mouth.
	for side: float in [-1.0, 1.0]:
		var reveal := BoxMesh.new()
		reveal.size = Vector3(.20, 6.5, .92)
		_solid(frame, "EntranceReveal", reveal, Vector3(.16 + side * 1.72, 3.25, 5.02), wall_mat)
	_build_arch_infill(frame, wall_mat)
	_build_approach(frame)

static func _build_carved_lining(frame: Node3D, material: Material) -> void:
	# Split the curved surface at every bay edge. Shelf panels close these holes
	# with their own carved reveals; nothing opaque sits behind the openings.
	var openings: Array = SHELVES.wall_openings()
	var angles: Array[float] = []
	var heights: Array[float] = [0.0, 7.2]
	var start := deg_to_rad(20.0)
	var finish := TAU - start
	for i in 129: angles.append(lerpf(start, finish, i / 128.0))
	for opening: Dictionary in openings:
		for edge: float in [opening.angle - opening.half_angle, opening.angle + opening.half_angle]:
			if edge > start and edge < finish and not angles.has(edge): angles.append(edge)
		for y: float in [opening.bottom, opening.top]:
			if not heights.has(y): heights.append(y)
	angles.sort(); heights.sort()
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_material(material)
	for i in angles.size() - 1:
		var middle := (angles[i] + angles[i + 1]) * .5
		for j in heights.size() - 1:
			var y := (heights[j] + heights[j + 1]) * .5
			var cut := false
			for opening: Dictionary in openings:
				if absf(middle - float(opening.angle)) < float(opening.half_angle) and y > float(opening.bottom) and y < float(opening.top):
					cut = true; break
			if cut: continue
			var a := Vector3(sin(angles[i]) * 5.01, heights[j], cos(angles[i]) * 5.01)
			var b := Vector3(sin(angles[i + 1]) * 5.01, heights[j], cos(angles[i + 1]) * 5.01)
			var c := Vector3(b.x, heights[j + 1], b.z)
			var d := Vector3(a.x, heights[j + 1], a.z)
			WINDOWS.wall_quad(surface, a, b, c, d)
	surface.generate_normals()
	var view := MeshInstance3D.new()
	view.name = "CarvedTreeLining"
	view.mesh = surface.commit()
	frame.add_child(view)
	view.create_trimesh_collision()
	for collision: CollisionShape3D in view.find_children("*", "CollisionShape3D", true, false):
		if collision.shape is ConcavePolygonShape3D: collision.shape.backface_collision = true

static func _build_approach(frame: Node3D) -> void:
	# Actual terrain samples at the doubled placement are .30-.36 m below the
	# retained threshold. A 2.07 m ramp embeds its toe below all three width samples.
	var a := Vector3(-1.68 * EXTERIOR_WIDTH, 0, 7.38)
	var b := Vector3(2.0 * EXTERIOR_WIDTH, 0, 7.38)
	var c := Vector3(2.0 * EXTERIOR_WIDTH, -.37, 12.0)
	var d := Vector3(-1.68 * EXTERIOR_WIDTH, -.37, 12.0)
	var down := Vector3(0, -.20, 0)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_material(_wood(Color("9e8567")))
	_quad(surface, a, b, c, d)
	_quad(surface, a + down, d + down, c + down, b + down)
	_quad(surface, a, d, d + down, a + down)
	_quad(surface, b, b + down, c + down, c)
	_quad(surface, d, c, c + down, d + down)
	_quad(surface, a, a + down, b + down, b)
	surface.generate_normals()
	var view := MeshInstance3D.new()
	view.name = "GroundedEntranceRamp"
	view.mesh = surface.commit()
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := ConvexPolygonShape3D.new()
	shape.points = view.mesh.get_faces()
	collision.shape = shape
	body.add_child(collision)
	view.add_child(body)
	frame.add_child(view)

static func _build_arch_infill(frame: Node3D, material: Material) -> void:
	# Seal the lining to the measured tunnel arch, rather than leaving sky visible
	# above its pointed crown. Coordinates come from the removed cap boundary.
	var left := [Vector2(.103, .390), Vector2(.040, 2.094), Vector2(.130, 2.684),
		Vector2(.383, 3.399), Vector2(.495, 3.591), Vector2(.605, 3.712), Vector2(.714, 3.763)]
	var right := [Vector2(1.779, .390), Vector2(1.771, 2.082), Vector2(1.614, 2.659),
		Vector2(1.393, 3.082), Vector2(1.166, 3.412), Vector2(.967, 3.637), Vector2(.825, 3.746), Vector2(.714, 3.763)]
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_material(material)
	for side: int in 2:
		var edge: Array = left if side == 0 else right
		var outside: float = -2.05 if side == 0 else 2.25
		for i: int in edge.size() - 1:
			var a: Vector2 = (edge[i] - Vector2(ROOM_ORIGIN.x, ROOM_ORIGIN.y)) * 2.0
			var b: Vector2 = (edge[i + 1] - Vector2(ROOM_ORIGIN.x, ROOM_ORIGIN.y)) * 2.0
			_quad(surface, Vector3(outside, a.y, 5.538), Vector3(a.x, a.y, 5.538),
				Vector3(b.x, b.y, 5.538), Vector3(outside, b.y, 5.538))
	_quad(surface, Vector3(-2.05, 6.746, 5.538), Vector3(2.25, 6.746, 5.538),
		Vector3(2.25, 7.25, 5.538), Vector3(-2.05, 7.25, 5.538))
	surface.generate_normals()
	var view := MeshInstance3D.new()
	view.name = "TunnelArchLining"
	view.mesh = surface.commit()
	frame.add_child(view)

static func _quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for point: Vector3 in [a, b, c, a, c, d]:
		surface.add_vertex(point)

static func _solid(parent: Node3D, label: String, mesh: PrimitiveMesh, at: Vector3, material: Material) -> MeshInstance3D:
	var view := MeshInstance3D.new()
	view.name = label
	view.mesh = mesh
	view.material_override = material
	view.position = at
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	collision.shape = mesh.create_trimesh_shape()
	body.add_child(collision)
	view.add_child(body)
	parent.add_child(view)
	return view
