class_name WorldBiomeField
extends RefCounted
## World +X/+Z, 4 metre cells. Four RGBA8 images hold thirteen normalized weights.
## Generated baseline is disposable; immutable save generations + atomic index protect edits.
signal changed(bounds: Rect2, revision: int)

const CELL := 4.0
const REGION := 1024
const SIZE := 256
const COUNT := 13
const MAX_VEGETATION_DENSITY := 8.0
const GENERATED := "res://world/biomes/generated"
const AUTHORED := "res://world/biomes/authored"
const WORKING := "user://world_editor/biomes"
const PRESETS := "res://world/biomes/presets.json"
const TILE_CACHE := 32
var presets: Array = []
var revision := 0
var working := false
var published_dir := AUTHORED
var working_dir := WORKING
var _tiles: Dictionary = {}
var _order: Array[Vector2i] = []
var _dirty: Dictionary = {}
var _published: Dictionary = {}
var _working: Dictionary = {}
var _mask: Image
var _palette: Dictionary = {}


func _init() -> void:
	presets = read_json(PRESETS).get("biomes", [])
	_published = index_at(AUTHORED).get("tiles", {})
	_working = index_at(WORKING).get("tiles", {})
	_mask = preload("res://world/resource_image.gd").read("res://world/terrain/src/biome_mask.png")
	for p in presets:
		_palette[Color(p.color).to_rgba32()] = int(p.id)


static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if data is Dictionary else {}


static func index_at(folder: String, surface := false) -> Dictionary:
	var bundle := read_json(folder.path_join("bundle.json"))
	if not bundle.is_empty(): return bundle.get("surface" if surface else "biomes", {})
	return read_json(folder.path_join("surface_index.json" if surface else "index.json"))


static func key(location: Vector2i) -> String:
	return "%d_%d" % [location.x, location.y]


static func location(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / REGION), floori(pos.y / REGION))


func _seed(pos: Vector2) -> PackedFloat32Array:
	var out := PackedFloat32Array(); out.resize(COUNT)
	var pixel := WorldLayout.world_to_canon(pos)
	var id := 0
	if _mask != null and pixel.x >= 0 and pixel.y >= 0 and pixel.x < _mask.get_width() and pixel.y < _mask.get_height():
		id = int(_palette.get(_mask.get_pixel(floori(pixel.x), floori(pixel.y)).to_rgba32(), 1))
	out[id] = 1.0
	return out


func _load_maps(folder: String) -> Array[Image]:
	var out: Array[Image] = []
	for i in 4:
		var path := folder.path_join("weights%d.png" % i)
		if not ResourceLoader.exists(path) and not FileAccess.file_exists(path): return []
		var im := preload("res://world/resource_image.gd").read(path)
		if im == null or im.get_size() != Vector2i(SIZE, SIZE): return []
		im.convert(Image.FORMAT_RGBA8); out.append(im)
	return out


