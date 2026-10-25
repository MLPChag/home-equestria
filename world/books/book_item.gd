extends Node3D
## A hardcover book in its story's colour (the Fimfiction story colour), built from boxes:
## two cover boards, a spine and a cream page block, and the story's cover art on the back
## (dev 2026-09-26) when it has one. Lies flat: X across the cover, Y through the pages (front
## cover up), Z from foot to head. Used in the hand (inventory item) and on house shelves.
const SFX := preload("res://world/audio/interaction_sounds.gd")
const LIBRARY := preload("res://world/books/book_library.gd")
## A large hardcover (dev 2026-09-26: big enough to read in the hand): 20 x 28.5 cm.
const SIZE := Vector3(0.28, 0.036, 0.32)
const BOARD := 0.0035
@export var item_id := ""
static var _meshes := {}      # rounded size key -> ArrayMesh with two surfaces (cover, pages)
static var _page_material: StandardMaterial3D
static var _cover_materials := {}

var _closed: Node3D
var _open: Node3D
var _typesetter: Node
var _book_id := -1
var opened := false
var page := 0                 # left page of the open spread (even); page + 1 on the right
var _swipe: Array = []        # [time, x] of the other hand's fingertip over the pages
var _tween: Tween
const OPEN_BOOK := preload("res://world/books/open_book.gd")
const TYPESETTER := preload("res://world/books/book_typesetter.gd")

func _ready() -> void:
	if item_id.is_empty():
		var parent := get_parent()
		if parent != null and parent.has_meta("item_id"): item_id = str(parent.get_meta("item_id"))
	_closed = build(self, item_id, SIZE)
	_book_id = LIBRARY.id_of(item_id)
	var settings := get_node_or_null("/root/Settings")
	if settings != null: settings.changed.connect(func(key: String):
		if key.begins_with("reading/") and opened: _refresh())

# --- reading: the book opens in the hand and its pages carry the text ------------------------

func open_book() -> bool:
	if opened or _book_id < 0: return opened
	_typesetter = TYPESETTER.get_instance(get_tree())
	if not _typesetter.use_book(_book_id): return false
	if not _typesetter.page_ready.is_connected(_on_page_ready): _typesetter.page_ready.connect(_on_page_ready)
	if _open == null:
		_open = OPEN_BOOK.new()
		_open.name = "Open"
		add_child(_open)
		_open.build(LIBRARY.cover_color(_book_id))
	page = int(LIBRARY.progress(_book_id).get("page", 0))
	page -= page % 2
	SFX.play_at(self, "cover")
	opened = true
	_closed.visible = false
	_open.visible = true
	_refresh()
	_animate_open(1.0)
	return true

func close_book() -> void:
	if not opened: return
	SFX.play_at(self, "cover")
	opened = false
	LIBRARY.save_page(_book_id, page)
	_animate_open(0.0, func():
		if not opened:
			_open.visible = false
			_closed.visible = true)

