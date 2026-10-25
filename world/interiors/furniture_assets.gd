extends RefCounted
## furniture assets extracted from interior_furnisher.gd.
## State and callback dispatch stay on the owning instance; authored transforms and order are unchanged.

const KIT_PATH := "res://world/interiors/interior_kit.json"
const MANIFEST_PATH := "res://world/props/household/manifest.json"
const PROP_DIR := "res://world/props/household/"
const SEAT := preload("res://world/life/seat.gd")
static var _boxes := {}      # prop id -> AABB in model units
static var _kit := {}
static var _requested := {}
static var _scenes := {}     # prop id -> PackedScene
static var _sizes := {}      # prop id -> Vector3 metres (width x, height y, depth z)
static var _window_bounds: Dictionary = {}

static func load_kit() -> void:
	if not _kit.is_empty(): return
	_kit = JSON.parse_string(FileAccess.get_file_as_string(KIT_PATH))
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	for asset: Dictionary in manifest.get("assets", []):
		var size: Dictionary = asset.get("suggested_size_m", {})
		if size.has("x"): _sizes[asset.id] = Vector3(size.x, size.y_height, size.z)
	# Kit entries that reuse another model (the tall cupboard is a pantry in a kitchen, a
	# wardrobe in a bedroom).
	for id: String in _kit.props:
		var model := _model(id)
		if model != id and _sizes.has(model): _sizes[id] = _sizes[model]

static func _model(id: String) -> String:
	return str(_kit.props.get(id, {}).get("model", id))

static func _source_windows(house: Node3D) -> Array[Dictionary]:
	var path: String = house.scene_file_path
	if not path.is_empty() and _window_bounds.has(path): return _window_bounds[path]
	var source: Node3D = house
	if not path.is_empty():
		var packed: PackedScene = load(path) as PackedScene
		if packed != null: source = packed.instantiate() as Node3D
		# Measure the same repaired window reveals that the live house renders.
		if source != house: preload("res://world/interiors/shell_repairs.gd").apply(source)
	var parts: Array[Dictionary] = []
	var result: Array[Dictionary] = []
	for mesh: MeshInstance3D in source.find_children("*Window*", "MeshInstance3D", true, false):
		if mesh.mesh == null or str(mesh.name).begins_with("MergedWindows"): continue
		var transform: Transform3D = Transform3D.IDENTITY
		var at: Node3D = mesh
		while at != source:
			transform = at.transform * transform
			at = at.get_parent() as Node3D
		var bounds: AABB = transform * mesh.get_aabb()
		var part_name: String = str(mesh.name)
		parts.append({"name": part_name, "bounds": bounds})
		if "Glass" in part_name:
			result.append({"prefix": part_name.get_slice("Glass", 0), "glass": bounds, "frame": bounds})
	for part: Dictionary in parts:
		# Longest prefix distinguishes Window1 from Window10, even after batching
		# has discarded the original frame meshes in the live house.
		var match_index: int = -1
		var match_length: int = -1
		for i: int in result.size():
			var prefix: String = result[i].prefix
			if str(part.name).begins_with(prefix) and prefix.length() > match_length:
				match_index = i
				match_length = prefix.length()
		if match_index >= 0:
			var bounds: AABB = result[match_index].frame
			result[match_index].frame = bounds.merge(part.bounds)
	if source != house: source.free()
	if not path.is_empty(): _window_bounds[path] = result
	return result

static func _visible_size(id: String) -> Vector3:
	var model_id: String = _model(id)
	if not _boxes.has(model_id):
		var model: Node3D = _scene(model_id).instantiate() as Node3D
		_model_box(model_id, model)
		model.free()
	var box: AABB = _boxes[model_id]
	var requested: Vector3 = _sizes[id]
	return box.size * (maxf(requested.x, maxf(requested.y, requested.z)) / maxf(box.get_longest_axis_size(), 1e-6))

static func _add_seating(model: Node3D, seating: Dictionary, box: AABB, k: float, is_couch := false) -> void:
	var frame := Node3D.new()
	frame.name = "Seating"
	frame.transform = Transform3D(Basis.from_scale(Vector3.ONE / maxf(k, 1e-6)), Vector3(box.get_center().x, box.position.y, box.get_center().z))
	model.add_child(frame)
	for part_name in ["solid", "upper"]:
		var parts: Array = seating.get(part_name, [])
		if parts.is_empty(): continue
		var body := StaticBody3D.new()
		body.name = "SeatSolid" if part_name == "solid" else "SeatUpper"
		body.collision_layer = 1
		body.collision_mask = 0
		for part: Array in parts:
			var holder := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3(part[1][0], part[1][1], part[1][2])
			holder.shape = shape
			holder.position = Vector3(part[0][0], part[0][1], part[0][2])
			body.add_child(holder)
		frame.add_child(body)
	var n := 0
	for spot: Array in seating.get("seats", []):
		var seat := Node3D.new()
		seat.set_script(SEAT)
		seat.name = "Seat%d" % n
		n += 1
		seat.depth = float(seating.get("depth", 0.45))
		# The sitter faces the prop's front (+Z); a seat faces its -Z.
		seat.transform = Transform3D(Basis(Vector3.UP, PI), Vector3(spot[0], spot[1], spot[2]))
		frame.add_child(seat)
	if is_couch:
		preload("res://world/life/couch.gd").install(frame)

static func _scene_path(id: String) -> String:
	var packed: String = PROP_DIR + id + ".scn"
	return packed if ResourceLoader.exists(packed) else PROP_DIR + id + ".glb"

static func _scene(id: String) -> PackedScene:
	if not _scenes.has(id):
		var path := _scene_path(id)
		_scenes[id] = ResourceLoader.load_threaded_get(path) if _requested.has(path) else load(path)
		_requested.erase(path)
	return _scenes[id]

static func props_loaded() -> bool:
	load_kit()
	var done := true
	for id: String in _kit.props:
		id = _model(id)
		var path := _scene_path(id)
		if _scenes.has(id) or not ResourceLoader.exists(path): continue
		if not _requested.has(path):
			_requested[path] = true
			ResourceLoader.load_threaded_request(path)
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS: done = false
		elif status == ResourceLoader.THREAD_LOAD_LOADED:
			# A random layout may never select this prop. Claim its completed native load
			# now instead of leaving a LoadToken alive until some house happens to use it.
			_scenes[id] = ResourceLoader.load_threaded_get(path)
			_requested.erase(path)
		elif status != ResourceLoader.THREAD_LOAD_LOADED: _requested.erase(path)
	return done

static func _model_box(id: String, model: Node3D) -> AABB:
	if _boxes.has(id): return _boxes[id]
	var box := AABB()
	var first := true
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null: continue
		var xf := Transform3D.IDENTITY
		var n: Node = mi
		while n != model and n is Node3D:
			xf = (n as Node3D).transform * xf
			n = n.get_parent()
		var b := xf * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	_boxes[id] = box
	return box

