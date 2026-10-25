extends Node
## Zone streaming (v2, Phase 3 of the 15 km world).
##
## Equestria is one continuous world: the Terrain3D ground (world/terrain) is always there,
## and the native zones on top of it (buildings, props, trees, mesh mountains) stream in and out
## around the anchor. Every zone in world/zones.json has a world centre and a radius (from
## world/world_layout.json via tools/world_layout.py --write-zones); the streaming distance
## is the distance to the *edge* of that disc, so a big zone loads as early as a small one.
## At most `max_resident` zones are loaded; the load queue is sorted by distance and only one
## scene is in flight at a time. A closer zone can evict the farthest resident.
##
## Baked scenes: tools/bake_zone.gd runs the ZoneProcessor once and saves
## world/zones/<id>/<id>.baked.scn (+ .baked.json with the inputs' hashes). When it is fresh
## the manager loads it threaded and only add_child()s; otherwise it processes the raw GLB
## scene live and warns, which stalls the main thread for a second or more per zone.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")

signal zone_loaded(id: String)
signal zone_unloaded(id: String)
signal zone_load_failed(id: String, err: int)

## Preloaded rather than referenced by class_name: autoloads are resolved before
## the global script class cache is necessarily populated in headless runs.
const ZONE_PROCESSOR := preload("res://world/zone_processor.gd")
const TERRAIN_BUILDER := preload("res://world/terrain_builder.gd")
const NAVMESH_BAKER := preload("res://world/navigation/walk_grid_service.gd")
const WORLD_TERRAIN := preload("res://world/terrain/world_terrain.gd")
const WORLD_WATER := preload("res://world/water/world_water.gd")
const PLANT_SUPPORT := preload("res://world/foliage/native_plant_support.gd")
const NORMAL_TREES := preload("res://world/foliage/normal_tree_replacements.gd")

const REGISTRY_PATH := "res://world/zones.json"
## Re-evaluating every frame is pointless when zones are hundreds of metres wide.
const EVAL_INTERVAL := 0.5
## Bump when the bake output format or ZoneProcessor semantics change: stale bakes are ignored.
const BAKE_VERSION := 2
## Default residency budget; `--max-resident N` overrides (VRAM: Ponyville alone is 2.2 GB).
const MAX_RESIDENT_DEFAULT := 3
## A queued zone evicts the farthest resident only when it is this much closer (metres past
## the edge), so two zones straddling the anchor do not swap every evaluation.
const EVICT_MARGIN := 150.0
## Main-thread time per frame spent attaching a zone's physics bodies (Jolt cooks every
## trimesh on enter-tree: 1-3 s per zone in one go, single big meshes up to ~45 ms).
## Distant models remain visible during staging, so detail can arrive in smaller
## slices. Loading and unloading each spend at most this budget per frame, apart
## from an indivisible scene part or physics-body cook.
const STAGE_BUDGET_MS := 2.0

var container: Node3D
var anchor: Node3D
var max_resident := MAX_RESIDENT_DEFAULT
## Zones loaded live (not from a bake) this session, for the streaming test and the HUD.
var live_processed: Array[String] = []

var _defs: Dictionary = {}        # id -> Dictionary
var _loaded: Dictionary = {}      # id -> Node3D
var _pending: Dictionary = {}     # id -> [paths] currently in flight (root first)
var _pending_baked: Dictionary = {}  # id -> bake meta (parts...) or {} for a raw scene
var _queue: Array[String] = []    # wanted, not loaded, nearest first
var _staging: Dictionary = {}     # id -> {content, cfg, bodies: [[parent, body]...], next, t0}
var _unloading: Array = []        # [{root, bodies: [...], next}] freed a few ms per frame
var _native_support: Dictionary = {} # loaded zone -> retained contact records for sculpt edits
var _eval_accum := 0.0
var _priority_zone := "" # Explicit destination while map travel waits for collision.
var proxies: Node3D
var _resident_override := false
var _configured_resident := 3
## Optional CPU phase timings for diagnosing stalls separately from GPU presentation.
var profile_streaming := false
var streaming_timings: Dictionary = {}


func _ready() -> void:
	set_process(false)
	var args := preload("res://world/dev_tools.gd").user_args()
	var at := args.find("--max-resident")
	if at >= 0 and at + 1 < args.size():
		max_resident = maxi(1, int(args[at + 1]))
		_resident_override = true
	_configured_resident = max_resident


