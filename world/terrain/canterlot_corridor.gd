extends RefCounted
## Shared bounded lowering for imported shells, before collision is built.
const PATH := "res://world/terrain/canterlot_corridor.json"

static func height_at(point: Vector3, config: Dictionary) -> float:
	var x: Array = config.x
	var z: Array = config.z
	var weight := smoothstep(x[0], x[1], point.x) * (1.0 - smoothstep(x[2], x[3], point.x))
	weight *= smoothstep(z[0], z[1], point.z) * (1.0 - smoothstep(z[2], z[3], point.z))
	var cap := lerpf(float(config.south_height), float(config.north_height), (1.0 - smoothstep(z[1], z[2], point.z)))
	return lerpf(point.y, minf(point.y, cap), weight)

static func apply(root: Node3D) -> int:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	var origin := Vector3(config.zone_origin[0], config.zone_origin[1], config.zone_origin[2])
	var changed := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if str(node.name) not in config.mesh_names: continue
		var transform := Transform3D.IDENTITY
		var parent: Node3D = node
		while parent != root and parent != null:
			transform = parent.transform * transform
			parent = parent.get_parent() as Node3D
		transform.origin += origin
		var inverse := transform.affine_inverse()
		var mesh := ArrayMesh.new()
		for surface in node.mesh.get_surface_count():
			var arrays: Array = node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for i in vertices.size():
				var point: Vector3 = transform * vertices[i]
				var height := height_at(point, config)
				if height < point.y:
					point.y = height; vertices[i] = inverse * point; changed += 1
			arrays[Mesh.ARRAY_VERTEX] = vertices
			var raw := ArrayMesh.new(); raw.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var tool := SurfaceTool.new(); tool.create_from(raw, 0); tool.generate_normals()
			tool.set_material(node.mesh.surface_get_material(surface)); tool.commit(mesh)
		node.mesh = mesh
	return changed

static func apply_proxy(root: Node3D, source: String) -> void:
	# Offline mesh replacements preserve the original proxy's MultiMesh buffers.
	# A freshly rebuilt full proxy already contains the lowered geometry.
	var path := "res://world/zones/canterlot/corridor_proxy/index.json"
	if not FileAccess.file_exists(path): return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	if int(data.source_mtime) != FileAccess.get_modified_time(source): return
	for node_path in data.meshes:
		var node := root.get_node_or_null(NodePath(node_path)) as MeshInstance3D
		if node != null: node.mesh = load(data.meshes[node_path])
