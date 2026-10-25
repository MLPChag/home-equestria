extends RefCounted
## The player's book library (dev 2026-09-26): user://books/library.json lists the books,
## user://books/text/<id>.json holds each one's chapters (tools/books/build_library.py writes
## both). Stories are their authors' work and live only in the player's own folder; every
## book shows its author and a link to the original.
##
## Inventory ids are "book:<id>"; one id per story, so copies of the same story stack.

const DIR := "user://books/"
const SAVE_FILE = preload("res://world/save_file.gd")
static var _state_path := ""
static var _state := {"progress": {}, "shelves": {}}

## Texts/covers are shared content; reading and shelf ownership belong to one world.
static func open_world(directory: String) -> void:
	_state_path = directory.path_join("books.json") if not directory.is_empty() else ""
	_state = {"progress": {}, "shelves": {}}
	if not _state_path.is_empty() and FileAccess.file_exists(_state_path):
		var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(_state_path))
		if valid_state(value):
			_state = {"progress":value.get("progress", {}).duplicate(true), "shelves":value.get("shelves", {}).duplicate(true)}

static func snapshot() -> Dictionary:
	return _state.duplicate(true)

static func valid_state(value: Variant) -> bool:
	if not value is Dictionary or not value.get("progress", {}) is Dictionary or not value.get("shelves", {}) is Dictionary: return false
	for row: Variant in value.get("progress", {}).values():
		if not row is Dictionary: return false
		for key: String in row:
			if key not in ["page", "chapter", "at"]: return false
			var number: Variant = row[key]
			if not (number is float or number is int) or not is_finite(float(number)) or number < 0: return false
	for item: Variant in value.get("shelves", {}).values():
		if not (item is bool or item is String): return false
	return true

static func restore(value: Dictionary) -> bool:
	if not valid_state(value): return false
	var next := {"progress": value.get("progress", {}).duplicate(true), "shelves": value.get("shelves", {}).duplicate(true)}
	if not _state_path.is_empty() and SAVE_FILE.write(_state_path, next) != OK: return false
	_state = next
	return true

static var _books: Array = []
static var _by_id := {}
static var _loaded_at := -1
static var _texts := {}      # id -> book document (chapters), a few kept
static var _icons := {}

static func _load() -> void:
	# Reload when the file changes (a library rebuilt while the game runs).
	var path := DIR + "library.json"
	var stamp := FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0
	if stamp == _loaded_at: return
	_loaded_at = stamp
	_books = []
	_by_id = {}
	if stamp == 0: return
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not doc is Dictionary: return
	for book: Dictionary in doc.get("books", []):
		if not book.has("id"): continue
		book.id = int(book.id)
		_books.append(book)
		_by_id[book.id] = book

static func books() -> Array:
	_load()
	return _books

static func item_id(id: int) -> String: return "book:%d" % id

static func id_of(item: String) -> int:
	return int(item.substr(5)) if item.begins_with("book:") else -1

## Metadata of a book by story id or item id ({} when unknown).
static func book(which: Variant) -> Dictionary:
	_load()
	var id: int = id_of(which) if which is String else int(which)
	return _by_id.get(id, {})

## The book's chapters: {"chapters": [{"title", "paragraphs"}], ...}. Cached, a few at a time.
static func text(id: int) -> Dictionary:
	if _texts.has(id): return _texts[id]
	var meta := book(id)
	var path := DIR + str(meta.get("text", "text/%d.json" % id))
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if not doc is Dictionary: return {}
	if _texts.size() >= 4: _texts.erase(_texts.keys()[0])
	_texts[id] = doc
	return doc

static func cover_color(which: Variant) -> Color:
	var hex := str(book(which).get("color", "8a6d4b"))
	return Color.html(hex) if Color.html_is_valid(hex) else Color("8a6d4b")

