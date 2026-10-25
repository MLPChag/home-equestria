extends Node
## Offline X/Z imagery. Only the main thread owns textures, requests and cache.
signal changed

const ROOT := "res://world/ui/aerial_map/"
const MANIFEST := ROOT + "manifest.json"
const TEXTURE_BUDGET := 64 * 1024 * 1024
var _bounds := Rect2()
var _overview: ImageTexture
var _levels: Array[Dictionary] = []
var _cache: Dictionary = {}
var _cache_bytes := 0
var _overview_bytes := 0
var _wanted: Dictionary = {}
var _visible: Dictionary = {}
var _requests: Array[Dictionary] = []
var _failed: Dictionary = {}
var _worker: Thread
var _loading: Dictionary = {}
var _view: Control
var _signature: Array = []
var _serial := 0

func _ready() -> void:
	_view = get_parent() as Control
	set_process(false)
	if _view == null or not FileAccess.file_exists(MANIFEST): return
	var document: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not document is Dictionary or document.get("version") != 1: return
	var bounds: Variant = document.get("bounds")
	if not bounds is Array or bounds.size() != 4: return
	for value in bounds:
		if not (value is float or value is int) or not is_finite(float(value)): return
	# Bounds are [x, z, width, depth], not min/max coordinates.
	_bounds = Rect2(float(bounds[0]), float(bounds[1]), float(bounds[2]), float(bounds[3]))
	if not _bounds.has_area(): return
	var overview_path := _image_path(str(document.get("overview", "")))
	if overview_path.is_empty(): return
	# One startup decode is allowed; draw_into() never touches disk.
	var overview := _decode_png(overview_path)
	if overview == null: return
	# Charge four bytes per pixel even for RGB, allowing renderer RGBA padding.
	_overview_bytes = overview.get_width() * overview.get_height() * 4
	if _overview_bytes >= TEXTURE_BUDGET: return
	_overview = ImageTexture.create_from_image(overview)
	var levels: Variant = document.get("levels", [])
	if levels is Array:
		for level in levels:
			if not level is Dictionary: continue
			var mpp := float(level.get("metres_per_pixel", 0))
			var span := float(level.get("span", 0))
			if mpp not in [4.0, 1.0, 0.25] or not is_finite(span) or span <= 0: continue
			var tiles: Variant = level.get("tiles", [])
			if not tiles is Array: continue
			var rows: Array[Dictionary] = []
			for tile in tiles:
				if not tile is Dictionary or not tile.has("x") or not tile.has("z"): continue
				var origin := Vector2(float(tile.x), float(tile.z))
				if not origin.is_finite(): continue
				var path := _image_path(str(tile.get("file", "")))
				if path.is_empty(): continue
				var rect := Rect2(origin, Vector2.ONE * span)
				if not rect.intersects(_bounds): continue
				rows.append({"key": path, "rect": rect, "mpp": mpp,
					"bytes": int(ceil(span / mpp)) * int(ceil(span / mpp)) * 4})
			_levels.append({"mpp": mpp, "tiles": rows})
	_levels.sort_custom(func(a: Dictionary, b: Dictionary): return a.mpp > b.mpp)
	set_process(true)

func available() -> bool:
	return _overview != null

func frame_bounds() -> Rect2:
	return _bounds

func draw_into(view: Control) -> void:
	if not available(): return
	var origin: Vector2 = view.world_to_map(_bounds.position)
	var end: Vector2 = view.world_to_map(_bounds.end)
	# Every raster is opaque RGB: finer levels replace pixels without double alpha.
	view.draw_texture_rect(_overview, Rect2(origin, end - origin), false)
	var visible := _view_rect(view)
	var zoom: float = view.zoom
	for level in _levels:
		if not _active(level.mpp, zoom): continue
		for tile: Dictionary in level.tiles:
			if not tile.rect.intersects(visible) or not _cache.has(tile.key): continue
			var texture: ImageTexture = _cache[tile.key].texture
			# Pixel extent, not nominal span, preserves cropped edge tiles exactly.
			var image_rect := Rect2(tile.rect.position, texture.get_size() * float(tile.mpp))
			var clipped := image_rect.intersection(tile.rect).intersection(_bounds).intersection(visible)
			if not clipped.has_area(): continue
			var dest: Vector2 = view.world_to_map(clipped.position)
			var dest_end: Vector2 = view.world_to_map(clipped.end)
			var source := Rect2((clipped.position - image_rect.position) / float(tile.mpp), clipped.size / float(tile.mpp))
			view.draw_texture_rect_region(texture, Rect2(dest, dest_end - dest), source)

func _process(_delta: float) -> void:
	# Sample current view BEFORE consuming a result: stale pans never form a backlog.
	_refresh_requests()
	if _worker != null:
		if _worker.is_alive(): return
		var decoded: Variant = _worker.wait_to_finish()
		_worker = null
		var key: String = _loading.key
		if decoded is Image:
			if _wanted.has(key):
				var bytes: int = decoded.get_width() * decoded.get_height() * 4
				if _make_room(bytes):
					_cache[key] = {"texture": ImageTexture.create_from_image(decoded), "bytes": bytes, "used": _serial}
					_cache_bytes += bytes
					changed.emit()
				else:
					_failed[key] = true
		else:
			_failed[key] = true
		_loading = {}
	for request in _requests:
		if _cache.has(request.key) or _failed.has(request.key): continue
		_loading = request
		_worker = Thread.new()
		# Static decoder, bound path only: no worker accesses this Node or its cache.
		if _worker.start(_decode_png.bind(str(request.key))) != OK:
			_worker = null
			_failed[request.key] = true
			_loading = {}
		return

func _refresh_requests() -> void:
	var visible := _view_rect(_view)
	var zoom: float = _view.zoom
	var signature: Array = [visible, zoom, _view.is_visible_in_tree()]
	if signature == _signature: return
	_signature = signature
	_serial += 1
	_requests.clear()
	_wanted.clear()
	_visible.clear()
	if not _view.is_visible_in_tree(): return
	var candidates: Array[Dictionary] = []
	for level in _levels:
		if not _active(level.mpp, zoom): continue
		for tile: Dictionary in level.tiles:
			if not tile.rect.intersection(_bounds).intersects(visible): continue
			_visible[tile.key] = true
			candidates.append(tile)
	# Cover the entire view cheaply first. The fine tiles nearest the center then
	# use the remaining budget; edges retain a useful regional layer on big panels.
	candidates.sort_custom(func(a: Dictionary, b: Dictionary):
		if (a.mpp == 4.0) != (b.mpp == 4.0): return a.mpp == 4.0
		if a.mpp != b.mpp: return a.mpp < b.mpp
		return a.rect.get_center().distance_squared_to(visible.get_center()) < b.rect.get_center().distance_squared_to(visible.get_center()))
	var remaining := TEXTURE_BUDGET - _overview_bytes
	for tile in candidates:
		if _wanted.has(tile.key): continue
		var bytes: int = _cache[tile.key].bytes if _cache.has(tile.key) else tile.bytes
		if bytes > remaining: continue
		remaining -= bytes
		_wanted[tile.key] = true
		_requests.append(tile)
		if _cache.has(tile.key): _cache[tile.key].used = _serial

func _make_room(bytes: int) -> bool:
	if bytes + _overview_bytes > TEXTURE_BUDGET: return false
	while _cache_bytes + _overview_bytes + bytes > TEXTURE_BUDGET:
		var victim := ""
		for key: String in _cache:
			if _wanted.has(key): continue
			if victim.is_empty():
				victim = key
			elif _visible.has(victim) and not _visible.has(key):
				victim = key
			elif _visible.has(victim) == _visible.has(key) and _cache[key].used < _cache[victim].used:
				victim = key
		if victim.is_empty(): return false
		_cache_bytes -= int(_cache[victim].bytes)
		_cache.erase(victim)
	return true

func _exit_tree() -> void:
	if _worker != null:
		_worker.wait_to_finish()
		_worker = null

static func _active(mpp: float, zoom: float) -> bool:
	if mpp == 0.25: return zoom > 1.0
	if mpp == 1.0: return zoom > 0.35
	return zoom > 0.1

static func _view_rect(view: Control) -> Rect2:
	var first: Vector2 = view.map_to_world(Vector2.ZERO)
	var last: Vector2 = view.map_to_world(view.size)
	return Rect2(first, last - first).abs()

static func _image_path(relative: String) -> String:
	if relative.is_empty() or relative.is_absolute_path() or ".." in relative: return ""
	var resource := ROOT + relative
	var absolute := ProjectSettings.globalize_path(resource)
	return absolute if FileAccess.file_exists(absolute) else resource

static func _decode_png(path: String) -> Image:
	var decoded := Image.new()
	var error: Error
	if path.begins_with("res://"):
		# Export must include raw manifest/PNGs; no imported-resource dependency.
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty(): return null
		error = decoded.load_png_from_buffer(bytes)
	else:
		error = decoded.load(path)
	if error != OK or decoded.is_empty(): return null
	decoded.clear_mipmaps()
	decoded.convert(Image.FORMAT_RGB8)
	return decoded
