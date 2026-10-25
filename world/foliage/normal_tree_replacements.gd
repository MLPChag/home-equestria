extends RefCounted
## Sliced replacement of ordinary decorative tree roots, before collision/nav staging.
const CATALOGUE := preload("res://world/foliage/grassy_catalogue.gd")
const SCALE := preload("res://world/foliage/vegetation_scale.gd")
const MARK := &"grassy_tree_variant"
var _stack: Array = []
var _choices: Array = []
var _world := Transform3D.IDENTITY
var _collision := true
var bodies: Array = []
var counts := {}
var contacts: Array = []
static var _vertices: Dictionary = {}

static func begin(content: Node, zone_transform: Transform3D, collision := true, zone_id := "") -> RefCounted:
	var job := new()
	job._world = zone_transform; job._collision = collision
	# Keep fruit-bearing orchards, tree buildings and the special Everfree ecosystem.
	var biome := str(WorldLayout.region_of_zone(zone_id).get("biome", ""))
	if biome != "dark_forest" and "--grassy-trees-off" not in preload("res://world/dev_tools.gd").user_args():
		job._choices = CATALOGUE.trees()
		if not job._choices.is_empty(): job._stack.append([content, zone_transform, true])
	return job

static func eligible(name: String, path: String) -> bool:
	var n := name.to_lower(); var p := path.to_lower()
	for protected in ["apple", "orchard", "library", "inn", "house", "bridge", "zecora", "hut", "everfree", "everfree", "rootcluster"]:
		if p.contains(protected): return false
	if n.contains("lod") or n.contains("wood") or n.contains("leaves") or n.ends_with("_col"): return false
	var re := RegEx.new()
	re.compile("^(ck_sprucetree[0-9]+|sprucetree[0-9]+|deciduoustree(cluster)?[0-9]+|tree[0-9]+)(_[a-z]+[0-9]*)?( \\([0-9]+\\))?$")
	return re.search(n) != null

func advance(budget_us := 1000) -> bool:
	var start := Time.get_ticks_usec()
	while not _stack.is_empty():
		var item: Array = _stack.pop_back(); var node: Node = item[0]
		if not is_instance_valid(node): continue
		var xform: Transform3D = item[1]; var visible: bool = item[2]
		if node is Node3D: xform *= node.transform; visible = visible and node.visible
		if not visible: continue
		var path := _path(node)
		if node is Node3D and not node.has_meta(MARK) and eligible(str(node.name), path):
			if _replace(node, xform):
				if Time.get_ticks_usec() - start >= budget_us: return false
				continue
		for child in node.get_children(): _stack.append([child, xform, visible])
		if Time.get_ticks_usec() - start >= budget_us: return false
	return true

static func _path(node: Node) -> String:
	var result := str(node.name); var parent := node.get_parent()
	while parent != null: result = str(parent.name) + "/" + result; parent = parent.get_parent()
	return result

