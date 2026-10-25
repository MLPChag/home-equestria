extends Node3D
## Persistent, lightweight zone representations. Full streamed zones replace these
## only after staging completes; unloading restores them before detailed nodes leave.
var manager: Node
var _queue: Array[String] = []
var _pending := ""
var _pending_path := ""
var _proxies: Dictionary = {}
var _ready_zones: Dictionary = {}
var missing: Array[String] = []
var stale: Array[String] = []
var _native_refs: Dictionary = {}
var _native_applied: Dictionary = {}
const GRASSY_CATALOGUE := "res://world/foliage/grassy_fields/catalogue_grassy.json"

func bind(value: Node) -> void:
	manager = value
	manager.zone_loaded.connect(_loaded)
	manager.zone_unloaded.connect(_unloaded)
	for id in manager.zone_ids():
		var dir: String = str(manager._defs[id].scene).get_base_dir()
		var path := dir.path_join(id + ".proxy.scn")
		if ResourceLoader.exists(path):
			_queue.append(id)
			var report_path := path.replace(".scn", ".json")
			var report: Variant = JSON.parse_string(FileAccess.get_file_as_string(report_path)) if FileAccess.file_exists(report_path) else null
			var bake := dir.path_join(id + ".baked.scn")
			if _report_stale(report, bake, id): stale.append(id)
		else: missing.append(id)
	if not missing.is_empty(): push_warning("[zones] Missing distant representations: %s. Run tools/bake_zone_proxy.gd -- --all" % [missing])
	if not stale.is_empty(): push_warning("[zones] Rebuild outdated distant representations: %s (tools/bake_zone_proxy.gd). Retaining their last visuals until rebuilt." % [stale])

func _report_stale(report: Variant, bake: String, id := "") -> bool:
	if not report is Dictionary or int(report.get("version", 0)) not in [8, 9]: return true
	if OS.has_feature("editor") and int(report.get("source_bake_mtime", 0)) != FileAccess.get_modified_time(bake): return true
	if FileAccess.file_exists(GRASSY_CATALOGUE) and str(report.get("grassy_catalogue_md5", "")) != FileAccess.get_md5(GRASSY_CATALOGUE): return true
	var replacements: Dictionary = report.get("grassy_tree_counts", {})
	if not replacements.is_empty() and (int(report.get("approved_tree_lod", -1)) != 1 or int(report.get("approved_tree_seating", 0)) != 1): return true
	var native_zone := not id.is_empty() and str(WorldLayout.region_of_zone(id).get("biome", "")) == "dark_forest"
	if native_zone and int(report.get("version", 0)) < 9: return true
	var native_contract := native_zone or int(report.get("native_owner_batches", 0)) > 0
	if native_contract and int(report.get("version", 0)) >= 9 and str(report.get("native_support_md5", "")) != FileAccess.get_md5("res://world/foliage/native_plant_support.gd"): return true
	if native_contract and int(report.get("version", 0)) >= 9 and str(report.get("terrain_revision", "")) != _terrain_revision(): return true
	return false

static func _terrain_revision() -> String:
	var revision := WorldTerrain.data_revision()
	var sculpt_index := "res://world/terrain/sculpt/index.json"
	if FileAccess.file_exists(sculpt_index): revision += ":" + FileAccess.get_md5(sculpt_index)
	return revision

func _process(_delta: float) -> void:
	var profiling := preload("res://tools/crowd_cpu_profile.gd")
	if not profiling.enabled:
		_profiled_process(_delta)
		return
	var started := Time.get_ticks_usec()
	_profiled_process(_delta)
	profiling.record("zone_proxies", started)


func _profiled_process(_delta: float) -> void:
	if not is_instance_valid(manager): return
	if _pending.is_empty():
		if _queue.is_empty(): return
		# Bring the nearest still-missing proxy in first; each request owns its textures.
		if is_instance_valid(manager.anchor):
			var pos: Vector3 = manager.anchor.global_position
			_queue.sort_custom(func(a, b): return manager.distance_to(a, pos) < manager.distance_to(b, pos))
		_pending = _queue.pop_front()
		_pending_path = str(manager._defs[_pending].scene).get_base_dir().path_join(_pending + ".proxy.scn")
		var err := ResourceLoader.load_threaded_request(_pending_path, "PackedScene", false)
		if err != OK:
			missing.append(_pending); push_error("[zones] Cannot load distant " + _pending); _pending = ""
		return
	var state := ResourceLoader.load_threaded_get_status(_pending_path)
	if state == ResourceLoader.THREAD_LOAD_IN_PROGRESS: return
	if state == ResourceLoader.THREAD_LOAD_LOADED:
		var scene := ResourceLoader.load_threaded_get(_pending_path) as PackedScene
		if scene != null:
			var node := scene.instantiate() as Node3D
			if _pending == "canterlot":
				preload("res://world/terrain/canterlot_corridor.gd").apply_proxy(node, _pending_path)
			_restore_grassy_shared_meshes(node)
			preload("res://world/foliage/vegetation_materials.gd").apply(node)
			_index_native_owners(_pending, node)
			var config := ZoneProcessor.load_config(str(manager._defs[_pending].scene).get_base_dir())
			preload("res://world/zone_visual_filter.gd").apply(node, config.get("omit_materials", []))
			node.position = manager._defs[_pending].origin
			node.rotation.y = deg_to_rad(float(manager._defs[_pending].rotation_y))
			node.visible = not _ready_zones.has(_pending)
			add_child(node); _proxies[_pending] = node
			if node.visible and manager._staging.has(_pending): manager._loaded[_pending].hide()
	else:
		missing.append(_pending); push_error("[zones] Failed distant load: " + _pending)
	_pending = ""; _pending_path = ""

