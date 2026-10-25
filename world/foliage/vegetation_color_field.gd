extends Node
## One shared world-space color field, independent of mesh chunks or tree LODs.
## 16 m samples + broad footprints + bilinear filtering; CPU runs only on build/paint.
const SAMPLER := preload("res://world/foliage/terrain_surface_color.gd")
const PACKED_FINGERPRINT := preload("res://world/foliage/vegetation_packed_fingerprint.gd")
const CELL := 16.0
const CACHE := "user://vegetation_color/"
const BAKED := "res://world/foliage/baked/vegetation_color.res"
const BAKED_INFO := "res://world/foliage/baked/vegetation_color.json"
const BAKED_HALF := "res://world/foliage/baked/vegetation_color_half.res"
const BAKED_HALF_INFO := "res://world/foliage/baked/vegetation_color_half.json"
## A whole-continent rebuild is ~989k samples (13 s of work, 7+ minutes at the 30 Hz budget), longer
## than many sessions, so quitting threw it away and every launch paid ~0.2 ms a frame from scratch
## (dev 2026-10-20 perf pass). Finished regions now persist under the same fingerprint and the next
## launch resumes; pixels are identical. false = old behaviour (restart the rebuild every launch).
const RESUME_PARTIAL := true
const PARTIAL_PNG := "user://vegetation_color/partial.png"
const PARTIAL_INFO := "user://vegetation_color/partial.json"
var sampler: RefCounted
var image: Image
var texture: ImageTexture
var origin := Vector2.ZERO
var locations: Array = []
var pending: Dictionary = {}
var upload_pending := false
var upload_clock := 0.0
var cache_key := ""
var cacheable := true
var _build_clock := 0.0
var _dirty: Dictionary = {}
var _refresh_timer: Timer
var _world: WeakRef
var _covered: Dictionary = {}
var _incomplete: Dictionary = {}
var _known: Dictionary = {}
var stats := {"samples":0,"cache_hit":false,"max_slice_us":0}

