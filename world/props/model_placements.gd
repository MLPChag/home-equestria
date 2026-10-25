class_name ModelPlacements
extends Node3D

## Persistent, authored Grassy Fields model instances. The JSON catalogue is cheap
## metadata; PackedScenes are loaded only when a placement actually references one.

const WORKING_PATH := "user://world_editor/model_placements.json"
const PUBLISHED_PATH := "res://world/props/model_placements.json"
const CATALOGUE_PATH := "res://world/foliage/grassy_fields/catalogue_grassy.json"
const GRASSY := preload("res://world/foliage/grassy_catalogue.gd")
const CLIFF_SHADER := "res://world/terrain/kits/grassy_fields/cliff.gdshader"

signal changed
signal bounds_changed(bounds: AABB)

@export var working_path := WORKING_PATH
@export var published_path := PUBLISHED_PATH
@export var catalogue_path := CATALOGUE_PATH
var entries: Array[Dictionary] = []
var _instances: Dictionary = {}
var _catalogue_rows: Dictionary = {}
var _shape_cache: Dictionary = {}
var _host: Node3D
var _runtime_enabled := true
var terrain_data: Object


func _ready() -> void:
	add_to_group("model_placements_runtime")


static func read(path: String) -> Array[Dictionary]:
	if not FileAccess.file_exists(path): return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var result: Array[Dictionary] = []
	var seen := {}
	if parsed is Dictionary:
		for value in parsed.get("placements", []):
			if value is Dictionary and _valid(value):
				var row: Dictionary = value.duplicate(true)
				var uid := String(row.get("uid", ""))
				if seen.has(uid): continue
				seen[uid] = true
				row["collision"] = bool(row.get("collision", false))
				result.append(row)
	return result


static func _valid(value: Dictionary) -> bool:
	var t: Array = value.get("transform", [])
	if String(value.get("uid", "")).is_empty() or String(value.get("id", "")).is_empty() or t.size() != 10: return false
	for number in t:
		if not is_finite(float(number)): return false
	return float(t[6]) > 0.0 and float(t[7]) > 0.0 and float(t[8]) > 0.0


static func atomic_write(path: String, data: Dictionary) -> Error:
	var absolute := ProjectSettings.globalize_path(path)
	var err := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if err != OK: return err
	var temporary := absolute + ".pending-%d" % Time.get_ticks_usec()
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "\t") + "\n")
	file.close()
	return DirAccess.rename_absolute(temporary, absolute)


func load_saved(working := false) -> void:
	var path := working_path if working and FileAccess.file_exists(working_path) else published_path
	entries = read(path)
	changed.emit()


func save(publish := false) -> Error:
	var clean: Array[Dictionary] = []
	for entry in entries:
		if _valid(entry): clean.append(entry.duplicate(true))
	return atomic_write(published_path if publish else working_path, {"version": 1, "placements": clean})


func set_entries(value: Array[Dictionary]) -> void:
	entries.clear()
	var seen := {}
	for source in value:
		if not _valid(source): continue
		var uid := String(source.uid)
		if seen.has(uid): continue
		seen[uid] = true
		entries.append(source.duplicate(true))
	changed.emit()


func set_runtime_enabled(enabled: bool) -> void:
	_runtime_enabled = enabled
	visible = enabled
	if enabled: sync(_host)
	else: clear_instances()


func sync(parent: Node3D = null) -> void:
	if parent != null: _host = parent
	if _host == null: _host = self
	if not _runtime_enabled: return
	_ensure_catalogue()
	var desired := {}
	for entry in entries: desired[String(entry.uid)] = entry
	var affected := AABB()
	var has_affected := false
	for uid in _instances.keys():
		if desired.has(uid): continue
		var old: Node3D = _instances[uid]
		if is_instance_valid(old):
			var box := visual_bounds(old)
			if box.size != Vector3.ZERO: affected = box if not has_affected else affected.merge(box); has_affected = true
			old.queue_free()
		_instances.erase(uid)
	for entry in entries:
		var uid := String(entry.uid)
		var fingerprint := _fingerprint(entry)
		var node: Node3D = _instances.get(uid)
		if is_instance_valid(node) and String(node.get_meta(&"placement_fingerprint", "")) == fingerprint: continue
		if is_instance_valid(node):
			var old_box := visual_bounds(node)
			if old_box.size != Vector3.ZERO: affected = old_box if not has_affected else affected.merge(old_box); has_affected = true
			node.queue_free()
		node = _spawn(entry, _host)
		if node == null: _instances.erase(uid); continue
		_instances[uid] = node
		var new_box := visual_bounds(node)
		if new_box.size != Vector3.ZERO: affected = new_box if not has_affected else affected.merge(new_box); has_affected = true
	changed.emit()
	if has_affected: bounds_changed.emit(affected)


func clear_instances() -> void:
	var affected := AABB()
	var found := false
	for node in _instances.values():
		if is_instance_valid(node):
			var box := visual_bounds(node)
			if box.size != Vector3.ZERO: affected = box if not found else affected.merge(box); found = true
			node.queue_free()
	_instances.clear()
	if found: bounds_changed.emit(affected)


func instance_for(uid: String) -> Node3D:
	return _instances.get(uid)


