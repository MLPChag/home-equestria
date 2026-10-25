extends RefCounted
## Counter fixtures follow the authored metre geometry; house scaling stays on its parent.
const STATION := preload("res://world/cooking/cooking_station.gd")
const TOOLS := preload("res://world/cooking/cooking_tools.scn")
static var _solids: Dictionary = {}

static func attach(model: Node3D, home: Node, kind: String) -> Node3D:
	if kind not in ["kitchen-island", "compact-kitchen"] or model.has_node("HomeCooking"): return null
	var home_id: String = str(home.place_id()) if home.has_method("place_id") else ""
	if home_id.is_empty(): return null
	var station := TOOLS.instantiate() as Node3D
	station.name = "HomeCooking"
	station.set_script(STATION)
	station.station_id = home_id + ":" + str(model.name)
	# Source counter, original cast burner, original front dial. No floating proxy height.
	var compact := kind == "compact-kitchen"
	station.pan = station.get_node("Pan")
	station.knob = station.get_node("Knob")
	station.heat_visual = station.get_node("Heat")
	station.knob_visual = station.get_node("Knob/Visual")
	station.status = station.get_node("Status/Face")
	station.pan.position = Vector3(-.32, .849, .12) if compact else Vector3(-.56, .901, .14)
	station.knob.position = Vector3(-.46, .64, .309) if compact else Vector3(-.64, .72, .418)
	station.heat_visual.position = station.pan.position + Vector3(0, .004, 0)
	station.get_node("RecipeCard").position = Vector3(-.32, 1.04, -.25) if compact else Vector3(-.50, 1.10, -.37)
	station.get_node("Status").position = station.knob.position + Vector3(.10, .075, .016)
	station.status.material_override = station.status.material_override.duplicate()
	for target: StaticBody3D in [station.pan, station.knob]:
		target.set_meta("home_cooker", station)
	station.pan.set_meta("cooker_role", "pan")
	station.knob.set_meta("cooker_role", "knob")
	_exact_collision(model, kind)
	model.add_child(station)
	return station

static func _exact_collision(model: Node3D, kind: String) -> void:
	# The old bounds include the tap: they block hands/food above the real worktop.
	# Cache one static source-triangle resource per model, not one copy per house.
	if not _solids.has(kind):
		var faces := PackedVector3Array()
		var meshes: Array[Node] = model.find_children("*", "MeshInstance3D", true, false)
		if model is MeshInstance3D: meshes.push_front(model)
		for mesh: MeshInstance3D in meshes:
			if mesh.mesh == null: continue
			var relative := Transform3D.IDENTITY
			var node: Node3D = mesh
			while node != model:
				relative = node.transform * relative
				node = node.get_parent() as Node3D
			faces.append_array(relative * mesh.mesh.get_faces())
		if faces.is_empty():
			push_error("Cooking counter has no authored collision triangles: " + kind)
			return
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces); shape.backface_collision = true
		_solids[kind] = shape
	for name: String in ["Collision", "KitchenSolid"]:
		var old: Node = model.get_node_or_null(name)
		if old != null:
			model.remove_child(old); old.queue_free()
	var body := StaticBody3D.new(); body.name = "CookingCounterSolid"
	body.collision_layer = 1; body.collision_mask = 0
	var holder := CollisionShape3D.new(); holder.shape = _solids[kind]
	body.add_child(holder); model.add_child(body)