func setup(zone_container: Node3D, streaming_anchor: Node3D) -> void:
	container = zone_container
	anchor = streaming_anchor
	# The world ground (Terrain3D) sits beside the zones; zones only add what the
	# heightmap cannot: buildings, props, trees, water, and mesh-terrain mountains.
	WORLD_TERRAIN.ensure(zone_container)
	var sculptor:=WORLD_TERRAIN.instance.get_node_or_null("TerrainSculptor")
	if sculptor!=null and sculptor.has_signal("height_changed") and not sculptor.height_changed.is_connected(_native_height_changed):sculptor.height_changed.connect(_native_height_changed)
	if WORLD_TERRAIN.has_data():
		WORLD_WATER.ensure(zone_container)
	_load_registry()
	var quality := get_node_or_null("/root/Quality")
	if quality != null and not quality.preset_changed.is_connected(_apply_resident_budget):
		quality.preset_changed.connect(_apply_resident_budget)
	_apply_resident_budget()
	if proxies == null and not ("--zone-proxies-off" in preload("res://world/dev_tools.gd").user_args()):
		proxies = preload("res://world/zone_proxies.gd").new()
		proxies.name = "DistantZones"; container.add_child(proxies); proxies.bind(self)
	_evaluate()
	set_process(true)


func _apply_resident_budget(_preset := 0) -> void:
	if _resident_override: return
	var quality := get_node_or_null("/root/Quality")
	if quality != null:
		max_resident = maxi(1, int(quality.get_value("zone_resident_budget", _configured_resident)))


func set_anchor(streaming_anchor: Node3D) -> void:
	anchor = streaming_anchor


func prioritize_zone(id: String) -> void:
	_priority_zone = id if _defs.has(id) else ""
	_eval_accum = EVAL_INTERVAL


## Overlapping discs otherwise tie at zero, leaving the older region resident forever.
func _containing_priority(pos: Vector3) -> String:
	var best := ""
	var score := INF
	for id in _defs:
		var def: Dictionary = _defs[id]
		if distance_to(id, pos) > 0.0: continue
		if bool(def.get("flight_only", false)) and pos.y < (def.get("origin", Vector3.ZERO) as Vector3).y - 100.0: continue
		var d := Vector2(pos.x,pos.z).distance_to(def.center) / maxf(1.0,float(def.radius))
		if d < score: best = id; score = d
	return best


func _process(delta: float) -> void:
	var started := Time.get_ticks_usec() if profile_streaming else 0
	_poll_pending()
	started = _record_streaming("loaded_scene_instantiation", started)
	_advance_staging()
	_advance_native_rechecks()
	started = _record_streaming("attach_parts_and_collision", started)
	_advance_unloading()
	started = _record_streaming("release_old_zone", started)
	_eval_accum += delta
	if _eval_accum < EVAL_INTERVAL:
		return
	_eval_accum = 0.0
	_evaluate()
	_record_streaming("evaluate_residency", started)


func _record_streaming(phase: String, started: int) -> int:
	if not profile_streaming: return 0
	var now := Time.get_ticks_usec()
	var elapsed := (now - started) / 1000.0
	var row: Dictionary = streaming_timings.get(phase, {"calls": 0, "total_ms": 0.0, "max_ms": 0.0})
	row.calls += 1; row.total_ms += elapsed; row.max_ms = maxf(row.max_ms, elapsed)
	streaming_timings[phase] = row
	return now


func _native_height_changed(bounds:AABB)->void:
	if not bounds.position.is_finite() or not bounds.size.is_finite():return
	for support_pass in _native_support.values():support_pass.queue_bounds(bounds)
	if proxies!=null:proxies.native_ground_changed(bounds,_native_support.keys())


func _advance_native_rechecks()->void:
	if _native_support.is_empty() or not is_instance_valid(container):return
	for support_id in _native_support:
		var support_pass: RefCounted = _native_support[support_id]
		if support_pass.pending()>0:
			var space:=container.get_world_3d().direct_space_state
			if support_pass.advance(space,WORLD_TERRAIN.instance,1000):
				var changed:AABB=support_pass.take_changed_bounds()
				if changed.size!=Vector3.ZERO:
					for service in get_tree().get_nodes_in_group("pony_navigation"):service.notify_geometry_changed(changed)
					var foliage:=WORLD_TERRAIN.instance.get_node_or_null("BiomeFoliage")
					if foliage!=null and foliage.has_method("native_support_changed"):foliage.native_support_changed(changed)
				if proxies!=null:proxies.sync_native_corrections(str(support_id),support_pass.corrections)
			return


