extends RefCounted
## Exact authored-material omissions, shared by detailed zones and old distant bakes.
## Never edits source resources; partial merged meshes keep their other surfaces/LODs.
static func apply(root: Node, names: Array) -> Dictionary:
	var stats := {"nodes": 0, "surfaces": 0}
	if names.is_empty(): return stats
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		var mesh: Mesh
		if node is MeshInstance3D: mesh = node.mesh
		elif node is MultiMeshInstance3D and node.multimesh != null: mesh = node.multimesh.mesh
		var remove: Array[int] = []
		if mesh != null:
			for surface in mesh.get_surface_count():
				var material: Material = node.material_override
				if material == null:
					material = node.get_active_material(surface) if node is MeshInstance3D else mesh.surface_get_material(surface)
				if material != null and material.resource_name in names: remove.append(surface)
		if not remove.is_empty():
			stats.surfaces += remove.size()
			if remove.size() == mesh.get_surface_count() and node != root:
				# Collision children leave with the rejected visual in detailed zones.
				node.get_parent().remove_child(node)
				node.queue_free()
				stats.nodes += 1
				continue
			if mesh is ArrayMesh:
				var copy := mesh.duplicate() as ArrayMesh
				copy.shadow_mesh = null
				for index in range(remove.size() - 1, -1, -1): copy.surface_remove(remove[index])
				if node is MeshInstance3D:
					# Reindex per-node overrides with the surviving surfaces.
					var overrides: Array[Material] = []
					for surface in mesh.get_surface_count():
						if surface not in remove: overrides.append(node.get_surface_override_material(surface))
					node.mesh = copy
					for surface in overrides.size(): node.set_surface_override_material(surface, overrides[surface])
				else:
					var multimesh: MultiMesh = node.multimesh.duplicate()
					multimesh.mesh = copy
					node.multimesh = multimesh
		for child in node.get_children(): pending.append(child)
	return stats