func tile(loc: Vector2i) -> Dictionary:
	var cached: Variant = _tiles.get(loc)
	if cached != null: return cached
	var baseline := _load_maps(GENERATED.path_join(key(loc)))
	if baseline.is_empty():
		for i in 4: baseline.append(Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8))
		var ocean := true
		for offset in [Vector2.ZERO, Vector2(1023, 0), Vector2(0, 1023), Vector2(1023, 1023), Vector2(512, 512)]:
			if _seed(Vector2(loc * REGION) + offset)[0] < 1.0: ocean = false
		if ocean:
			baseline[0].fill(Color(1, 0, 0, 0))
		else:
			for y in SIZE:
				for x in SIZE:
					put_weights(baseline, Vector2i(x, y), _seed(Vector2(loc * REGION) + Vector2(x, y) * CELL))
	var maps: Array[Image] = []
	for im in baseline: maps.append(im.duplicate())
	var coverage := Image.create(SIZE, SIZE, false, Image.FORMAT_L8)
	var density := Image.create(SIZE, SIZE, false, Image.FORMAT_L8); density.fill(Color.WHITE)
	var density_boost := Image.create(SIZE, SIZE, false, Image.FORMAT_L8); density_boost.fill(Color.BLACK)
	var vegetation := Image.create(SIZE, SIZE, false, Image.FORMAT_L8); vegetation.fill(Color.BLACK)
	var data := {"maps": maps, "baseline": baseline, "coverage": coverage, "density": density, "density_boost": density_boost, "vegetation": vegetation}
	for entry in [[published_dir, _published], [working_dir, _working] if working else ["", {}]]:
		var ref: String = str(entry[1].get(key(loc), ""))
		if ref.is_empty(): continue
		var folder: String = str(entry[0]).path_join(ref)
		var saved := _load_maps(folder)
		if saved.is_empty(): continue
		var cover := preload("res://world/resource_image.gd").read(folder.path_join("coverage.png"))
		var dens := preload("res://world/resource_image.gd").read(folder.path_join("density.png"))
		var boost_path := folder.path_join("density_boost.png")
		var boost := preload("res://world/resource_image.gd").read(boost_path) if ResourceLoader.exists(boost_path) or FileAccess.file_exists(boost_path) else null
		var vegetation_path := folder.path_join("vegetation.png")
		var saved_vegetation := preload("res://world/resource_image.gd").read(vegetation_path) if ResourceLoader.exists(vegetation_path) or FileAccess.file_exists(vegetation_path) else null
		if cover == null or dens == null or cover.get_size() != Vector2i(SIZE, SIZE) or dens.get_size() != Vector2i(SIZE, SIZE): continue
		if boost==null or boost.get_size()!=Vector2i(SIZE,SIZE):
			boost=Image.create(SIZE,SIZE,false,Image.FORMAT_L8); boost.fill(Color.BLACK)
		else: boost.convert(Image.FORMAT_L8)
		if saved_vegetation==null or saved_vegetation.get_size()!=Vector2i(SIZE,SIZE):
			saved_vegetation=Image.create(SIZE,SIZE,false,Image.FORMAT_L8); saved_vegetation.fill(Color.BLACK)
		else: saved_vegetation.convert(Image.FORMAT_L8)
		# A working snapshot replaces the published snapshot, including erased cells.
		if str(entry[0]) == working_dir:
			for i in 4: maps[i].copy_from(baseline[i])
			coverage.fill(Color.BLACK); density.fill(Color.WHITE); density_boost.fill(Color.BLACK); vegetation.fill(Color.BLACK)
		for y in SIZE:
			for x in SIZE:
				if cover.get_pixel(x, y).r <= 0: continue
				for i in 4: maps[i].set_pixel(x, y, saved[i].get_pixel(x, y))
				coverage.set_pixel(x, y, Color.WHITE)
				density.set_pixel(x, y, dens.get_pixel(x, y))
				density_boost.set_pixel(x,y,boost.get_pixel(x,y))
				vegetation.set_pixel(x,y,saved_vegetation.get_pixel(x,y))
	_tiles[loc] = data; _order.append(loc)
	# Room for every painted tile plus the generated ones around them: the vegetation fill walks
	# rings through all of them, and a reload re-reads twelve PNGs (tens of ms).
	if _order.size() > TILE_CACHE:
		for old in _order.duplicate():
			if old == loc or _dirty.has(old): continue
			_tiles.erase(old); _order.erase(old)
			if _order.size() <= TILE_CACHE: break
	return data