func _load_registry() -> void:
	_defs.clear()
	if not FileAccess.file_exists(REGISTRY_PATH):
		push_warning("[zones] no registry at %s" % REGISTRY_PATH)
		return
	var text := FileAccess.get_file_as_string(REGISTRY_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("zones"):
		push_error("[zones] registry malformed")
		return
	for entry in parsed["zones"]:
		var origin := _to_vec3(entry.get("origin", [0, 0, 0]))
		var center := Vector2(origin.x, origin.z)
		if entry.has("center"):
			var c: Array = entry["center"]
			if c.size() >= 2:
				center = Vector2(float(c[0]), float(c[1]))
		var radius := float(entry.get("radius", 400.0))
		var def := {
			"id": entry.get("id", ""),
			"scene": entry.get("scene", ""),
			"origin": origin,
			"rotation_y": float(entry.get("rotation_y", 0.0)),
			"center": center,
			"radius": radius,
			"load_radius": float(entry.get("load_radius", radius + 600.0)),
			# Hysteresis band -- without it a player standing on the boundary
			# thrashes load/unload every evaluation tick.
			"unload_radius": float(entry.get("unload_radius", 0.0)),
			"always_loaded": bool(entry.get("always_loaded", false)),
			"flight_only": bool(entry.get("flight_only", false)),
		}
		if def["unload_radius"] <= float(def["load_radius"]):
			def["unload_radius"] = float(def["load_radius"]) + 400.0
		if def["id"] == "":
			continue
		_defs[def["id"]] = def


## Streaming distance: metres from the anchor to the edge of the zone's disc (0 inside).
func distance_to(id: String, pos: Vector3) -> float:
	var def: Dictionary = _defs[id]
	return maxf(0.0, Vector2(pos.x, pos.z).distance_to(def["center"] as Vector2) - float(def["radius"]))


func _anchor_position() -> Vector3:
	return anchor.global_position if is_instance_valid(anchor) else Vector3.ZERO


## One streaming decision: unload what left its band, queue what entered it, and start at
## most one load (evicting the farthest resident when the budget is full and the newcomer is
## clearly closer). Returns true when a load was started.
func _evaluate() -> bool:
	if container == null:
		return false
	var pos := _anchor_position()
	var priority := _priority_zone if _defs.has(_priority_zone) else _containing_priority(pos)
	# A quality change can lower the budget while all current zones are in-band.
	while _loaded.size() > max_resident:
		var candidates: Array = _loaded.keys().filter(func(id): return not _defs[id].always_loaded)
		if candidates.is_empty(): break
		candidates.sort_custom(func(a, b):
			if a == priority or b == priority: return a != priority and b == priority
			return distance_to(a, pos) > distance_to(b, pos))
		unload(candidates[0])
	for id in _loaded.keys():
		var def: Dictionary = _defs.get(id, {})
		if def.is_empty():
			continue
		if id != priority and not def["always_loaded"] and distance_to(id, pos) > float(def["unload_radius"]):
			unload(id)
	var wanted: Array = []
	for id in _defs:
		var def: Dictionary = _defs[id]
		var d := distance_to(id, pos)
		if id == priority or def["always_loaded"] or d <= float(def["load_radius"]):
			wanted.append([d, id])
	wanted.sort_custom(func(a, b):
		if a[1] == priority or b[1] == priority: return a[1] == priority and b[1] != priority
		return a[0] < b[0])
	_queue.clear()
	for w in wanted:
		var id: String = w[1]
		if not _loaded.has(id) and not _pending.has(id):
			_queue.append(id)
	if _queue.is_empty() or not _pending.is_empty() or not _staging.is_empty():
		return false
	var next: String = _queue[0]
	if _loaded.size() >= max_resident:
		var farthest := ""
		var farthest_d := -1.0
		for id in _loaded:
			if id == priority or _defs[id]["always_loaded"]:
				continue
			var d := distance_to(id, pos)
			if d > farthest_d:
				farthest_d = d
				farthest = id
		if farthest == "" or (next != priority and farthest_d < distance_to(next, pos) + EVICT_MARGIN):
			return false
		unload(farthest)
	# Unloading roots still own their GPU resources even after leaving _loaded.
	# Do not overlap a new full-zone load with that deferred release: the nominal
	# two-zone budget otherwise briefly retains three or four zones and can OOM.
	if not _unloading.is_empty(): return false
	_begin_load(next, _defs[next])
	return true


## Path of a fresh bake for this zone, or "" when it is missing or stale.
func baked_scene_path(id: String) -> String:
	return str(bake_meta(id).get("scene", ""))


## The fresh bake's meta ({scene, parts, ...}) for this zone, or {} when missing or stale
## (wrong version, edited zone.json/processor, re-exported GLB, missing part file).
func bake_meta(id: String) -> Dictionary:
	var def: Dictionary = _defs.get(id, {})
	if def.is_empty():
		return {}
	var scene: String = def["scene"]
	var dir := scene.get_base_dir()
	var baked := dir.path_join("%s.baked.scn" % id)
	var meta_path := dir.path_join("%s.baked.json" % id)
	if not ResourceLoader.exists(baked) or not FileAccess.file_exists(meta_path):
		return {}
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	if typeof(meta) != TYPE_DICTIONARY:
		return {}
	if int(meta.get("bake_version", 0)) != BAKE_VERSION:
		return {}
	if str(meta.get("zone_json_md5", "")) != bake_input_md5(dir):
		return {}
	# Exported PCK entries have no source filesystem modification time.
	if OS.has_feature("editor") and int(meta.get("glb_mtime", 0)) != int(FileAccess.get_modified_time(scene)):
		return {}
	for part in meta.get("parts", []):
		if not ResourceLoader.exists(str(part.get("scene", ""))):
			return {}
	meta["scene"] = baked
	return meta


## Identity of the bake inputs besides the GLB itself: zone.json and the processor script.
static func bake_input_md5(zone_dir: String) -> String:
	var zone_json := zone_dir.path_join("zone.json")
	var a := FileAccess.get_md5(zone_json) if FileAccess.file_exists(zone_json) else "-"
	var b := FileAccess.get_md5("res://world/zone_processor.gd")
	# Processor delegates offline geometry/material changes; helper edits invalidate bakes too.
	for helper in ["res://world/foliage/vegetation_scale.gd", "res://world/terrain/mountain_materials.gd", "res://world/terrain/terrain_ownership.gd"]:
		b += ":" + FileAccess.get_md5(helper)
	if zone_dir.ends_with("/canterlot"):
		b += ":" + FileAccess.get_md5("res://world/terrain/canterlot_corridor.gd") + ":" + FileAccess.get_md5("res://world/terrain/canterlot_corridor.json")
	return a + ":" + b


func _begin_load(id: String, def: Dictionary) -> void:
	var path: String = def["scene"]
	if not ResourceLoader.exists(path):
		push_error("[zones] missing scene for '%s': %s" % [id, path])
		zone_load_failed.emit(id, ERR_FILE_NOT_FOUND)
		_defs.erase(id)
		return
	var meta := bake_meta(id)
	# One request: a bake's parts and shared meshes are external dependencies of its root.
	var paths: Array = [path if meta.is_empty() else meta["scene"]]
	for p in paths:
		ResourceLoader.load_threaded_request(p)
	_pending[id] = paths
	_pending_baked[id] = meta


func _poll_pending() -> void:
	if _pending.is_empty():
		return
	for id in _pending.keys():
		var paths: Array = _pending[id]
		var failed := false
		var done := true
		for path in paths:
			match ResourceLoader.load_threaded_get_status(path):
				ResourceLoader.THREAD_LOAD_IN_PROGRESS:
					done = false
				ResourceLoader.THREAD_LOAD_LOADED:
					pass
				_:
					failed = true
		if not done and not failed:
			continue
		var meta: Dictionary = _pending_baked.get(id, {})
		_pending.erase(id)
		_pending_baked.erase(id)
		if failed:
			push_error("[zones] load failed for '%s'" % id)
			zone_load_failed.emit(id, ERR_CANT_OPEN)
			continue
		var packed: Array = []
		for path in paths:
			packed.append(ResourceLoader.load_threaded_get(path))
		_instantiate(id, packed, meta)


## `packed` is [root scene] -- a bake carries its parts in the root's "baked_parts" meta.
func _instantiate(id: String, packed: Array, meta: Dictionary) -> void:
	if packed.is_empty() or packed[0] == null or _loaded.has(id):
		return
	var def: Dictionary = _defs[id]
	var root := Node3D.new()
	root.name = "Zone_%s" % id
	root.position = def["origin"]
	root.rotation.y = deg_to_rad(float(def["rotation_y"]))

	var t0 := Time.get_ticks_msec()
	var content: Node = (packed[0] as PackedScene).instantiate()
	var dir := str(def["scene"]).get_base_dir()
	var cfg: Dictionary = ZONE_PROCESSOR.load_config(dir)
	var parts: Array = []
	if not meta.is_empty():
		var scenes: Array = content.get_meta("baked_parts", [])
		var parents: PackedStringArray = content.get_meta("baked_part_parents", PackedStringArray())
		for i in mini(scenes.size(), parents.size()):
			parts.append({"packed": scenes[i], "parent": parents[i]})
		content.remove_meta("baked_parts")
		content.remove_meta("baked_part_parents")
	elif not cfg.is_empty():
		# Raw native zone exports are not directly usable -- see world/zone_processor.gd.
		push_warning("[zones] '%s' has no fresh bake; processing live (tools/bake_zone.gd %s)" % [id, id])
		live_processed.append(id)
		var stats: Dictionary = process_content(content, dir, cfg)
		print("[zones] '%s' processed in %d ms: %s" % [id, Time.get_ticks_msec() - t0, stats])
	# Structure now; parts and then physics over the next frames (see _advance_staging).
	var bodies: Array = []
	container.add_child(root)
	_loaded[id] = root
	if is_instance_valid(proxies) and proxies.ready_for(id): root.hide()
	_staging[id] = {"content": content, "cfg": cfg, "parts": parts, "part": 0,
			"bodies": bodies, "next": 0, "t0": t0, "part_ms": 0, "nav": {"hashes": []},
			"tree_job": NORMAL_TREES.begin(content, root.global_transform, true, id),
			"tree_node": content, "tree_parent": root, "tree_counts": {}}
	_advance_staging()


func _detach_bodies(content: Node) -> Array:
	preload("res://world/native_material_modes.gd").apply(content)
	var bodies: Array = []
	for body in content.find_children("*", "StaticBody3D", true, false):
		# Legacy prefix matching also lit lamp collider names; these duplicate the
		# parent fixture and otherwise return when staged physics enters the tree.
		for child in body.get_children():
			if child is OmniLight3D and child.has_meta("night_energy"):
				body.remove_child(child)
				child.free()
		bodies.append([body.get_parent(), body])
		body.get_parent().remove_child(body)
		body.owner = null  # re-adding an owned node warns; the bake's ownership is spent
	return bodies


## Instantiate the zone's parts, then attach the detached physics bodies, STAGE_BUDGET_MS
## per frame; then build the walk grid service (its geometry hash needs every collider) and
## announce the zone. The zone is `is_loaded` from the first frame.
func _advance_staging() -> void:
	if _staging.is_empty():
		return
	var id: String = _staging.keys()[0]
	var st: Dictionary = _staging[id]
	var content: Node = st["content"]
	var parts: Array = st["parts"]
	var bodies: Array = st["bodies"]
	var start := Time.get_ticks_usec()
	while st.has("tree_job") or st["part"] < parts.size():
		if st.has("tree_job"):
			var job: RefCounted = st.tree_job
			if not job.advance(1000): return
			var ready_node: Node = st.tree_node
			var water_prefix := "" if ready_node == content else str(content.get_path_to(st.tree_parent))
			preload("res://world/water/water_contact.gd").prepare_native(ready_node, st.cfg.get("toon_water", []), water_prefix)
			bodies.append_array(_detach_bodies(ready_node))
			bodies.append_array(job.bodies)
			for variant in job.counts:
				st.tree_counts[variant] = int(st.tree_counts.get(variant, 0)) + int(job.counts[variant])
			if st.tree_parent != null: st.tree_parent.add_child(ready_node)
			preload("res://world/street_lamps.gd").prepare(ready_node)
			st.erase("tree_job"); st.erase("tree_node"); st.erase("tree_parent")
			if float(Time.get_ticks_usec() - start) / 1000.0 >= STAGE_BUDGET_MS: return
			if st["part"] >= parts.size(): break
		var part: Dictionary = parts[st["part"]]
		st["part"] += 1
		var parent: Node = content.get_node_or_null(NodePath(part["parent"]))
		if parent == null or part["packed"] == null:
			push_error("[zones] '%s': part parent '%s' missing" % [id, part["parent"]])
			continue
		var node: Node = (part["packed"] as PackedScene).instantiate()
		st.tree_job = NORMAL_TREES.begin(node, (parent as Node3D).global_transform, true, id)
		st.tree_node = node; st.tree_parent = parent
		if float(Time.get_ticks_usec() - start) / 1000.0 >= STAGE_BUDGET_MS:
			return
	if st["part_ms"] == 0 and not parts.is_empty():
		st["part_ms"] = Time.get_ticks_msec() - int(st["t0"])
	while st["next"] < bodies.size():
		var pair: Array = bodies[st["next"]]
		st["next"] += 1
		if is_instance_valid(pair[0]):
			(pair[0] as Node).add_child(pair[1])

		else:
			(pair[1] as Node).free()
		if float(Time.get_ticks_usec() - start) / 1000.0 >= STAGE_BUDGET_MS:
			return
	# Reconcile vegetation against final world ground after physics attachment,
	# before registering navigation or showing detailed geometry. Work stays sliced.
	if not st.has("plant_support"):
		var zone_root:Node3D=_loaded[id];var zone_dir:=str(_defs[id].scene).get_base_dir()
		st["plant_support"] = PLANT_SUPPORT.begin(content,st.cfg,zone_root.global_position,zone_dir)
		st["support_frame"] = Engine.get_physics_frames()
		return
	if Engine.get_physics_frames() <= int(st["support_frame"]): return
	if not st["plant_support"].advance(container.get_world_3d().direct_space_state, WORLD_TERRAIN.instance, 1000): return
	# Grounding moves collision children too. Hash their FINAL transforms so old
	# walk-grid caches can never route through a newly grounded trunk.
	var support_pass: RefCounted = st["plant_support"]
	if not st.has("signature_next"):
		st["signature_next"] = 0
		if not support_pass.corrections.is_empty():
			print("[plant-support] ", id, " corrected=", support_pass.corrections.size(), " visited=", support_pass.visited)
			content.set_meta("plant_support_corrections", support_pass.corrections)
	while st["signature_next"] < bodies.size():
		var pair: Array = bodies[st["signature_next"]]
		st["signature_next"] += 1
		if not is_instance_valid(pair[1]): continue
		var nav: Dictionary = st["nav"]
		for col in (pair[1] as Node).get_children():
			if not col is CollisionShape3D: continue
			var sig: Array = NAVMESH_BAKER.collider_signature(col)
			if sig.is_empty(): continue
			nav["bounds"] = (nav["bounds"] as AABB).merge(sig[0]) if nav.has("bounds") else sig[0]
			(nav["hashes"] as Array).append(sig[1])
		if float(Time.get_ticks_usec() - start) / 1000.0 >= STAGE_BUDGET_MS: return
	_staging.erase(id)
	if not st.tree_counts.is_empty():
		content.set_meta("grassy_tree_counts", st.tree_counts)
		print("[grassy-trees] ", id, " ", st.tree_counts)
	support_pass.take_changed_bounds() # Initial moves are covered by the nav bake below.
	_native_support[id]=support_pass
	if proxies!=null:proxies.sync_native_corrections(id,support_pass.corrections,true)
	var cfg: Dictionary = st["cfg"]
	var nav_ms := 0
	if not cfg.is_empty():
		# The walk grid is threaded and cached; it never goes into the bake.
		var t := Time.get_ticks_msec()
		NAVMESH_BAKER.bake(content, cfg, st["nav"])
		nav_ms = Time.get_ticks_msec() - t
	print("[zones] '%s' in tree: %d parts by %d ms, %d bodies by %d ms, walk grid service %d ms" % [
		id, parts.size(), int(st["part_ms"]), bodies.size(), Time.get_ticks_msec() - int(st["t0"]), nav_ms])
	zone_loaded.emit(id)


## True while a zone is loading or attaching its physics bodies.
func is_busy() -> bool:
	return not _pending.is_empty() or not _staging.is_empty() or not _unloading.is_empty()


## Everything tools/bake_zone.gd stores: prune/collide/look rules plus mesh-mode terrain.
func process_content(content: Node, dir: String, cfg: Dictionary) -> Dictionary:
	if cfg.get("lower_ponyville_corridor", false):
		preload("res://world/terrain/canterlot_corridor.gd").apply(content)
	var stats: Dictionary = ZONE_PROCESSOR.process(content, cfg)
	_build_terrain(content, dir, cfg)
	return stats


## Ground is rebuilt from extracted Unity heightmaps rather than coming from the
## zone GLB -- Unity Terrain is a component, not mesh geometry. See TECH.md.
func _build_terrain(content: Node, dir_path: String, cfg: Dictionary) -> void:
	for entry in cfg.get("terrain", []):
		if str(entry.get("mode", "mesh")) == "terrain3d" and WORLD_TERRAIN.has_data():
			continue  # this heightmap lives in the world Terrain3D (tools/import_world_terrain.gd)
		var t0 := Time.get_ticks_msec()
		var meta_path := dir_path.path_join(str(entry.get("meta", "")))
		var meta: Dictionary = TERRAIN_BUILDER.load_meta(meta_path)
		if meta.is_empty():
			continue
		var mi: MeshInstance3D = TERRAIN_BUILDER.build(dir_path, meta, entry)
		if mi == null:
			continue
		content.add_child(mi)
		print("[zones]   terrain '%s' built in %d ms" % [
			meta.get("name", "?"), Time.get_ticks_msec() - t0])


func unload(id: String) -> void:
	if not _loaded.has(id):
		return
	if _staging.has(id):
		var st: Dictionary = _staging[id]
		if st.has("tree_job"):
			for pair in st.tree_job.bodies:
				if is_instance_valid(pair[1]): pair[1].free()
			if is_instance_valid(st.tree_node) and not st.tree_node.is_inside_tree(): st.tree_node.free()
		for i in range(int(st["next"]), (st["bodies"] as Array).size()):
			if is_instance_valid(st["bodies"][i][1]): (st["bodies"][i][1] as Node).free()
		_staging.erase(id)
	_native_support.erase(id)
	var node: Node3D = _loaded[id]
	# A complete far representation is visible before detailed geometry is released.
	if is_instance_valid(proxies): proxies._unloaded(id)
	node.hide()
	_loaded.erase(id)
	# Freeing a zone in one go costs up to ~120 ms (Jolt body removal dominates): the bodies
	# go first, a few ms per frame, then the rest of the tree.
	var bodies: Array = node.find_children("*", "StaticBody3D", true, false)
	var services: Array = []
	for service in get_tree().get_nodes_in_group("pony_navigation"):
		if node.is_ancestor_of(service):
			services.append(service)
	_unloading.append({"root": node, "bodies": bodies, "next": 0, "services": services})
	zone_unloaded.emit(id)


## The world scene is leaving (quit to title, or a saved game reloading the scene): its
## zone nodes are freed with it. Forget them, free what staging held outside the tree,
## drain in-flight loads, and stop until the next setup().
func reset() -> void:
	set_process(false)
	for id in _staging:
		var st: Dictionary = _staging[id]
		if st.has("tree_job"):
			for pair in st.tree_job.bodies:
				if is_instance_valid(pair[1]) and not (pair[1] as Node).is_inside_tree(): (pair[1] as Node).free()
			if is_instance_valid(st.tree_node) and not (st.tree_node as Node).is_inside_tree(): (st.tree_node as Node).free()
		for i in range(int(st["next"]) if st.has("next") else 0, (st["bodies"] as Array).size()):
			var body: Variant = st["bodies"][i][1]
			if is_instance_valid(body) and not (body as Node).is_inside_tree(): (body as Node).free()
	for id in _pending:
		for path in _pending[id]:
			if ResourceLoader.load_threaded_get_status(path) in [ResourceLoader.THREAD_LOAD_IN_PROGRESS, ResourceLoader.THREAD_LOAD_LOADED]:
				ResourceLoader.load_threaded_get(path)
	_loaded.clear(); _pending.clear(); _pending_baked.clear(); _queue.clear()
	_staging.clear(); _unloading.clear(); _native_support.clear()
	_priority_zone = ""; _eval_accum = 0.0
	container = null; anchor = null; proxies = null


func _advance_unloading() -> void:
	if _unloading.is_empty():
		return
	var st: Dictionary = _unloading[0]
	var bodies: Array = st["bodies"]
	var start := Time.get_ticks_usec()
	while st["next"] < bodies.size():
		var body: Node = bodies[st["next"]]
		st["next"] += 1
		if is_instance_valid(body):
			body.get_parent().remove_child(body)
			body.free()
		if float(Time.get_ticks_usec() - start) / 1000.0 >= STAGE_BUDGET_MS:
			return
	# The walk grid service must not join a running worker inside _exit_tree.
	for service in st["services"]:
		if is_instance_valid(service) and not service.release():
			return
	# Then free the nodes a few ms per frame, leaves first (each leaves the tree as it goes:
	# removing a 17k-node root in one call costs ~40 ms).
	if not st.has("order"):
		var order: Array = []
		if is_instance_valid(st["root"]):
			_postorder(st["root"], order)
		st["order"] = order
	var order: Array = st["order"]
	while not order.is_empty():
		var n: Node = order.pop_back()
		if is_instance_valid(n):
			n.free()
		if float(Time.get_ticks_usec() - start) / 1000.0 >= STAGE_BUDGET_MS:
			return
	_unloading.pop_front()


func _postorder(n: Node, out: Array) -> void:
	out.append(n)  # popped from the back: children (appended later) go first
	for c in n.get_children():
		_postorder(c, out)


func is_loaded(id: String) -> bool:
	return _loaded.has(id)


## Loaded roots exist before their meshes and collision finish attaching.
func is_ready(id: String) -> bool:
	return _loaded.has(id) and not _staging.has(id) and not _pending.has(id)


func loaded_ids() -> Array:
	return _loaded.keys()


func zone_ids() -> Array:
	return _defs.keys()


func zone_origin(id: String) -> Vector3:
	return _defs[id]["origin"] if _defs.has(id) else Vector3.ZERO


## World XZ disc of a zone: (centre.x, centre.z, radius).
func zone_bounds(id: String) -> Vector3:
	if not _defs.has(id):
		return Vector3.ZERO
	var def: Dictionary = _defs[id]
	return Vector3((def["center"] as Vector2).x, (def["center"] as Vector2).y, float(def["radius"]))


## The zone whose disc contains `pos` (smallest radius wins), or "".
func zone_contains(pos: Vector3, include_flight := false) -> String:
	var best := ""
	var best_r := INF
	for id in _defs:
		var def: Dictionary = _defs[id]
		if def["flight_only"] and not include_flight:
			continue
		if distance_to(id, pos) <= 0.0 and float(def["radius"]) < best_r:
			best_r = float(def["radius"])
			best = id
	return best


## The zone whose disc edge is nearest to `pos` (walkable zones only), or "".
func nearest_zone(pos: Vector3) -> String:
	var best := ""
	var best_d := INF
	for id in _defs:
		if _defs[id]["flight_only"]:
			continue
		var d := distance_to(id, pos)
		if d < best_d:
			best_d = d
			best = id
	return best


## Ids of the zones whose discs overlap the XZ box (min.x, min.z, max.x, max.z).
func zones_overlapping(box: Rect2) -> Array[String]:
	var out: Array[String] = []
	for id in _defs:
		var def: Dictionary = _defs[id]
		var c: Vector2 = def["center"]
		var r := float(def["radius"])
		var nearest := Vector2(clampf(c.x, box.position.x, box.end.x), clampf(c.y, box.position.y, box.end.y))
		if nearest.distance_to(c) <= r:
			out.append(id)
	return out


## Blocks until the streaming queue is drained: every zone inside the load band that the
## residency budget allows is loaded. Only for capture harnesses and tests -- screenshots
## must never catch a half-streamed world.
func wait_until_idle() -> void:
	while true:
		_poll_pending()
		_advance_staging()
		_advance_unloading()
		if not is_busy():
			var started := _evaluate()
			# Evaluation can start an eviction without starting its replacement load.
			if not started and not is_busy():
				break
		if not await SHUTDOWN.frame(self): return


func wait_for_navigation() -> void:
	await wait_until_idle()
	for service in get_tree().get_nodes_in_group("pony_navigation"):
		while is_instance_valid(service) and (service.baking or service._dirty):
			if not await SHUTDOWN.frame(self): return


func get_zone_navigation(id: String) -> Node3D:
	if not _loaded.has(id):
		return null
	return _loaded[id].find_child("Navigation", true, false) as Node3D


func _to_vec3(a: Variant) -> Vector3:
	if typeof(a) == TYPE_ARRAY and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO
