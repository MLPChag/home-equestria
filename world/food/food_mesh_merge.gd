extends RefCounted
## Food models arrive as many small parts (the celebration cake has 138, a pie 18), and every
## part was its own draw call: a bakery counter cost ~300 draws. This bakes each model once per
## session into one mesh per role (edible / container / other) with one surface per material, so
## the same triangles, materials and bounds draw in a handful of calls. Instances share the cache.
## Bites still scale the edible role about its base and empties still hide it (food_item.gd).
## Anything the bake cannot reproduce exactly (skins, blend shapes, overlays, custom arrays,
## non-triangle surfaces) returns {} and the caller keeps the original part nodes.
const ROLES: Array[String] = ["edible", "container", "other"]
## Small things stop drawing once they are a few pixels. Godot fades a FADE_SELF instance
## between end - margin and end + margin; ~1220 px per radian on desktop (VR is similar), so
## end = 400 x size starts the dither at ~4 px: a 9 cm strawberry fades 26-43 m, a pie 88-146 m.
## Pickup/purchase bodies and collision are untouched: only drawing stops.
const PIXEL_RULE := 400.0
const MIN_END := 20.0
const MAX_END := 150.0
static var _cache: Dictionary = {}
## path -> why the bake kept the original part nodes (review tooling reads it).
static var skipped: Dictionary = {}

## Size-based visibility range shared by food, price cards and small shop goods.
static func fade_out_far(node: Node, size: float) -> void:
	var end: float = clampf(size * PIXEL_RULE, MIN_END, MAX_END)
	for instance: GeometryInstance3D in _geometry(node):
		# Authored ranges that already stop sooner (paper wrappers) stay as they are.
		if instance.visibility_range_end > 0.0 and instance.visibility_range_end <= end:
			continue
		instance.visibility_range_end = end
		instance.visibility_range_end_margin = end * 0.25
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

## Stock inside a shop room stops where the shut room itself stops (Quality interior_range,
## world/buildings/interior_range.gd: hard 2 m hysteresis), so no food floats past the room.
static func cap_indoor(node: Node, cap: float) -> void:
	if cap <= 0.0:
		return
	for instance: GeometryInstance3D in _geometry(node):
		if instance.visibility_range_end > 0.0 and instance.visibility_range_end <= cap:
			continue
		instance.set_meta(&"indoor_cap_before", [instance.visibility_range_end, instance.visibility_range_end_margin, instance.visibility_range_fade_mode])
		instance.visibility_range_end = cap
		instance.visibility_range_end_margin = 2.0
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

## Bought or picked up: the item leaves the shop room, so its own far fade comes back.
static func uncap_indoor(node: Node) -> void:
	for instance: GeometryInstance3D in _geometry(node):
		if not instance.has_meta(&"indoor_cap_before"): continue
		var before: Array = instance.get_meta(&"indoor_cap_before")
		instance.visibility_range_end = float(before[0])
		instance.visibility_range_end_margin = float(before[1])
		instance.visibility_range_fade_mode = int(before[2]) as GeometryInstance3D.VisibilityRangeFadeMode
		instance.remove_meta(&"indoor_cap_before")

static func _geometry(node: Node) -> Array[GeometryInstance3D]:
	var result: Array[GeometryInstance3D] = []
	if node is GeometryInstance3D:
		result.append(node)
	for each: Node in node.find_children("*", "GeometryInstance3D", true, false):
		result.append(each as GeometryInstance3D)
	return result

## {"bounds": AABB, "parts": [{"role", "mesh", "shadow"}]} in the scene root's parent space, or {}.
static func merged(path: String, all_edible: bool) -> Dictionary:
	var key: String = path + ("|edible" if all_edible else "")
	if _cache.has(key):
		return _cache[key]
	var result: Dictionary = _build(path, all_edible)
	_cache[key] = result
	return result

static func _build(path: String, all_edible: bool) -> Dictionary:
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		return {}
	var root: Node = packed.instantiate()
	if not root is Node3D:
		root.free()
		return {}
	# role|shadow -> material key -> {"material", "parts": [[mesh, surface, transform]]}
	var groups: Dictionary = {}
	groups["_keys"] = {}
	var boxes: Array[AABB] = []
	var ok: bool = _gather(root, root, Transform3D.IDENTITY, "", all_edible, groups, boxes)
	root.free()
	if not ok or boxes.is_empty():
		return {}
	var bounds: AABB = boxes[0]
	for box: AABB in boxes:
		bounds = bounds.merge(box)
	groups.erase("_keys")
	var parts: Array[Dictionary] = []
	for group_key: String in groups:
		var mesh: ArrayMesh = ArrayMesh.new()
		for material_key: Variant in groups[group_key]:
			var entry: Dictionary = groups[group_key][material_key]
			var arrays: Array = _merge_surface(entry.parts, _needs_tangents(entry.material))
			if arrays.is_empty():
				skipped[path] = "arrays unavailable or skinned/custom"
				return {}
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, entry.material)
		var split: PackedStringArray = group_key.split("|")
		parts.append({"role": split[0], "mesh": mesh, "shadow": int(split[1])})
	return {"bounds": bounds, "parts": parts}

## Mirrors food_item.gd _collect: bounds include every mesh, roles come from the nearest
## edible_/container_ ancestor name (the model root's own name included).
static func _gather(node: Node3D, root: Node3D, parent: Transform3D, role: String, all_edible: bool, groups: Dictionary, boxes: Array[AABB]) -> bool:
	var at: Transform3D = parent * node.transform
	var name_text: String = str(node.name)
	# The nearest named ancestor wins, as in food_item.gd _collect.
	if name_text.begins_with("edible_"):
		role = "edible"
	elif name_text.begins_with("container_"):
		role = "container"
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var instance: MeshInstance3D = node
		var mesh: Mesh = instance.mesh
		boxes.append(at * mesh.get_aabb())
		var refusal: String = ""
		if instance.skin != null or (mesh is ArrayMesh and (mesh as ArrayMesh).get_blend_shape_count() > 0):
			refusal = "skin or blend shapes"
		elif instance.material_overlay != null or instance.transparency != 0.0 or instance.layers != 1:
			refusal = "overlay, transparency or layers"
		elif instance.visibility_range_end > 0.0 or instance.visibility_range_begin > 0.0:
			refusal = "own visibility range"
		if not refusal.is_empty():
			skipped[root.scene_file_path] = "%s: %s" % [name_text, refusal]
			return false
		if _visible_chain(instance, root):
			var final_role: String = "edible" if all_edible else (role if not role.is_empty() else "other")
			var group_key: String = "%s|%d" % [final_role, int(instance.cast_shadow)]
			var by_material: Dictionary = groups.get_or_add(group_key, {})
			for surface: int in mesh.get_surface_count():
				if mesh is ArrayMesh and (mesh as ArrayMesh).surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
					skipped[root.scene_file_path] = name_text + ": not triangles"
					return false
				var material: Material = instance.material_override
				if material == null:
					material = instance.get_surface_override_material(surface)
				if material == null:
					material = mesh.surface_get_material(surface)
				# One key per material copy, not per part (property scans are the slow bit).
				var keys: Dictionary = groups["_keys"]
				var material_id: int = material.get_instance_id() if material != null else 0
				if not keys.has(material_id):
					keys[material_id] = _material_key(material)
				var material_key: String = keys[material_id]
				var entry: Dictionary = by_material.get_or_add(material_key, {"material": material, "parts": []})
				entry.parts.append([mesh, surface, at])
	for child: Node in node.get_children():
		if child is Node3D and not _gather(child, root, at, role, all_edible, groups, boxes):
			return false
	return true

## Imports often give every part its own copy of an identical material (the hay bundle has 41).
## Copies whose stored properties all match draw identically, so they share one surface; the
## first copy is used. Shader materials and anything else stay keyed by instance.
static func _material_key(material: Material) -> String:
	if material == null:
		return "none"
	if not material is BaseMaterial3D:
		return "id:%d" % material.get_instance_id()
	var values: Array = [material.get_class()]
	for property: Dictionary in material.get_property_list():
		if (int(property.usage) & PROPERTY_USAGE_STORAGE) == 0 or str(property.name) in ["resource_name", "resource_path", "resource_local_to_scene", "script"]:
			continue
		var value: Variant = material.get(property.name)
		values.append(property.name)
		# Textures and next passes compare by identity, never by serialising their data.
		values.append("object:%d" % (value as Object).get_instance_id() if value is Object else value)
	return var_to_str(values) if values.size() < 400 else "id:%d" % material.get_instance_id()

static func _visible_chain(node: Node, root: Node) -> bool:
	var at: Node = node
	while at != null:
		if at is Node3D and not (at as Node3D).visible:
			return false
		if at == root:
			break
		at = at.get_parent()
	return true

## Only these material features read vertex tangents; without them the tangent array is
## unused by the shader, so the bake skips its per-vertex loop and leaves it out.
static func _needs_tangents(material: Material) -> bool:
	if not material is BaseMaterial3D:
		return true
	var base: BaseMaterial3D = material
	return base.normal_enabled or base.anisotropy_enabled or base.heightmap_enabled or base.clearcoat_enabled or base.detail_enabled