## A small book icon in the story's colour, for the inventory and the wrist hotbar.
static func icon(which: Variant) -> Texture2D:
	var id: int = id_of(which) if which is String else int(which)
	if _icons.has(id): return _icons[id]
	var colour := cover_color(id)
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var dark := colour.darkened(0.35)
	img.fill_rect(Rect2i(14, 8, 38, 50), Color(0.93, 0.9, 0.82))        # pages
	img.fill_rect(Rect2i(10, 6, 38, 50), colour)                          # cover
	img.fill_rect(Rect2i(10, 6, 6, 50), dark)                             # spine
	img.fill_rect(Rect2i(20, 16, 22, 3), colour.lightened(0.45))          # title lines
	img.fill_rect(Rect2i(20, 22, 16, 2), colour.lightened(0.45))
	var texture := ImageTexture.create_from_image(img)
	_icons[id] = texture
	return texture

static var _covers := {}
## The story's cover art (user://books/covers/<id>.jpg), or null when it has none.
static func cover_texture(which: Variant) -> Texture2D:
	var meta := book(which)
	if meta.is_empty() or not meta.has("cover"): return null
	var id: int = int(meta.id)
	if _covers.has(id): return _covers[id]
	var image := Image.load_from_file(ProjectSettings.globalize_path(DIR + str(meta.cover)))
	var texture: Texture2D = null
	if image != null and not image.is_empty():
		if image.get_width() > 1024: image.resize(1024, int(1024.0 * image.get_height() / image.get_width()), Image.INTERPOLATE_LANCZOS)
		image.generate_mipmaps()
		texture = ImageTexture.create_from_image(image)
	_covers[id] = texture
	return texture

## Shelf copies use their own small GPU textures. Never populate the full-cover cache here;
## picking up a book loads its original reading-quality cover through cover_texture().
const SHELF_COVER_MAX := 256
static var _shelf_covers := {}
static func shelf_cover_texture(which: Variant) -> Texture2D:
	var meta := book(which)
	if meta.is_empty() or not meta.has("cover"): return null
	var id: int = int(meta.id)
	if _shelf_covers.has(id): return _shelf_covers[id]
	var image := Image.load_from_file(ProjectSettings.globalize_path(DIR + str(meta.cover)))
	var texture: Texture2D = null
	if image != null and not image.is_empty():
		var longest := maxi(image.get_width(), image.get_height())
		if longest > SHELF_COVER_MAX:
			var factor := float(SHELF_COVER_MAX) / longest
			image.resize(maxi(1, roundi(image.get_width() * factor)), maxi(1, roundi(image.get_height() * factor)), Image.INTERPOLATE_LANCZOS)
		image.generate_mipmaps()
		texture = ImageTexture.create_from_image(image)
	_shelf_covers[id] = texture
	return texture

# --- reading position -------------------------------------------------------------------------

static func progress(id: int) -> Dictionary:
	var row: Dictionary = _state.progress.get(str(id), {"chapter": 0, "at": 0.0})
	return row.duplicate(true)

## The open book's left page (the typesetter's page stream index).
static func save_page(id: int, page: int) -> void:
	var all: Dictionary = _state.progress.duplicate(true)
	all[str(id)] = {"page": page}
	_write_section("progress", all)

# --- books taken off house shelves (so a shelf does not refill on the next load) ---------------

## Legacy true entries mean empty; string entries persist a book placed in that slot.
static func _shelf_state() -> Dictionary:
	return _state.shelves

static func taken(key: String) -> bool:
	var value: Variant = _shelf_state().get(key, false)
	return value is bool and value

static func shelf_item(key: String, initial_item: String) -> String:
	var value: Variant = _shelf_state().get(key, initial_item)
	if value is bool: return "" if value else initial_item
	return str(value) if value is String and id_of(value) >= 0 else initial_item

static func set_shelf_item(key: String, item: String) -> bool:
	if key.is_empty() or (not item.is_empty() and id_of(item) < 0): return false
	var all: Dictionary = _state.shelves.duplicate(true)
	all[key] = true if item.is_empty() else item
	return _write_section("shelves", all)

static func mark_taken(key: String) -> bool:
	return set_taken(key, true)

static func set_taken(key: String, value: bool) -> bool:
	var all: Dictionary = _state.shelves.duplicate(true)
	if value: all[key] = true
	else: all.erase(key)
	return _write_section("shelves", all)

static func _write_section(section: String, value: Dictionary) -> bool:
	var next := snapshot()
	next[section] = value
	return restore(next)