func _animate_open(to: float, done := Callable()) -> void:
	if _tween != null: _tween.kill()
	_tween = create_tween()
	_tween.tween_property(_open, "open_amount", to, 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if done.is_valid(): _tween.tween_callback(done)

## Turn one leaf: +1 forward, -1 back. False at either end of the book.
func turn(dir: int) -> bool:
	if not opened or _open.flipping(): return false
	var next := page + 2 * signi(dir)
	if next < 0 or _typesetter.locate(next).x == -2: return false
	SFX.play_at(self, "page")
	if dir > 0:
		var from: Texture2D = _typesetter.texture(_book_id, page + 1)
		var to: Texture2D = _typesetter.texture(_book_id, next)
		page = next
		_open.set_pages(_typesetter.texture(_book_id, page - 2), _typesetter.texture(_book_id, page + 1))
		_open.flip(1, from, to)
	else:
		var from: Texture2D = _typesetter.texture(_book_id, page)
		var to: Texture2D = _typesetter.texture(_book_id, next + 1)
		page = next
		_open.set_pages(_typesetter.texture(_book_id, page), _typesetter.texture(_book_id, page + 3))
		_open.flip(-1, from, to)
	_open.flipped.connect(_refresh, CONNECT_ONE_SHOT)
	_prefetch()
	LIBRARY.save_page(_book_id, page)
	return true

## The other hand's fingertip sweeping across the pages turns them (right to left: forward).
func swipe(tip: Vector3, now: float) -> bool:
	if not opened or _open.flipping(): _swipe.clear(); return false
	var p := _open.to_local(tip)
	if absf(p.y) > 0.06 or absf(p.z) > OPEN_BOOK.H * 0.55 or absf(p.x) > OPEN_BOOK.W * 1.1:
		_swipe.clear(); return false
	_swipe.append([now, p.x])
	while not _swipe.is_empty() and now - float(_swipe[0][0]) > 0.4: _swipe.pop_front()
	if _swipe.size() < 3: return false
	var dx: float = float(_swipe[-1][1]) - float(_swipe[0][1])
	if absf(dx) < 0.08: return false
	_swipe.clear()
	return turn(1 if dx < 0.0 else -1)

func _refresh() -> void:
	if not opened or _open.flipping(): return
	_open.set_pages(_typesetter.texture(_book_id, page), _typesetter.texture(_book_id, page + 1))
	_prefetch()

func _prefetch() -> void:
	for k in [page, page + 1, page + 2, page + 3, page - 2, page - 1, page + 4, page + 5]:
		if k >= 0: _typesetter.request(_book_id, k)

func _on_page_ready(book: int, n: int) -> void:
	if book == _book_id and opened and (n == page or n == page + 1): _refresh()

func _exit_tree() -> void:
	if opened: LIBRARY.save_page(_book_id, page)

## Adds the book mesh under `parent`, sized `size`, coloured for `id` (item or story id).
static func build(parent: Node3D, id: Variant, size: Vector3, cover_tree: SceneTree = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Book"
	# Shelf stock follows the existing small decorative-book shadow policy. Held books
	# use the immediate path and keep their authored physical shadows.
	if cover_tree != null: mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.mesh = mesh(size)
	mi.set_surface_override_material(0, cover_material(LIBRARY.cover_color(id)))
	mi.set_surface_override_material(1, page_material())
	parent.add_child(mi)
	if cover_tree == null: _add_cover(mi, id, size)
	else:
		_cover_queue.append({"mesh": weakref(mi), "id": id, "size": size})
		_schedule_covers(cover_tree)
	return mi

## Shelf stock must not decode dozens of cover images in one furnishing frame. The complete
## physical book appears immediately; a shared queue adds cached shelf thumbnails in bounded work.
## Handheld books use the immediate path above. Signal connections die with the SceneTree.
const COVER_FRAME_BUDGET_USEC := 2000
static var _cover_queue: Array[Dictionary] = []
static var _cover_scheduled := false
static var _cover_queue_peak_usec := 0 # Diagnostic: includes the final indivisible image decode.

static func _schedule_covers(tree: SceneTree) -> void:
	if _cover_scheduled: return
	_cover_scheduled = true
	tree.process_frame.connect(_drain_covers.bind(tree), CONNECT_ONE_SHOT)

static func _drain_covers(tree: SceneTree) -> void:
	var resume := _drain_covers.bind(tree)
	if tree.process_frame.is_connected(resume): tree.process_frame.disconnect(resume)
	_cover_scheduled = false
	var started := Time.get_ticks_usec()
	while not _cover_queue.is_empty() and Time.get_ticks_usec() - started < COVER_FRAME_BUDGET_USEC:
		var job: Dictionary = _cover_queue.pop_front()
		var mesh: MeshInstance3D = job.mesh.get_ref() as MeshInstance3D
		if is_instance_valid(mesh) and mesh.is_inside_tree(): _add_cover(mesh, job.id, job.size, true)
	_cover_queue_peak_usec = maxi(_cover_queue_peak_usec, Time.get_ticks_usec() - started)
	if not _cover_queue.is_empty(): _schedule_covers(tree)

static func _add_cover(mesh: MeshInstance3D, id: Variant, size: Vector3, shelf := false) -> void:
	var art := LIBRARY.shelf_cover_texture(id) if shelf else LIBRARY.cover_texture(id)
	if art == null: return
	var back := MeshInstance3D.new()
	back.name = "BackCover"; back.mesh = back_mesh(size)
	if shelf: back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	back.set_surface_override_material(0, art_material(art, size))
	mesh.add_child(back)

## The cover art cropped to fill the back board (centre crop, aspect kept).
static func art_material(art: Texture2D, size: Vector3) -> StandardMaterial3D:
	var key := "%d_%.3f" % [art.get_rid().get_id(), size.x / size.z]
	if _art_materials.has(key): return _art_materials[key]
	var m := StandardMaterial3D.new()
	m.albedo_texture = art
	m.roughness = 0.55
	var board := size.x / size.z
	var image := float(art.get_width()) / maxf(float(art.get_height()), 1.0)
	if image > board:
		m.uv1_scale = Vector3(board / image, 1, 1)
		m.uv1_offset = Vector3((1.0 - board / image) * 0.5, 0, 0)
	else:
		m.uv1_scale = Vector3(1, image / board, 1)
		m.uv1_offset = Vector3(0, (1.0 - image / board) * 0.5, 0)
	_art_materials[key] = m
	return m
static var _art_materials := {}

## One quad just outside the back board, facing -Y; u runs +X, v from head to foot, so the art
## reads upright with the book turned over head-up.
static func back_mesh(size: Vector3) -> ArrayMesh:
	var key := "back_%.3f_%.3f" % [size.x, size.z]
	if _meshes.has(key): return _meshes[key]
	var h := size * 0.5
	var inset := 0.006
	var y := -h.y - 0.0004
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [Vector3(-h.x + inset, y, h.z - inset), Vector3(h.x - inset, y, h.z - inset),
		Vector3(h.x - inset, y, -h.z + inset), Vector3(-h.x + inset, y, -h.z + inset)]
	var uvs := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_normal(Vector3.DOWN)
		st.set_uv(uvs[i])
		st.add_vertex(corners[i])
	var out := st.commit()
	_meshes[key] = out
	return out

static func cover_material(colour: Color) -> StandardMaterial3D:
	var key := colour.to_html(false)
	if not _cover_materials.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = colour
		m.roughness = 0.62
		_cover_materials[key] = m
	return _cover_materials[key]

static func page_material() -> StandardMaterial3D:
	if _page_material == null:
		_page_material = StandardMaterial3D.new()
		_page_material.albedo_color = Color(0.93, 0.9, 0.81)
		_page_material.roughness = 0.9
	return _page_material

static func mesh(size: Vector3) -> ArrayMesh:
	var key := "%.3f_%.3f_%.3f" % [size.x, size.y, size.z]
	if _meshes.has(key): return _meshes[key]
	var h := size * 0.5
	var cover := SurfaceTool.new()
	cover.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Boards overhang the pages by 4 mm at the head, foot and fore edge; the spine is at -X.
	_box(cover, Vector3(-h.x, h.y - BOARD, -h.z), Vector3(h.x, h.y, h.z))
	_box(cover, Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y + BOARD, h.z))
	_box(cover, Vector3(-h.x, -h.y, -h.z), Vector3(-h.x + BOARD * 1.4, h.y, h.z))
	var pages := SurfaceTool.new()
	pages.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(pages, Vector3(-h.x + BOARD, -h.y + BOARD, -h.z + 0.004), Vector3(h.x - 0.004, h.y - BOARD, h.z - 0.004))
	var out := cover.commit()
	pages.commit(out)
	_meshes[key] = out
	return out

static func _box(st: SurfaceTool, lo: Vector3, hi: Vector3) -> void:
	var c := [Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z),
		Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)]
	var faces := [[0, 3, 2, 1, Vector3.FORWARD], [4, 5, 6, 7, Vector3.BACK], [0, 4, 7, 3, Vector3.LEFT],
		[1, 2, 6, 5, Vector3.RIGHT], [3, 7, 6, 2, Vector3.UP], [0, 1, 5, 4, Vector3.DOWN]]
	# Corner lists run counter-clockwise seen from outside; Godot's front faces are clockwise.
	for f: Array in faces:
		for i in [0, 2, 1, 0, 3, 2]:
			st.set_normal(f[4])
			st.add_vertex(c[f[i]])