func bind(world: WorldTerrain) -> void:
	_world = weakref(world)
	sampler = _make_sampler(world)
	locations.assign(world._region_files.keys() if not world._region_files.is_empty() else world.terrain.data.get_region_locations())
	if locations.is_empty():return
	for location: Vector2i in locations: _known[location] = true
	var low: Vector2i=locations[0];var high:=low
	for at: Vector2i in locations:low=low.min(at);high=high.max(at)
	origin=Vector2(low)*1024.0
	var size: Vector2i=(high-low+Vector2i.ONE)*64+Vector2i.ONE
	image=Image.create(size.x,size.y,false,Image.FORMAT_RGBA8);image.fill(Color(0,0,0,0))
	# Door, furniture and navigation edits do not change terrain color.
	var packed := OS.has_feature("template")
	cache_key=PACKED_FINGERPRINT.fingerprint(world.active_data_dir()) if packed else _fingerprint(WorldTerrain.data_revision(world.active_data_dir()))
	if cache_key.is_empty(): cacheable = false
	var path:=CACHE.path_join(cache_key+".png")
	if not cache_key.is_empty() and FileAccess.file_exists(path):
		var cached:=Image.load_from_file(ProjectSettings.globalize_path(path))
		if cached!=null and cached.get_size()==size and cached.get_format()==Image.FORMAT_RGBA8:
			image=cached;stats.cache_hit=true
	var baked_path := BAKED_HALF if world.half_res else BAKED
	var info_path := BAKED_HALF_INFO if world.half_res else BAKED_INFO
	if not stats.cache_hit and FileAccess.file_exists(info_path) and ResourceLoader.exists(baked_path):
		var parser := JSON.new()
		var metadata: Variant = parser.data if parser.parse(FileAccess.get_file_as_string(info_path)) == OK else null
		var signature := "packed_fingerprint" if packed else "fingerprint"
		if not cache_key.is_empty() and metadata is Dictionary and str(metadata.get(signature, "")) == cache_key and _coordinates_match(metadata.get("origin"), origin) and _coordinates_match(metadata.get("size"), Vector2(size)):
			var baked: Resource = load(baked_path)
			if baked is Image and baked.get_size() == size and baked.get_format() == Image.FORMAT_RGBA8:
				image = baked.duplicate(); stats.cache_hit = true
	if not stats.cache_hit:
		var camera:=preload("res://world/player_view.gd").camera(world)
		var center:=Vector2(camera.global_position.x,camera.global_position.z) if camera else WorldLayout.spawn("ponyville")
		locations.sort_custom(func(a,b):return (Vector2(a)*1024-center).length_squared()<(Vector2(b)*1024-center).length_squared())
		_load_partial(size)
		# Queue in the sorted order (nearest first), skipping regions a previous session finished.
		var resident := {}
		for at: Vector2i in world.terrain.data.get_region_locations(): resident[at] = true
		for at: Vector2i in locations:
			if resident.has(at) and not _covered.has(at): pending[at] = 0
	else:
		for at: Vector2i in locations: _covered[at] = true
	texture=ImageTexture.create_from_image(image)
	RenderingServer.global_shader_parameter_set("vegetation_color_map",texture)
	RenderingServer.global_shader_parameter_set("vegetation_color_rect",Vector4(origin.x,origin.y,size.x*CELL,size.y*CELL))
	RenderingServer.global_shader_parameter_set("vegetation_color_enabled",true)
	world.biome_surfaces.controls_changed.connect(invalidate)
	world.regions_loaded.connect(_regions_loaded)
	_refresh_timer = Timer.new(); _refresh_timer.wait_time = 60.0; _refresh_timer.one_shot = true
	add_child(_refresh_timer); _refresh_timer.timeout.connect(_flush_dirty)
	print("[vegetation-color] ","cached" if stats.cache_hit else "building", " ",size," cell=",CELL)
	set_process(not pending.is_empty())

func _make_sampler(world: WorldTerrain) -> RefCounted:
	var source := SAMPLER.new(); source.bind(world.terrain); return source

## Regions an earlier session finished for this exact fingerprint (RESUME_PARTIAL). Anything
## inconsistent (other key, size, edited image, unknown region) is ignored and sampled afresh.
func _load_partial(size: Vector2i) -> void:
	if not RESUME_PARTIAL or cache_key.is_empty() or not FileAccess.file_exists(PARTIAL_INFO) or not FileAccess.file_exists(PARTIAL_PNG): return
	var info: Variant = JSON.parse_string(FileAccess.get_file_as_string(PARTIAL_INFO))
	if not (info is Dictionary) or str(info.get("key", "")) != cache_key: return
	if str(info.get("png_md5", "")) != FileAccess.get_md5(PARTIAL_PNG): return
	var raw: Variant = info.get("covered")
	if not (raw is Array): return
	var done: Array[Vector2i] = []
	for entry: Variant in raw:
		if not (entry is Array) or (entry as Array).size() != 2: return
		var region := Vector2i(int(entry[0]), int(entry[1]))
		if not _known.has(region): return
		done.append(region)
	var saved := Image.load_from_file(ProjectSettings.globalize_path(PARTIAL_PNG))
	if saved == null or saved.get_size() != size or saved.get_format() != Image.FORMAT_RGBA8: return
	image = saved
	for at: Vector2i in done: _covered[at] = true
	print("[vegetation-color] resuming: %d of %d regions already sampled" % [done.size(), locations.size()])