static func get_weights(maps: Array, pixel: Vector2i) -> PackedFloat32Array:
	var weights := PackedFloat32Array(); weights.resize(COUNT)
	if COUNT == 13:
		# The loop below, unrolled: four RGBA maps hold weights 0..12.
		var c: Color = maps[0].get_pixelv(pixel)
		weights[0] = c.r; weights[1] = c.g; weights[2] = c.b; weights[3] = c.a
		c = maps[1].get_pixelv(pixel)
		weights[4] = c.r; weights[5] = c.g; weights[6] = c.b; weights[7] = c.a
		c = maps[2].get_pixelv(pixel)
		weights[8] = c.r; weights[9] = c.g; weights[10] = c.b; weights[11] = c.a
		weights[12] = maps[3].get_pixelv(pixel).r
		return weights
	for i in 4:
		var c: Color = maps[i].get_pixelv(pixel)
		for j in 4:
			if i * 4 + j < COUNT: weights[i * 4 + j] = c[j]
	return weights


static func put_weights(maps: Array, pixel: Vector2i, weights: PackedFloat32Array) -> void:
	var total := 0.0
	for w in weights: total += maxf(w, 0.0)
	if total < 0.0001: weights[1] = 1.0; total = 1.0
	var bytes := PackedInt32Array(); bytes.resize(COUNT)
	var remainder: Array = []; var sum := 0
	for i in COUNT:
		var scaled := maxf(weights[i], 0.0) / total * 255
		bytes[i] = floori(scaled); sum += bytes[i]; remainder.append([scaled - bytes[i], i])
	remainder.sort_custom(func(a, b): return a[0] > b[0] if a[0] != b[0] else a[1] < b[1])
	for i in maxi(0, 255 - sum): bytes[int(remainder[i % COUNT][1])] += 1
	for i in 4:
		var c := Color(0, 0, 0, 0)
		for j in 4:
			if i * 4 + j < COUNT: c[j] = bytes[i * 4 + j] / 255.0
		maps[i].set_pixelv(pixel, c)


func cell_weights(cell: Vector2i) -> PackedFloat32Array:
	var loc := Vector2i(floori(cell.x / float(SIZE)), floori(cell.y / float(SIZE)))
	var pixel := cell - loc * SIZE
	# Sampling an unbuilt sea tile should not allocate a megabyte or stall the camera.
	if not _tiles.has(loc) and not (ResourceLoader.exists(GENERATED.path_join(key(loc)).path_join("weights0.png")) or FileAccess.file_exists(GENERATED.path_join(key(loc)).path_join("weights0.png"))) and not _published.has(key(loc)) and not _working.has(key(loc)):
		return _seed(Vector2(cell) * CELL)
	return get_weights(tile(loc).maps, pixel)


func sample_weights(pos: Vector2) -> PackedFloat32Array:
	var grid := pos / CELL; var cell := Vector2i(floori(grid.x), floori(grid.y))
	var f := grid - Vector2(cell)
	var a: PackedFloat32Array; var b: PackedFloat32Array; var c: PackedFloat32Array; var d: PackedFloat32Array
	var loc := Vector2i(floori(cell.x / float(SIZE)), floori(cell.y / float(SIZE)))
	var pixel := cell - loc * SIZE
	var loaded: Variant = _tiles.get(loc)
	if loaded != null and pixel.x < SIZE - 1 and pixel.y < SIZE - 1:
		# All four corners in one loaded tile: what cell_weights returns, without four lookups.
		var maps: Array = loaded.maps
		a = get_weights(maps, pixel); b = get_weights(maps, pixel + Vector2i.RIGHT)
		c = get_weights(maps, pixel + Vector2i.DOWN); d = get_weights(maps, pixel + Vector2i.ONE)
	else:
		a = cell_weights(cell); b = cell_weights(cell + Vector2i.RIGHT)
		c = cell_weights(cell + Vector2i.DOWN); d = cell_weights(cell + Vector2i.ONE)
	for i in COUNT: a[i] = lerpf(lerpf(a[i], b[i], f.x), lerpf(c[i], d[i], f.x), f.y)
	return a


