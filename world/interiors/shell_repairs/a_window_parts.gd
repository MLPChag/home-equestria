extends RefCounted
## Six measured window parts; preserve materials and replace matching collision.
const DATA: String = "res://world/interiors/shell_repairs/a_window_parts.json"
const WALL_BACK: float = -0.359136402606964
static var _parts: Array = []
static var _meshes: Dictionary = {}

static func matches(house: Node3D) -> bool:
	if _parts.is_empty():
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA))
		_parts = data.get("parts", [])
	if _parts.size() != 6:
		return false
	for value: Variant in _parts:
		var part: Dictionary = value
		var node: MeshInstance3D = house.get_node_or_null(str(part["node"])) as MeshInstance3D
		if node == null or node.mesh == null:
			return false
		var arrays: Array = node.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var expected: Array = part["source_vertices"]
		if vertices.size() != expected.size():
			return false
		for i: int in vertices.size():
			var point: Array = expected[i]
			if (node.transform * vertices[i]).distance_to(_vector(point)) > 0.000001:
				return false
		var expected_indices: Array = part["source_indices"]
		var indices: PackedInt32Array = PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			indices = arrays[Mesh.ARRAY_INDEX]
		else:
			for i: int in vertices.size():
				indices.append(i)
		if indices.size() != expected_indices.size():
			return false
		for i: int in indices.size():
			if indices[i] != int(expected_indices[i]):
				return false
		for shape: CollisionShape3D in node.find_children("*", "CollisionShape3D", true, false):
			if not shape.transform.is_equal_approx(Transform3D.IDENTITY) or not (shape.get_parent() as Node3D).transform.is_equal_approx(Transform3D.IDENTITY):
				return false
	return true

static func apply(house: Node3D) -> void:
	for value: Variant in _parts:
		var part: Dictionary = value
		var name: String = str(part["node"])
		var node: MeshInstance3D = house.get_node(name) as MeshInstance3D
		if not _meshes.has(name):
			_meshes[name] = _build(part)
		var mesh: ArrayMesh = _meshes[name] as ArrayMesh
		var material: Material = node.get_active_material(0)
		# Captured vertices already include the old reveal's sheared basis.
		# Physics bodies cannot reproduce that shear; use house-space vertices
		# and identity transforms for both rendering and collision.
		node.transform = Transform3D.IDENTITY
		node.mesh = mesh
		node.set_surface_override_material(0, material)
		var room: MeshInstance3D = house.get_node_or_null(name + "RoomFace") as MeshInstance3D
		if room != null:
			room.transform = Transform3D.IDENTITY
			room.mesh = mesh
		for holder: CollisionShape3D in node.find_children("*", "CollisionShape3D", true, false):
			var shape: ConcavePolygonShape3D = mesh.create_trimesh_shape()
			shape.backface_collision = true
			holder.shape = shape
	house.set_meta("a_window_slabs_repaired", true)

static func _vector(point: Array) -> Vector3:
	return Vector3(float(point[0]), float(point[1]), float(point[2]))

static func _build(part: Dictionary) -> ArrayMesh:
	var points: Array = part["vertices"]
	var indices: Array = part["indices"]
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var draw_indices: PackedInt32Array = PackedInt32Array()
	for i: int in range(0, indices.size(), 3):
		var a: Vector3 = _vector(points[int(indices[i])])
		var b: Vector3 = _vector(points[int(indices[i+1])])
		var c: Vector3 = _vector(points[int(indices[i+2])])
		# Blender's hole fill capped the reveal's inner loop as a solid disc.
		# This cut plane meets the closed new wall; keep the reveal sides and
		# outer lip, but never put an opaque cap across the glazing aperture.
		if str(part["node"]).ends_with("WindowReveal") and absf(a.z-WALL_BACK)<0.000001 and absf(b.z-WALL_BACK)<0.000001 and absf(c.z-WALL_BACK)<0.000001:
			continue
		var cross: Vector3 = (b-a).cross(c-a)
		if cross.length_squared() < 1.0e-24:
			continue
		var normal: Vector3 = cross.normalized()
		# Native CCW -> Godot clockwise, keeping native outward normals.
		for point: Vector3 in [a,c,b]:
			draw_indices.append(vertices.size())
			vertices.append(point)
			normals.append(normal)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	# Window batching appends to indexed source meshes. Unindexed vertices would
	# be appended without draw indices and disappear from that indexed batch.
	arrays[Mesh.ARRAY_INDEX] = draw_indices
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