## On exit while a rebuild is unfinished: keep the finished regions for the next launch.
func _save_partial() -> void:
	if not RESUME_PARTIAL or not cacheable or cache_key.is_empty() or image == null or stats.cache_hit: return
	save_cache()  # finished but not yet written (upload still pending at quit): the complete cache
	if not cacheable: return
	var done: Array = []
	for at: Vector2i in _covered:
		if not _incomplete.has(at): done.append([at.x, at.y])
	if done.is_empty(): return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE))
	if image.save_png(ProjectSettings.globalize_path(PARTIAL_PNG)) != OK: return
	var file := FileAccess.open(PARTIAL_INFO, FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify({"key": cache_key, "png_md5": FileAccess.get_md5(PARTIAL_PNG), "covered": done}))

static func _coordinates_match(raw: Variant, expected: Vector2) -> bool:
	if not raw is Array or raw.size() != 2: return false
	for index in 2:
		var value: Variant = raw[index]
		if not (value is int or value is float) or not is_finite(float(value)): return false
		if float(value) != expected[index]: return false
	return true

func _loaded(location: Vector2i) -> bool:
	if _world == null: return true # Existing isolated maintenance fixture.
	var world: WorldTerrain = _world.get_ref()
	return is_instance_valid(world) and world.terrain.data.has_region(location)

func _footprint_loaded(point: Vector2) -> bool:
	for offset: Vector2 in [Vector2.ZERO, Vector2(-8, 0), Vector2(8, 0), Vector2(0, -8), Vector2(0, 8)]:
		var at := point + offset
		var region := Vector2i(floori(at.x / 1024.0), floori(at.y / 1024.0))
		if _known.has(region) and not _loaded(region): return false
	return true

func _regions_loaded(added: Array) -> void:
	for at: Vector2i in added:
		if at not in locations or not _loaded(at): continue
		if _dirty.has(at):
			pending[at] = 0; _dirty.erase(at)
		elif not _covered.has(at): pending[at] = 0
		# A previously sampled edge may have awaited this region's control map.
		for y in range(-1, 2):
			for x in range(-1, 2):
				var neighbor := at + Vector2i(x, y)
				if _incomplete.has(neighbor) and _loaded(neighbor): pending[neighbor] = 0
	if not pending.is_empty(): set_process(true)

static func _fingerprint(revision: String) -> String:
	var keys:=["vegetation-color-v2",revision]
	for path in ["res://world/foliage/terrain_surface_color.gd",
			"res://world/terrain/gaea_material.gd","res://world/terrain/grass_palette.json",WorldTerrain.TEXTURES,
			"res://world/world_layout.json","res://world/terrain/gaea/materials.f32","res://world/terrain/gaea/surfaces.res",
			"res://world/biomes/authored/surface_index.json"]:
		keys.append(FileAccess.get_md5(path) if FileAccess.file_exists(path) else "missing")
	keys.append("gaea-off" if "--gaea-materials-off" in preload("res://world/dev_tools.gd").user_args() else "gaea-on")
	return str(keys).sha256_text()

func invalidate(changed: Array) -> void:
	# Streaming re-applies the published controls after bind accepted the baked map.
	# Both source and packed fingerprints include the publication's surface_index;
	# the offline baker already sampled these controls. Keep ordinary paint/working
	# edits and any previously invalidated field on the normal rebuild path.
	if stats.cache_hit and cacheable and _world != null:
		var world: WorldTerrain = _world.get_ref()
		if is_instance_valid(world) and world.biome_surfaces.restoring_published: return
	cacheable=false
	# Include the sample footprint and bilinear boundary in adjacent regions.
	for at: Vector2i in changed:
		for y in range(-1,2):
			for x in range(-1,2):
				var neighbor:=at+Vector2i(x,y)
				if neighbor in locations: _dirty[neighbor] = true
	if not _dirty.is_empty() and _refresh_timer != null and _refresh_timer.is_stopped(): _refresh_timer.start()

func _flush_dirty() -> void:
	for location: Vector2i in _dirty.keys():
		if _loaded(location): pending[location] = 0; _dirty.erase(location)
	if not pending.is_empty(): set_process(true)