func _replace(node: Node3D, xform: Transform3D) -> bool:
	# Some ordinary-looking outer names wrap a bespoke Everfree tree prefab.
	for child in node.get_children():
		var name := str(child.name).to_lower()
		if name.begins_with("ef-tree") or name.begins_with("everfree"): return false
	var measured := measure(node, xform)
	if measured.is_empty(): return false
	var box: AABB = measured.bounds
	if box.size.y < 4.0 or maxf(box.size.x, box.size.z) > 90.0: return false
	var contact: Vector3 = measured.contact
	var seed_value: int = (floori(contact.x * 13) * 73856093) ^ (floori(contact.z * 13) * 19349663)
	var rng := RandomNumberGenerator.new(); rng.seed = seed_value
	var entry: Dictionary = _choices[rng.randi_range(0, _choices.size() - 1)]
	var packed := CATALOGUE.scene(entry)
	if packed == null: return false
	var replacement := packed.instantiate() as Node3D
	var size_factor := clampf(box.size.y, 6.0, 23.0) / maxf(0.1, float(entry.height))
	# Catalogue geometry retains its buried roots. `support_y` is the authored
	# trunk collar above the lowest root tip after the portable scene is recentered.
	# Keep the measured trunk XZ (some imported roots are offset from their node),
	# but use the imported root's authored Y as the collar instead of putting the
	# lowest root vertex on the terrain surface.
	var support_y := CATALOGUE.support_y(entry)
	var basis := Basis(Vector3.UP, rng.randf_range(-PI, PI)).scaled(Vector3.ONE * size_factor)
	# `xform.origin` is the imported tree's authored placement. Reproduce that
	# collar exactly; applying the full measured contact vector also handles the
	# Sakura's deliberately off-centre root system.
	var desired := Transform3D(basis, xform.origin + basis * CATALOGUE.contact_offset(entry))
	# Keep the imported root identity, remove only its spent runtime decoration.
	for child in node.get_children(): node.remove_child(child); child.free()
	if node is MeshInstance3D: node.mesh = null
	var parent_world := xform * node.transform.affine_inverse()
	node.transform = parent_world.affine_inverse() * desired
	node.set_meta(MARK, entry.id); node.set_meta(SCALE.APPLIED_META, 1.0)
	node.set_meta(&"tree_support_y", support_y)
	node.set_meta(&"tree_collar_offset", CATALOGUE.collar_offset(entry))
	replacement.name = "ApprovedTree"; node.add_child(replacement)
	# Authored LOD distances are in metres; account for the native tree's chosen size.
	for mesh in replacement.find_children("*", "MeshInstance3D", true, false):
		mesh.visibility_range_begin *= size_factor; mesh.visibility_range_end *= size_factor
		mesh.extra_cull_margin = maxf(mesh.extra_cull_margin, 0.8)
	if _collision:
		var body := StaticBody3D.new(); body.name = "Trunk"; body.collision_layer = 1; body.collision_mask = 0
		var shape := CollisionShape3D.new(); var capsule := CylinderShape3D.new()
		capsule.radius = clampf(float(entry.radius) * 0.085, 0.12, 0.65)
		capsule.height = float(entry.height) * 0.60
		shape.shape = capsule
		shape.position = CATALOGUE.collar_offset(entry) + Vector3.UP * capsule.height * 0.5
		body.add_child(shape)
		bodies.append([node, body])
	counts[entry.id] = int(counts.get(entry.id, 0)) + 1
	if contacts.size() < 32: contacts.append({"variant": entry.id, "contact": contact, "height": float(entry.height) * size_factor})
	return true

static func measure(node: Node3D, xform: Transform3D) -> Dictionary:
	var stack := [[node, xform, true]]; var points := PackedVector3Array(); var bounds := AABB(); var first := true
	var bottom := INF
	while not stack.is_empty():
		var item: Array = stack.pop_back(); var current: Node = item[0]; var world: Transform3D = item[1]; var visible: bool = item[2]
		if not visible: continue
		if current is MeshInstance3D and current.mesh != null:
			var mesh: Mesh = current.mesh; var box := world * mesh.get_aabb()
			bounds = box if first else bounds.merge(box); first = false
			if _vertices.size() > 128: _vertices.clear()
			if not _vertices.has(mesh):
				var vertices := PackedVector3Array()
				for s in mesh.get_surface_count(): vertices.append_array(mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX])
				_vertices[mesh] = vertices
			for v: Vector3 in _vertices[mesh]:
				var point := world * v
				if not point.is_finite(): continue
				points.append(point); bottom = minf(bottom, point.y)
		for child in current.get_children():
			stack.append([child, world * child.transform if child is Node3D else world, visible and child.visible if child is Node3D else visible])
	if points.is_empty() or not is_finite(bottom): return {}
	# A transformed AABB is conservative: after a tilt its lowest corner often has
	# no mesh vertex there. Using that corner left the contact set empty, and the
	# old divide-by-one fallback collapsed otherwise unrelated trees to world XZ 0.
	var contact := Vector3.ZERO; var count := 0
	for p in points:
		if p.y <= bottom + maxf(0.1, bounds.size.y * 0.015): contact += p; count += 1
	if count == 0: return {}
	contact /= count; contact.y = bottom
	return {"bounds": bounds, "contact": contact}