func catalogue_entries() -> Array[Dictionary]:
	_ensure_catalogue()
	var result: Array[Dictionary] = []
	for row in _catalogue_rows.values(): result.append(row)
	result.sort_custom(func(a, b): return String(a.get("name", a.id)).naturalnocasecmp_to(String(b.get("name", b.id))) < 0)
	return result


func catalogue_entry(id: String) -> Dictionary:
	_ensure_catalogue()
	return _catalogue_rows.get(id, {})


func instantiate_asset(id: String) -> Node3D:
	_ensure_catalogue()
	var row: Dictionary = _catalogue_rows.get(id, {})
	var path := String(row.get("scene", ""))
	if path.is_empty() or not ResourceLoader.exists(path): return null
	var packed := load(path) as PackedScene
	return packed.instantiate() as Node3D if packed != null else null


func _spawn(entry: Dictionary, parent: Node3D) -> Node3D:
	var node := instantiate_asset(String(entry.id))
	if node == null: return null
	node.name = "Placed_%s_%s" % [String(entry.id), String(entry.uid)]
	node.transform = transform_from_data(entry.transform)
	node.set_meta(&"placement_uid", String(entry.uid))
	node.set_meta(&"placement_fingerprint", _fingerprint(entry))
	parent.add_child(node)
	update_surface_contact(node)
	if bool(entry.get("collision", false)): _attach_collision(node, catalogue_entry(String(entry.id)))
	return node


func update_surface_contact(node: Node3D) -> void:
	# Instance uniforms keep the immutable catalogue material shared. Cache the
	# affected meshes so dragging only samples the CPU heightfield once per model.
	if not node.has_meta(&"terrain_contact_meshes"):
		var meshes: Array[MeshInstance3D] = []
		for child in node.find_children("*", "MeshInstance3D", true, false):
			var mesh := child as MeshInstance3D
			if mesh.mesh == null: continue
			for surface in mesh.mesh.get_surface_count():
				var material := mesh.get_active_material(surface) as ShaderMaterial
				if material != null and material.shader != null and material.shader.resource_path == CLIFF_SHADER:
					meshes.append(mesh)
					break
		node.set_meta(&"terrain_contact_meshes", meshes)
	var affected: Array = node.get_meta(&"terrain_contact_meshes")
	if affected.is_empty(): return
	var plane := contact_plane(terrain_data, node.global_position)
	for mesh: MeshInstance3D in affected:
		if not is_instance_valid(mesh): continue
		mesh.set_instance_shader_parameter(&"use_terrain_contact", true)
		mesh.set_instance_shader_parameter(&"terrain_contact_plane", plane)


static func contact_plane(data: Object, position: Vector3) -> Vector4:
	if not is_instance_valid(data): return Vector4.ZERO
	var height: float = data.get_height(position)
	if not is_finite(height): return Vector4.ZERO
	var normal: Vector3 = data.get_normal(position)
	if not normal.is_finite() or normal.length_squared() < 0.5 or normal.y <= 0.01:
		normal = Vector3.UP
	normal = normal.normalized()
	var ground := Vector3(position.x, height, position.z)
	return Vector4(normal.x, normal.y, normal.z, -normal.dot(ground))


func refresh_surface_contacts(_bounds := AABB()) -> void:
	for node in _instances.values():
		if is_instance_valid(node): update_surface_contact(node)


func _attach_collision(node: Node3D, row: Dictionary) -> void:
	var lod := 1 if String(row.get("category", "")) in ["cliff", "mountain", "rock"] and int(row.get("lods", []).size()) > 1 else 0
	var key := "%s:%d" % [String(row.get("id", "")), lod]
	if not _shape_cache.has(key):
		var built: Array = []
		for part in GRASSY.parts(row, lod):
			var mesh: Mesh = part[0]
			var shape := mesh.create_trimesh_shape()
			if shape != null: built.append([shape, part[1]])
		_shape_cache[key] = built
	var body := StaticBody3D.new()
	body.name = "AuthoredCollision"
	body.collision_layer = 1
	body.collision_mask = 1
	node.add_child(body)
	for item in _shape_cache[key]:
		var collision := CollisionShape3D.new()
		collision.shape = item[0]
		collision.transform = item[1]
		body.add_child(collision)


func _ensure_catalogue() -> void:
	if not _catalogue_rows.is_empty() or not FileAccess.file_exists(catalogue_path): return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(catalogue_path))
	if not parsed is Dictionary: return
	for value in parsed.get("assets", []):
		if value is Dictionary and not String(value.get("scene", "")).is_empty(): _catalogue_rows[String(value.get("id", ""))] = value


static func transform_from_data(data: Array) -> Transform3D:
	var scale := Vector3(maxf(0.001, float(data[6])), maxf(0.001, float(data[7])), maxf(0.001, float(data[8])))
	return Transform3D(Basis.from_euler(Vector3(float(data[3]), float(data[4]), float(data[5]))).scaled_local(scale), Vector3(float(data[0]), float(data[1]), float(data[2])))


static func visual_bounds(node: Node3D) -> AABB:
	var result := AABB()
	var found := false
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.mesh == null or not mesh.visible: continue
		var box: AABB = mesh.global_transform * mesh.get_aabb()
		result = box if not found else result.merge(box)
		found = true
	return result if found else AABB(node.global_position - Vector3.ONE * 0.25, Vector3.ONE * 0.5)


static func _fingerprint(entry: Dictionary) -> String:
	return var_to_str([entry.get("id", ""), entry.get("transform", []), bool(entry.get("collision", false))])
