extends RefCounted
## Save, load, import and export of paintings (docs/DESIGN.md 2.9). All static. No Node access and
## no shared state, so save_painting_image() is safe on a WorkerThreadPool task (autosave).
##
## A painting is a plain PNG with 1 pixel per cell, RGBA8 (alpha 0 = empty cell) plus a JSON sidecar
## <name>.json. Every write goes to <file>.tmp first and is then renamed over the old file.
## Block-scale detection: the same rule as duniul/pixel-scale (ISC), "the largest k for which every
## k x k block is one colour", computed here from the positions where adjacent rows or columns differ.

const CanvasModel := preload("res://world/painting/core/canvas_model.gd")
const BrushLoad := preload("res://world/painting/core/brush_load.gd")

const PAINTINGS_DIR := "user://paintings"
const IMPORT_DIR := "user://import"
const FORMAT := "easel-painting/1"
const EXPORT_PX_PER_BASE_CELL := 16
## The export long side of a base-aspect painting (73 rows x 16 px). export_scale_for() keeps any
## other size at or below it (a 584 x 400 import at 16 px would be 9344 x 6400 and take seconds).
const EXPORT_MAX_LONG_PX := 1168
const EMPTY_COLOR := Color8(242, 238, 228)
## level_for_size() knows the levels 0..3 (45 x 73 up to 360 x 584).
const MAX_INFERRED_LEVEL := 3
## A sidecar level above this value is clamped (the long-side limit allows no more doublings).
const MAX_LEVEL := 10

const _EMPTY_R := 242
const _EMPTY_G := 238
const _EMPTY_B := 228
const _PNG_SIGNATURE: PackedByteArray = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]


static func ensure_dirs() -> void:
	DirAccess.make_dir_recursive_absolute(PAINTINGS_DIR)
	DirAccess.make_dir_recursive_absolute(IMPORT_DIR)


## Paths are used as given (user://, res:// or absolute).
static func expand_path(p: String) -> String:
	return p


## <name>.png -> <name>.json (in the same form as [param png_path]).
static func sidecar_path(png_path: String) -> String:
	return png_path.get_basename() + ".json"


## Writes the PNG (1 px per cell, RGBA8) and the JSON sidecar atomically. Thread-safe: it only reads
## [param img] and does not change it. [param meta] keys are kept; format, cols, rows and modified
## are always set here; level, mix_depth, created and source get defaults when missing or invalid.
static func save_painting_image(img: Image, png_path: String, meta: Dictionary) -> Error:
	if img == null or img.is_empty():
		return ERR_INVALID_PARAMETER
	var image: Image = _rgba8_view(img)
	var w: int = image.get_width()
	var h: int = image.get_height()
	var abs_png: String = _abs(png_path)
	var err: Error = DirAccess.make_dir_recursive_absolute(abs_png.get_base_dir())
	if err != OK:
		return err
	var now: String = _iso_now()
	var side: Dictionary = meta.duplicate(true)
	side["format"] = FORMAT
	side["cols"] = w
	side["rows"] = h
	side["level"] = _level_from(meta.get("level"), level_for_size(w, h))
	side["mix_depth"] = _depth_from(meta.get("mix_depth"))
	var created: Variant = meta.get("created")
	side["created"] = created if created is String and created != "" else now
	side["modified"] = now
	var source: Variant = meta.get("source", "")
	side["source"] = source if source is String else ""
	var png: PackedByteArray = image.save_png_to_buffer()
	if png.is_empty():
		return ERR_CANT_CREATE
	err = write_atomic(abs_png, png)
	if err != OK:
		return err
	return write_atomic(sidecar_path(abs_png), JSON.stringify(side, "\t").to_utf8_buffer())


## get_image_copy() + save_painting_image(). The sidecar level is the canvas level.
static func save_painting(canvas: CanvasModel, png_path: String, meta: Dictionary) -> Error:
	if canvas == null:
		return ERR_INVALID_PARAMETER
	var m: Dictionary = meta.duplicate(true)
	m["level"] = canvas.level
	return save_painting_image(canvas.get_image_copy(), png_path, m)


## {"image": Image (RGBA8), "meta": Dictionary, "level": int} or {"error": String}.
## A missing or broken sidecar is not an error: the meta then holds defaults, the size of the PNG and
## the inferred level. The PNG is the truth for cols and rows.
static func load_painting(png_path: String) -> Dictionary:
	var abs_png: String = _abs(png_path)
	if not FileAccess.file_exists(abs_png):
		return {"error": "File not found: %s" % png_path}
	var image: Image = _load_png_rgba8(abs_png)
	if image == null:
		return {"error": "Not a readable PNG: %s" % png_path.get_file()}
	var w: int = image.get_width()
	var h: int = image.get_height()
	if maxi(w, h) > CanvasModel.MAX_LONG_SIDE:
		return {"error": _too_large_text(w, h)}
	normalize_alpha(image)
	var inferred: int = level_for_size(w, h)
	var stamp: String = Time.get_datetime_string_from_unix_time(FileAccess.get_modified_time(abs_png)) + "Z"
	var meta: Dictionary = {
		"format": FORMAT, "cols": w, "rows": h, "level": inferred,
		"mix_depth": BrushLoad.DEFAULT_DEPTH, "created": stamp, "modified": stamp, "source": "",
	}
	var side: Variant = _read_json(sidecar_path(abs_png))
	if side is Dictionary:
		var d: Dictionary = side
		for key: Variant in d:
			meta[str(key)] = d[key]
		meta["format"] = FORMAT
		meta["cols"] = w
		meta["rows"] = h
		meta["level"] = _level_from(d.get("level"), inferred)
		meta["mix_depth"] = _depth_from(d.get("mix_depth"))
		if not (meta["source"] is String):
			meta["source"] = ""
	return {"image": image, "meta": meta, "level": meta["level"]}


## {"image": Image (RGBA8, reduced), "block_scale": int, "level": int} or {"error": String}.
## Reduces an exact k x k block upscale, refuses a long side above 584 cells, normalises alpha and
## maps opaque EMPTY_COLOR to empty. The source file never changes.
@warning_ignore("integer_division")
static func import_png(path: String) -> Dictionary:
	var abs_path: String = _abs(path)
	if not FileAccess.file_exists(abs_path):
		return {"error": "File not found: %s" % path}
	var image: Image = _load_png_rgba8(abs_path)
	if image == null:
		return {"error": "Not a readable PNG: %s" % path.get_file()}
	var k: int = detect_block_scale(image)
	if k > 1:
		image.resize(image.get_width() / k, image.get_height() / k, Image.INTERPOLATE_NEAREST)
	var w: int = image.get_width()
	var h: int = image.get_height()
	if maxi(w, h) > CanvasModel.MAX_LONG_SIDE:
		return {"error": _too_large_text(w, h)}
	normalize_alpha(image)
	map_empty_color(image)
	return {"image": image, "block_scale": k, "level": level_for_size(w, h)}


## The largest k (2..max_k) that divides the width and the height where every k x k block is one
## colour; 1 when there is none. Every pair of adjacent rows (and columns) that differ must sit on a
## block edge, so k divides the gcd of the width, the height and all those positions.
static func detect_block_scale(img: Image, max_k: int = 32) -> int:
	if img == null or img.is_empty() or max_k < 2:
		return 1
	var image: Image = _rgba8_view(img)
	var w: int = image.get_width()
	var h: int = image.get_height()
	var g: int = _gcd(w, h)
	if g < 2:
		return 1
	g = _change_gcd(image.get_data(), w * 4, h, g)
	if g < 2:
		return 1
	var turned: Image = image.duplicate() as Image
	turned.rotate_90(CLOCKWISE)   # row j of the turned image is column j of the image
	g = _change_gcd(turned.get_data(), h * 4, w, g)
	for k: int in range(mini(max_k, g), 1, -1):
		if g % k == 0:
			return k
	return 1


## Alpha below 128 becomes empty (0, 0, 0, 0). Alpha 128 or more becomes 255. Converts to RGBA8.
static func normalize_alpha(img: Image) -> void:
	if img == null or img.is_empty():
		return
	_make_rgba8(img)
	var data: PackedByteArray = img.get_data()
	var changed: bool = false
	for i: int in range(3, data.size(), 4):
		var a: int = data[i]
		if a == 255:
			continue
		if a >= 128:
			data[i] = 255
			changed = true
		elif a != 0 or data[i - 3] != 0 or data[i - 2] != 0 or data[i - 1] != 0:
			data[i - 3] = 0
			data[i - 2] = 0
			data[i - 1] = 0
			data[i] = 0
			changed = true
	if changed:
		img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)


## A flattened RGB8 copy of a canvas image: empty cells become EMPTY_COLOR (the easel's stored
## form; map_empty_color() turns them back into empty cells). Thread-safe: [param img] is only read.
static func flatten_rgb8(img: Image) -> Image:
	var copy: Image = img.duplicate() as Image
	_make_rgba8(copy)
	_fill_empty(copy)
	copy.convert(Image.FORMAT_RGB8)
	return copy


## Opaque pixels with the exact value EMPTY_COLOR become empty. Returns the number of pixels changed.
## No full-brush or partial mix at depth 1..8 gives this value, so painted cells never match.
static func map_empty_color(img: Image) -> int:
	if img == null or img.is_empty():
		return 0
	_make_rgba8(img)
	var data: PackedByteArray = img.get_data()
	var count: int = 0
	for i: int in range(0, data.size(), 4):
		if data[i + 3] == 255 and data[i] == _EMPTY_R and data[i + 1] == _EMPTY_G and data[i + 2] == _EMPTY_B:
			data[i] = 0
			data[i + 1] = 0
			data[i + 2] = 0
			data[i + 3] = 0
			count += 1
	if count > 0:
		img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)
	return count


## L when cols == 45 * 2^L and rows == 73 * 2^L (L = 0..3), else 0.
static func level_for_size(cols: int, rows: int) -> int:
	for l: int in range(MAX_INFERRED_LEVEL + 1):
		if cols == CanvasModel.BASE_COLS << l and rows == CanvasModel.BASE_ROWS << l:
			return l
	return 0


## Writes <name>-<YYYYMMDD-HHMMSS>-<W>x<H>.png (W x H = exported pixels) into [param dir] ("~" is
## expanded; the folder is created). Scale: export_scale_for() px per cell, nearest. Empty cells
## become opaque EMPTY_COLOR unless [param transparent]. Returns the path, or "" on failure.
static func export_png(canvas: CanvasModel, dir: String, doc_name: String, transparent: bool = false) -> String:
	if canvas == null:
		return ""
	var image: Image = canvas.get_image_copy()
	_make_rgba8(image)
	if not transparent:
		_fill_empty(image)
	var k: int = export_scale_for(image.get_width(), image.get_height(), canvas.level)
	if k > 1:
		image.resize(image.get_width() * k, image.get_height() * k, Image.INTERPOLATE_NEAREST)
	var out_dir: String = expand_path(dir)
	var abs_dir: String = _abs(dir)
	if DirAccess.make_dir_recursive_absolute(abs_dir) != OK:
		return ""
	var stem: String = doc_name.strip_edges().validate_filename()
	if stem == "":
		stem = "painting"
	var t: Dictionary = Time.get_datetime_dict_from_system()
	stem = "%s-%04d%02d%02d-%02d%02d%02d-%dx%d" % [stem, int(t.year), int(t.month), int(t.day),
		int(t.hour), int(t.minute), int(t.second), image.get_width(), image.get_height()]
	stem = unique_name(abs_dir, stem)
	var png: PackedByteArray = image.save_png_to_buffer()
	if png.is_empty() or write_atomic(abs_dir.path_join(stem + ".png"), png) != OK:
		return ""
	return out_dir.path_join(stem + ".png")


## max(1, 16 >> level): a base-aspect painting exports at 720 x 1168 at every level.
static func export_scale(level: int) -> int:
	return maxi(1, EXPORT_PX_PER_BASE_CELL >> clampi(level, 0, 30))


## export_scale(level), capped so that the long side stays at most EXPORT_MAX_LONG_PX (never
## below 1). Base-aspect paintings keep 720 x 1168 at every level.
static func export_scale_for(cols: int, rows: int, level: int) -> int:
	return maxi(1, mini(export_scale(level), EXPORT_MAX_LONG_PX / maxi(1, maxi(cols, rows))))


## "painting-YYYY-MM-DD-HHMM". [param now] uses the keys of Time.get_datetime_dict_from_system();
## an empty dict means the system time (local).
static func new_painting_name(now: Dictionary = {}) -> String:
	var t: Dictionary = now if not now.is_empty() else Time.get_datetime_dict_from_system()
	return "painting-%04d-%02d-%02d-%02d%02d" % [int(t.get("year", 0)), int(t.get("month", 0)),
		int(t.get("day", 0)), int(t.get("hour", 0)), int(t.get("minute", 0))]


## [param base] when neither <base>.png nor <base>.json exists in [param dir], else base-2, base-3, ...
static func unique_name(dir: String, base: String) -> String:
	var abs_dir: String = _abs(dir)
	var stem: String = base
	var n: int = 2
	while FileAccess.file_exists(abs_dir.path_join(stem + ".png")) \
			or FileAccess.file_exists(abs_dir.path_join(sidecar_path(stem + ".png"))):
		stem = "%s-%d" % [base, n]
		n += 1
	return stem


## The PNG files in [param dir], newest first (file modification time, then name descending):
## {path, name, modified (unix s), cols, rows}. Files that are not PNG data are left out.
static func list_paintings(dir: String = PAINTINGS_DIR) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var abs_dir: String = _abs(dir)
	if not DirAccess.dir_exists_absolute(abs_dir):
		return out
	var shown_dir: String = expand_path(dir)
	for file: String in DirAccess.get_files_at(abs_dir):
		if file.get_extension().to_lower() != "png":
			continue
		var abs_file: String = abs_dir.path_join(file)
		var size: Vector2i = _png_size(abs_file)
		if size == Vector2i.ZERO:
			continue
		out.push_back({
			"path": shown_dir.path_join(file), "name": file.get_basename(),
			"modified": FileAccess.get_modified_time(abs_file), "cols": size.x, "rows": size.y,
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.modified != b.modified:
			return a.modified > b.modified
		return a.name > b.name)
	return out


## The PNG files in each folder of [param dirs] (not recursive; missing folders are skipped), in
## folder order, then by file name: {path, name, dir}. "dir" is the folder as given.
static func list_importable(dirs: PackedStringArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for dir: String in dirs:
		var abs_dir: String = _abs(dir)
		if not DirAccess.dir_exists_absolute(abs_dir):
			continue
		var shown_dir: String = expand_path(dir)
		var files: PackedStringArray = DirAccess.get_files_at(abs_dir)
		files.sort()
		for file: String in files:
			if file.get_extension().to_lower() == "png":
				out.push_back({"path": shown_dir.path_join(file), "name": file.get_basename(), "dir": dir})
	return out


## A nearest-filter copy with the long side at [param max_px]. Empty cells show EMPTY_COLOR, as on
## the canvas.
static func make_thumbnail(img: Image, max_px: int = 128) -> Image:
	if img == null or img.is_empty():
		return Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	var thumb: Image = img.duplicate() as Image
	_make_rgba8(thumb)
	var w: int = thumb.get_width()
	var h: int = thumb.get_height()
	var scale: float = float(maxi(1, max_px)) / float(maxi(w, h))
	thumb.resize(maxi(1, roundi(w * scale)), maxi(1, roundi(h * scale)), Image.INTERPOLATE_NEAREST)
	_fill_empty(thumb)
	return thumb


## Writes [param bytes] to <path>.tmp and renames it over [param path]. Creates no folders.
static func write_atomic(path: String, bytes: PackedByteArray) -> Error:
	var abs_path: String = _abs(path)
	var tmp: String = abs_path + ".tmp"
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(bytes)
	var err: Error = f.get_error()
	f.close()
	if err != OK:
		return err
	return DirAccess.rename_absolute(tmp, abs_path)


## Moves a file that could not be parsed out of the way, so that the next save does not overwrite
## it: <dir>/<name>.broken-<unix time>.<ext> (a rename; "-2", "-3"... is added when that name is
## taken). Logs the move with push_warning. Returns the new absolute path, or "" when there is no
## such file or the rename failed (push_error).
static func move_aside_broken(path: String) -> String:
	var abs_path: String = _abs(path)
	if not FileAccess.file_exists(abs_path):
		return ""
	var stem: String = abs_path.get_basename() + ".broken-%d" % int(Time.get_unix_time_from_system())
	var ext: String = abs_path.get_extension()
	var dot_ext: String = "." + ext if ext != "" else ""
	var target: String = stem + dot_ext
	var n: int = 2
	while FileAccess.file_exists(target):
		target = "%s-%d%s" % [stem, n, dot_ext]
		n += 1
	var err: Error = DirAccess.rename_absolute(abs_path, target)
	if err != OK:
		push_error("PaintingIO: could not move the broken file %s aside (error %d)" % [abs_path, err])
		return ""
	push_warning("PaintingIO: %s could not be read; moved it to %s" % [abs_path, target])
	return target


# --- helpers ---------------------------------------------------------------------------------

static func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(expand_path(p))


static func _iso_now() -> String:
	return Time.get_datetime_string_from_system(true) + "Z"


static func _too_large_text(w: int, h: int) -> String:
	return "Too large: %d x %d cells. The long side must be %d cells or less." % [
		w, h, CanvasModel.MAX_LONG_SIDE]


static func _level_from(v: Variant, fallback: int) -> int:
	if (v is int or v is float) and is_finite(float(v)) and float(v) >= 0.0:
		return clampi(int(v), 0, MAX_LEVEL)
	return fallback


static func _depth_from(v: Variant) -> int:
	if (v is int or v is float) and is_finite(float(v)):
		return clampi(roundi(float(v)), BrushLoad.MIN_DEPTH, BrushLoad.MAX_DEPTH)
	return BrushLoad.DEFAULT_DEPTH


## [param img] itself when it is plain RGBA8, else a converted copy. Never changes [param img].
static func _rgba8_view(img: Image) -> Image:
	if img.get_format() == Image.FORMAT_RGBA8 and not img.has_mipmaps() and not img.is_compressed():
		return img
	var copy: Image = img.duplicate() as Image
	_make_rgba8(copy)
	return copy


## Converts [param img] in place to RGBA8 without mipmaps.
static func _make_rgba8(img: Image) -> void:
	if img.is_compressed():
		img.decompress()
	if img.has_mipmaps():
		img.clear_mipmaps()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)


## The PNG at [param abs_path] as RGBA8, or null. Reads the bytes, so no res:// import warning.
static func _load_png_rgba8(abs_path: String) -> Image:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(abs_path)
	if bytes.size() < 8 or bytes.slice(0, 8) != _PNG_SIGNATURE:
		return null
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK or image.is_empty():
		return null
	_make_rgba8(image)
	return image


## Width and height from the PNG IHDR chunk, without decoding; Vector2i.ZERO when not a PNG.
static func _png_size(abs_path: String) -> Vector2i:
	var f: FileAccess = FileAccess.open(abs_path, FileAccess.READ)
	if f == null or f.get_length() < 24:
		return Vector2i.ZERO
	if f.get_buffer(8) != _PNG_SIGNATURE:
		return Vector2i.ZERO
	f.big_endian = true
	f.seek(12)
	if f.get_buffer(4).get_string_from_ascii() != "IHDR":
		return Vector2i.ZERO
	var w: int = f.get_32()
	var h: int = f.get_32()
	return Vector2i(w, h)


## Parsed JSON at [param path] or null (missing file or parse error; no engine error print).
static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		push_warning("PaintingIO: broken sidecar %s (line %d: %s)" % [
			path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data


## Empty pixels (alpha 0) become opaque EMPTY_COLOR. [param img] must be RGBA8.
static func _fill_empty(img: Image) -> void:
	var data: PackedByteArray = img.get_data()
	var changed: bool = false
	for i: int in range(0, data.size(), 4):
		if data[i + 3] == 0:
			data[i] = _EMPTY_R
			data[i + 1] = _EMPTY_G
			data[i + 2] = _EMPTY_B
			data[i + 3] = 255
			changed = true
	if changed:
		img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)


## gcd of [param g] and every line index y where line y differs from line y - 1.
static func _change_gcd(data: PackedByteArray, stride: int, lines: int, g: int) -> int:
	var prev: PackedByteArray = data.slice(0, stride)
	for y: int in range(1, lines):
		var cur: PackedByteArray = data.slice(y * stride, (y + 1) * stride)
		if cur != prev:
			g = _gcd(g, y)
			if g < 2:
				return 1
		prev = cur
	return g


static func _gcd(a: int, b: int) -> int:
	a = absi(a)
	b = absi(b)
	while b != 0:
		var t: int = a % b
		a = b
		b = t
	return a