func _restore_grassy_shared_meshes(node: Node3D) -> void:
	# MultiMesh serialization embeds its nested Mesh even when that mesh originally
	# came from a shared resource. Replace it immediately after each threaded load;
	# every cell and zone then points at ResourceLoader's one catalogue Mesh.
	for child in node.get_children():
		if not child is MultiMeshInstance3D or not str(child.name).begins_with("ApprovedTrees"): continue
		var source_path := str(child.multimesh.get_meta(&"grassy_source_mesh", ""))
		if source_path.begins_with("res://world/foliage/grassy_fields/shared/"):
			var shared: Mesh = load(source_path)
			if shared != null: child.multimesh.mesh = shared

func _index_native_owners(id: String, node: Node3D) -> void:
	var refs := {}; var applied := {}
	for child in node.get_children():
		if not child is MultiMeshInstance3D or not str(child.name).begins_with("NativeOwners"): continue
		# PackedScene instances otherwise share the mutable transform resource via
		# ResourceLoader cache. Each live zone proxy owns its correction buffer.
		child.multimesh = child.multimesh.duplicate(false)
		var owners: PackedStringArray = child.multimesh.get_meta(&"native_owner_paths", PackedStringArray())
		var offsets: PackedFloat32Array = child.multimesh.get_meta(&"native_baked_offsets", PackedFloat32Array())
		if owners.size() != child.multimesh.instance_count or offsets.size() != owners.size(): continue
		for index in owners.size():
			var owner := str(owners[index])
			if not refs.has(owner): refs[owner] = []
			refs[owner].append([child.multimesh, index])
			applied[owner] = float(offsets[index])
	_native_refs[id] = refs; _native_applied[id] = applied
	if manager != null and manager._native_support.has(id):
		sync_native_corrections(id, manager._native_support[id].corrections, true)

func sync_native_corrections(id: String, corrections: Array, authoritative := false) -> void:
	if not _native_refs.has(id): return
	var refs: Dictionary = _native_refs[id]; var totals := {}
	for correction: Dictionary in corrections:
		var full := str(correction.get("path", "")); var owner := ""
		for candidate: String in refs:
			if full == candidate or full.ends_with("/" + candidate): owner = candidate; break
		if not owner.is_empty(): totals[owner] = float(totals.get(owner, 0.0)) + float(correction.get("delta", 0.0))
	var dirty := {}
	# A sliced sculpt pass reports cumulative corrections for owners it has reached.
	# Preserve baked offsets for every unvisited owner. The initial completed support
	# pass is authoritative and may reset an owner whose current absolute total is zero.
	var owners: Array = refs.keys() if authoritative else totals.keys()
	for owner: String in owners:
		var previous := float((_native_applied[id] as Dictionary).get(owner, 0.0))
		var current := float(totals.get(owner, 0.0))
		var delta := current - previous
		if absf(delta) <= 0.0001: continue
		for pair: Array in refs[owner]:
			var mm: MultiMesh = pair[0]; var index: int = pair[1]
			var transform := mm.get_instance_transform(index); transform.origin.y += delta
			mm.set_instance_transform(index, transform); dirty[mm] = true
		(_native_applied[id] as Dictionary)[owner] = current
	for mm: MultiMesh in dirty:
		var bounds := AABB()
		for index in mm.instance_count:
			var box := mm.get_instance_transform(index) * mm.mesh.get_aabb()
			bounds = box if index == 0 else bounds.merge(box)
		mm.custom_aabb = bounds

func native_ground_changed(bounds: AABB, detailed_ids: Array) -> void:
	# An unloaded proxy has no physics-backed support pass to distinguish terrain
	# from bridges/platforms. Flag only intersecting native batches for rebake
	# instead of moving them from a guessed terrain-only sample.
	for id: String in _proxies:
		if id in detailed_ids: continue
		var proxy: Node3D = _proxies[id]; var affected := false
		for child in proxy.get_children():
			if child is MultiMeshInstance3D and str(child.name).begins_with("NativeOwners") \
					and (proxy.global_transform * child.multimesh.custom_aabb).intersects(bounds):
				affected = true; break
		if affected and id not in stale:
			stale.append(id)
			push_warning("[zones] Native distant grounding for %s is stale after unloaded terrain sculpt; rebuild its proxy." % id)

func _loaded(id: String) -> void:
	_ready_zones[id] = true
	if _proxies.has(id): _proxies[id].hide()
	if manager._loaded.has(id): manager._loaded[id].show()

func _unloaded(id: String) -> void:
	_ready_zones.erase(id)
	if _proxies.has(id): _proxies[id].show()

func ready_for(id: String) -> bool:
	return _proxies.has(id)

func is_busy() -> bool:
	return not _pending.is_empty() or not _queue.is_empty()

func statistics() -> Dictionary:
	var visible := 0; var triangles := 0; var surfaces := 0
	for node in _proxies.values():
		if not node.visible: continue
		visible += 1; triangles += int(node.get_meta("triangles", 0))
		for child in node.get_children():
			if child is MeshInstance3D: surfaces += child.mesh.get_surface_count()
			elif child is MultiMeshInstance3D: surfaces += child.multimesh.mesh.get_surface_count()
	return {"loaded": _proxies.size(), "visible": visible, "base_triangles": triangles, "surfaces": surfaces, "missing": missing, "stale": stale}
