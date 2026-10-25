extends RefCounted
## dev 2026-09-26 (docs/PERF_REPORT_2026_09_26.md, item 2): every house drew its window pieces
## (reveal, sash, glass and their room faces, ~90 per house) as separate draw calls, 1,620 draws
## in one view of Ponyville. When a house has been set up (house_interior.gd), its visible, static
## window and door-frame pieces are merged into one mesh per material and render setting: about
## five draws per house. The door leaf (it opens) and skinned meshes stay as they are. Pieces with a
## collider child keep their node and collision and lose only their mesh. The glass boxes are kept in the house's `window_glass_boxes` meta for the furnisher.

## Window and door-frame pieces by name ("FrontWindow3Sash", "BackWindow1Glass", "DoorReveal", …).
static func _is_window_part(node: Node) -> bool:
	var n := str(node.name)
	return ("Window" in n or n.begins_with("DoorReveal")) and not n.begins_with("FrontDoor")

## Same as town_render_budget.gd SMALL_CASTER (not preloaded: that script preloads house_interior).
const SMALL_CASTER := 1.6

static func merge(house: Node3D) -> int:
	var groups := {}
	var order: Array = []
	var boxes: Array = []
	var merged := 0
	var to_house := house.global_transform.affine_inverse()
	for node: MeshInstance3D in house.find_children("*", "MeshInstance3D", true, false):
		if not _is_window_part(node) or node.mesh == null: continue
		# (MeshInstance3D.skeleton defaults to "..", so the skin is the only sign of a skinned mesh.)
		if node.skin != null: continue
		if _inside_door(node, house): continue
		if "Glass" in str(node.name):
			boxes.append(node.global_transform * node.get_aabb())
		if not node.is_visible_in_tree(): continue
		var local := to_house * node.global_transform
		for surface in node.mesh.get_surface_count():
			var material := node.get_active_material(surface)
			# town_render_budget.gd turns sun shadows off for pieces under 1.6 m; a merged mesh
			# spans the house, so apply that per piece here, before the pieces are gone.
			var cast := node.cast_shadow
			if (node.global_transform * node.get_aabb()).get_longest_axis_size() < SMALL_CASTER:
				cast = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var key := [material, node.material_overlay, node.layers, cast, node.visibility_range_begin,
				node.visibility_range_end, node.visibility_range_end_margin, node.visibility_range_fade_mode, node.gi_mode]
			# The house scenes carry one copy of the sash material per window; equal copies share a batch.
			var id := str(key.map(func(v): return _signature(v) if v is Material else v))
			if not groups.has(id):
				var tool := SurfaceTool.new(); tool.begin(Mesh.PRIMITIVE_TRIANGLES)
				groups[id] = {"key": key, "tool": tool, "count": 0}
				order.append(id)
			var entry: Dictionary = groups[id]
			if node.mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES: continue
			(entry.tool as SurfaceTool).append_from(node.mesh, surface, local)
			entry.count += 1
		# Most pieces carry their collider (a "<name>_col" StaticBody3D child): keep the node and
		# its collision, drop only its drawing.
		if node.get_child_count() > 0: node.mesh = null
		else: node.queue_free()
		merged += 1
	var index := 0
	for id in order:
		var entry: Dictionary = groups[id]
		if int(entry.count) == 0: continue
		var key: Array = entry.key
		var tool: SurfaceTool = entry.tool
		if key[0] != null: tool.set_material(key[0])
		var mi := MeshInstance3D.new(); mi.name = "MergedWindows%d" % index; index += 1
		mi.mesh = tool.commit()
		mi.material_overlay = key[1]; mi.layers = key[2]; mi.cast_shadow = key[3]
		mi.visibility_range_begin = key[4]; mi.visibility_range_end = key[5]
		mi.visibility_range_end_margin = key[6]; mi.visibility_range_fade_mode = key[7]; mi.gi_mode = key[8]
		house.add_child(mi)
	house.set_meta("window_glass_boxes", boxes)
	return merged

## A material's stored settings (textures and other resources by identity), so equal copies match.
static var _signatures := {}
static func _signature(material: Material) -> String:
	var id := material.get_instance_id()
	if _signatures.has(id): return _signatures[id]
	var parts: Array[String] = [material.get_class()]
	for property in material.get_property_list():
		if not (int(property.usage) & PROPERTY_USAGE_STORAGE): continue
		if str(property.name) in ["resource_name", "resource_path", "resource_local_to_scene", "resource_scene_unique_id"]: continue
		var value: Variant = material.get(property.name)
		parts.append(str(property.name) + "=" + (str(value.get_instance_id()) if value is Object else var_to_str(value)))
	var signature := "|".join(parts)
	_signatures[id] = signature
	return signature

static func _inside_door(node: Node, house: Node) -> bool:
	var at := node.get_parent()
	while at != null and at != house:
		if str(at.name).begins_with("FrontDoor") or at.get_script() != null: return true
		at = at.get_parent()
	return false