static func _merge_surface(parts: Array, tangents_used: bool = true) -> Array:
	var sources: Array[Array] = []
	var has: Dictionary = {}
	for part: Array in parts:
		var arrays: Array = (part[0] as Mesh).surface_get_arrays(int(part[1]))
		if arrays.size() != Mesh.ARRAY_MAX or arrays[Mesh.ARRAY_VERTEX] == null:
			return []
		for kind: int in [Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS, Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
			if arrays[kind] != null:
				return []
		for kind: int in [Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]:
			if arrays[kind] != null and (kind != Mesh.ARRAY_TANGENT or tangents_used):
				has[kind] = true
		sources.append(arrays)
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var tangents: PackedFloat32Array = PackedFloat32Array()
	var colors: PackedColorArray = PackedColorArray()
	var uvs: PackedVector2Array = PackedVector2Array()
	var uv2s: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()
	for index: int in sources.size():
		var arrays: Array = sources[index]
		var xf: Transform3D = parts[index][2]
		var flip: bool = xf.basis.determinant() < 0.0
		var source_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var count: int = source_vertices.size()
		var base: int = vertices.size()
		vertices.append_array(xf * source_vertices)
		if has.has(Mesh.ARRAY_NORMAL):
			if arrays[Mesh.ARRAY_NORMAL] != null:
				# Inverse transpose keeps normals perpendicular under non-uniform scale; length
				# is irrelevant (octahedral encoding normalises when the surface is stored).
				normals.append_array(Transform3D(xf.basis.inverse().transposed(), Vector3.ZERO) * (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array))
			else:
				_fill_vector3(normals, count, Vector3.UP)
		if has.has(Mesh.ARRAY_TANGENT):
			var source_tangents: Variant = arrays[Mesh.ARRAY_TANGENT]
			if source_tangents != null:
				var packed_tangents: PackedFloat32Array = source_tangents
				var sign_factor: float = -1.0 if flip else 1.0
				for vertex: int in count:
					var tangent: Vector3 = (xf.basis * Vector3(packed_tangents[vertex * 4], packed_tangents[vertex * 4 + 1], packed_tangents[vertex * 4 + 2])).normalized()
					tangents.append(tangent.x)
					tangents.append(tangent.y)
					tangents.append(tangent.z)
					tangents.append(packed_tangents[vertex * 4 + 3] * sign_factor)
			else:
				for vertex: int in count:
					tangents.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 1.0]))
		if has.has(Mesh.ARRAY_COLOR):
			if arrays[Mesh.ARRAY_COLOR] != null:
				colors.append_array(arrays[Mesh.ARRAY_COLOR])
			else:
				var white: PackedColorArray = PackedColorArray()
				white.resize(count)
				white.fill(Color.WHITE)
				colors.append_array(white)
		if has.has(Mesh.ARRAY_TEX_UV):
			if arrays[Mesh.ARRAY_TEX_UV] != null:
				uvs.append_array(arrays[Mesh.ARRAY_TEX_UV])
			else:
				_fill_vector2(uvs, count)
		if has.has(Mesh.ARRAY_TEX_UV2):
			if arrays[Mesh.ARRAY_TEX_UV2] != null:
				uv2s.append_array(arrays[Mesh.ARRAY_TEX_UV2])
			else:
				_fill_vector2(uv2s, count)
		var source_indices: PackedInt32Array = PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			source_indices = arrays[Mesh.ARRAY_INDEX]
		else:
			source_indices.resize(count)
			for vertex: int in count:
				source_indices[vertex] = vertex
		var start: int = indices.size()
		indices.resize(start + source_indices.size())
		for corner: int in source_indices.size():
			indices[start + corner] = source_indices[corner] + base
		if flip:
			# A mirrored part keeps its outside facing out: reverse each triangle's winding.
			for triangle: int in range(start, indices.size() - 2, 3):
				var swap: int = indices[triangle + 1]
				indices[triangle + 1] = indices[triangle + 2]
				indices[triangle + 2] = swap
	if vertices.is_empty():
		return []
	var result: Array = []
	result.resize(Mesh.ARRAY_MAX)
	result[Mesh.ARRAY_VERTEX] = vertices
	result[Mesh.ARRAY_INDEX] = indices
	if has.has(Mesh.ARRAY_NORMAL):
		result[Mesh.ARRAY_NORMAL] = normals
	if has.has(Mesh.ARRAY_TANGENT):
		result[Mesh.ARRAY_TANGENT] = tangents
	if has.has(Mesh.ARRAY_COLOR):
		result[Mesh.ARRAY_COLOR] = colors
	if has.has(Mesh.ARRAY_TEX_UV):
		result[Mesh.ARRAY_TEX_UV] = uvs
	if has.has(Mesh.ARRAY_TEX_UV2):
		result[Mesh.ARRAY_TEX_UV2] = uv2s
	return result

static func _fill_vector3(target: PackedVector3Array, count: int, value: Vector3) -> void:
	var fill: PackedVector3Array = PackedVector3Array()
	fill.resize(count)
	fill.fill(value)
	target.append_array(fill)

static func _fill_vector2(target: PackedVector2Array, count: int) -> void:
	var fill: PackedVector2Array = PackedVector2Array()
	fill.resize(count)
	target.append_array(fill)