static func vegetation_density(data: Dictionary,pixel: Vector2i) -> float:
	var base := float((data.density as Image).get_pixelv(pixel).r)
	var boost: Image=data.get("density_boost")
	return base+float(boost.get_pixelv(pixel).r)*(MAX_VEGETATION_DENSITY-1.0) if boost!=null else base


static func put_vegetation_density(data: Dictionary,pixel: Vector2i,value: float) -> void:
	value=clampf(value,0.0,MAX_VEGETATION_DENSITY)
	(data.density as Image).set_pixelv(pixel,Color(minf(value,1.0),0,0))
	var boost: Image=data.get("density_boost")
	if boost!=null: boost.set_pixelv(pixel,Color(maxf(value-1.0,0.0)/(MAX_VEGETATION_DENSITY-1.0),0,0))


static func vegetation_biome(data: Dictionary, pixel: Vector2i) -> int:
	var image: Image = data.get("vegetation")
	return roundi(image.get_pixelv(pixel).r * 255.0) - 1 if image != null else -1


static func put_vegetation_biome(data: Dictionary, pixel: Vector2i, biome: int) -> void:
	var image: Image = data.get("vegetation")
	if image != null: image.set_pixelv(pixel, Color(float(clampi(biome + 1, 0, COUNT)) / 255.0, 0, 0))


func snapshot(loc: Vector2i) -> Dictionary:
	var data := tile(loc); var maps: Array[Image] = []
	for im in data.maps: maps.append(im.duplicate())
	return {"maps":maps,"coverage":data.coverage.duplicate(),"density":data.density.duplicate(),"density_boost":data.density_boost.duplicate(),"vegetation":data.vegetation.duplicate()}


func restore(loc: Vector2i, saved: Dictionary) -> void:
	var data := tile(loc)
	for i in 4: data.maps[i] = saved.maps[i].duplicate()
	data.coverage=saved.coverage.duplicate(); data.density=saved.density.duplicate()
	data.density_boost=saved.density_boost.duplicate() if saved.has("density_boost") else Image.create(SIZE,SIZE,false,Image.FORMAT_L8)
	data.vegetation=saved.vegetation.duplicate() if saved.has("vegetation") else Image.create(SIZE,SIZE,false,Image.FORMAT_L8)
	mark_changed(Rect2(Vector2(loc * REGION), Vector2.ONE * REGION), [loc])


func mark_changed(bounds: Rect2, locations: Array) -> void:
	for loc in locations: _dirty[loc] = true
	revision += 1
	changed.emit(bounds, revision)


static func atomic_json(path: String, data: Dictionary) -> Error:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var pending := path + ".pending"
	var file := FileAccess.open(pending, FileAccess.WRITE)
	if file == null: return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "  ") + "\n"); file.flush(); file.close()
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(pending), ProjectSettings.globalize_path(path))


func save(publish := false) -> Error:
	var folder := published_dir if publish else working_dir
	var index: Dictionary = (_published if publish else _working).duplicate()
	# Publishing includes saved working tiles, even if they are no longer in memory.
	var keys: Array = _dirty.keys()
	if publish:
		for name in _working:
			var xy := str(name).split("_"); var loc := Vector2i(int(xy[0]), int(xy[1]))
			if not keys.has(loc): keys.append(loc)
	for loc: Vector2i in keys:
		var data := tile(loc)
		var generation := "%s/%d_%d" % [key(loc), Time.get_unix_time_from_system(), Time.get_ticks_usec()]
		var path := folder.path_join(generation)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
		for i in 4:
			var err: Error = data.maps[i].save_png(path.path_join("weights%d.png" % i))
			if err != OK: return err
		for name in ["coverage","density","density_boost","vegetation"]:
			var err: Error = data[name].save_png(path.path_join(name + ".png"))
			if err != OK: return err
		index[key(loc)] = generation
	var error := atomic_json(folder.path_join("index.json"), {"version": 1, "cell": CELL, "tiles": index})
	if error == OK:
		if publish: _published = index
		else: _working = index
		_dirty.clear()
	return error