func _process(delta: float) -> void:
	var profiling := preload("res://tools/crowd_cpu_profile.gd")
	if not profiling.enabled:
		_profiled_process(delta)
		return
	var started := Time.get_ticks_usec()
	_profiled_process(delta)
	profiling.record("vegetation_color_field", started)


func _profiled_process(delta: float) -> void:
	# This is background work over the entire continent, not animation. Spending
	# 1ms at every rendered frame made faster machines do proportionally more work.
	# Keep the identical samples/texture, with a bounded 30Hz maintenance budget.
	_build_clock += delta
	if _build_clock >= 1.0 / 30.0:
		_build_clock = fmod(_build_clock, 1.0 / 30.0)
		advance(1000)
	upload_clock+=delta
	if upload_pending and (pending.is_empty() or upload_clock>=.25):
		texture.update(image);upload_pending=false;upload_clock=0
		if pending.is_empty() and cacheable:save_cache()
	if pending.is_empty() and not upload_pending: set_process(false)

func advance(budget_us: int) -> void:
	if pending.is_empty():return
	var start:=Time.get_ticks_usec()
	var loc: Vector2i=pending.keys()[0]
	var checked := loc
	var region_ok := _region_ready(loc)
	while not pending.is_empty():
		if loc != checked:
			checked = loc; region_ok = _region_ready(loc)
		if not region_ok and not _loaded(loc):
			pending.erase(loc)
			if pending.is_empty(): break
			loc = pending.keys()[0]; continue
		var cursor:=int(pending[loc])
		if cursor == 0: _incomplete.erase(loc); _covered.erase(loc)
		# Shared border samples use identical world coordinates. The last row and
		# column also cover the outer edge without clamping to an unrelated biome.
		var local:=Vector2i(cursor%65,cursor/65)
		var point:=Vector2(loc)*1024.0+Vector2(local)*CELL
		var pixel:=Vector2i((point-origin)/CELL)
		if not region_ok and not _footprint_loaded(point):
			_incomplete[loc] = true # Retain existing pixels until their controls are resident.
		else:
			var color: Color=sampler.palette_at(Vector3(point.x,0,point.y)).linear_to_srgb()
			image.set_pixelv(pixel,color);stats.samples+=1;upload_pending=true
		cursor+=1
		if cursor==65*65:
			_covered[loc] = true
			pending.erase(loc)
			if not pending.is_empty(): loc=pending.keys()[0]
		else:pending[loc]=cursor
		if Time.get_ticks_usec()-start>=budget_us:break
	stats.max_slice_us=maxi(stats.max_slice_us,Time.get_ticks_usec()-start)

## Every footprint offset (+-8 m) of a region's samples lands in it or one of its eight
## neighbours; when all of those that exist are resident, the per-sample residency tests always
## pass (residency only changes between slices), so they are skipped. Same pixels, roughly a
## quarter fewer engine calls per sample (dev 2026-10-20 perf pass; false = test every sample).
const REGION_READY_CHECK := true
func _region_ready(loc: Vector2i) -> bool:
	if not REGION_READY_CHECK: return false
	for y in range(-1, 2):
		for x in range(-1, 2):
			var at := loc + Vector2i(x, y)
			if (at == loc or _known.has(at)) and not _loaded(at): return false
	return true

func save_cache() -> void:
	# A terrain window may be idle while most of the continent has never been sampled.
	if not pending.is_empty() or not _dirty.is_empty() or not _incomplete.is_empty() or _covered.size() != locations.size(): return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE))
	var path:=ProjectSettings.globalize_path(CACHE.path_join(cache_key+".png"))
	var temp:=path+".pending.png"
	if image.save_png(temp)==OK:DirAccess.rename_absolute(temp,path)
	cacheable=false

func _exit_tree() -> void:
	_save_partial()
	RenderingServer.global_shader_parameter_set("vegetation_color_enabled",false)
	RenderingServer.global_shader_parameter_set("vegetation_color_map",null)
