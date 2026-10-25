extends RefCounted
## The cell grid (docs/DESIGN.md 2.7). One RGBA8 pixel per cell. Alpha 0 = empty cell.
## Pure logic, no Node dependency. The canvas view reads take_dirty_rect() once per frame.

const BASE_COLS := 45
const BASE_ROWS := 73
const MAX_LONG_SIDE := 584
const EMPTY := Color(0, 0, 0, 0)

signal resized(cols: int, rows: int)

## Number of doublings since the base size.
var level: int = 0

var _image: Image
var _dirty: Rect2i = Rect2i()


func _init(p_cols: int = BASE_COLS, p_rows: int = BASE_ROWS) -> void:
	_image = Image.create_empty(maxi(1, p_cols), maxi(1, p_rows), false, Image.FORMAT_RGBA8)


func get_cols() -> int:
	return _image.get_width()


func get_rows() -> int:
	return _image.get_height()


func get_size() -> Vector2i:
	return _image.get_size()


func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < _image.get_width() and cell.y < _image.get_height()


## y * cols + x. -1 when the cell is out of bounds.
func index_of(cell: Vector2i) -> int:
	if not in_bounds(cell):
		return -1
	return cell.y * _image.get_width() + cell.x


## The cell colour; EMPTY out of bounds.
func get_cell(cell: Vector2i) -> Color:
	if not in_bounds(cell):
		return EMPTY
	return _image.get_pixelv(cell)


func is_empty_cell(cell: Vector2i) -> bool:
	return get_cell(cell).a8 == 0


## Writes [param c] into the cell. Returns true when the value changed (compares to_rgba32()).
## Ignores cells out of bounds. A colour with 8-bit alpha 0 is stored as EMPTY.
func set_cell(cell: Vector2i, c: Color) -> bool:
	if not in_bounds(cell):
		return false
	var value: Color = EMPTY if c.a8 == 0 else c
	if _image.get_pixelv(cell).to_rgba32() == value.to_rgba32():
		return false
	_image.set_pixelv(cell, value)
	_mark_dirty(Rect2i(cell, Vector2i.ONE))
	return true


## Applies (cell index, old RGBA32, new RGBA32) triples: the new values when [param use_new],
## else the old values. Returns the rect of the cells written (Rect2i() when none).
@warning_ignore("integer_division")
func apply_triples(triples: PackedInt32Array, use_new: bool) -> Rect2i:
	var cols: int = _image.get_width()
	var count: int = cols * _image.get_height()
	var value_offset: int = 2 if use_new else 1
	var rect := Rect2i()
	var i: int = 0
	while i + 2 < triples.size():
		var idx: int = triples[i]
		if idx >= 0 and idx < count:
			var cell := Vector2i(idx % cols, idx / cols)
			_image.set_pixelv(cell, Color.hex(triples[i + value_offset] & 0xFFFFFFFF))
			rect = _merge(rect, Rect2i(cell, Vector2i.ONE))
		i += 3
	_mark_dirty(rect)
	return rect


## Sets every cell to EMPTY.
func clear() -> void:
	_image.fill(EMPTY)
	_mark_dirty(Rect2i(Vector2i.ZERO, _image.get_size()))


func can_double() -> bool:
	return maxi(_image.get_width(), _image.get_height()) * 2 <= MAX_LONG_SIDE


## Doubles the grid. Each cell becomes an exact 2 x 2 block (nearest filter). Emits resized.
func double_resolution() -> bool:
	if not can_double():
		return false
	_image.resize(_image.get_width() * 2, _image.get_height() * 2, Image.INTERPOLATE_NEAREST)
	level += 1
	_dirty = Rect2i(Vector2i.ZERO, _image.get_size())
	resized.emit(_image.get_width(), _image.get_height())
	return true


## Stores a copy of [param img], converted to RGBA8 without mipmaps. Emits resized.
func set_image(img: Image, p_level: int = 0) -> void:
	if img == null or img.is_empty():
		push_error("PaintingCanvasModel.set_image: empty image")
		return
	var copy: Image = img.duplicate() as Image
	if copy.is_compressed():
		copy.decompress()
	copy.clear_mipmaps()
	if copy.get_format() != Image.FORMAT_RGBA8:
		copy.convert(Image.FORMAT_RGBA8)
	_image = copy
	level = maxi(0, p_level)
	_dirty = Rect2i(Vector2i.ZERO, _image.get_size())
	resized.emit(_image.get_width(), _image.get_height())


## The live image. Callers must not change it or keep it.
func get_image() -> Image:
	return _image


func get_image_copy() -> Image:
	return _image.duplicate() as Image


## The union of the changes since the last call; Rect2i() when none.
func take_dirty_rect() -> Rect2i:
	var r: Rect2i = _dirty
	_dirty = Rect2i()
	return r


## The number of cells with alpha > 0.
func count_painted() -> int:
	var data: PackedByteArray = _image.get_data()
	var n: int = 0
	var i: int = 3
	var size: int = data.size()
	while i < size:
		if data[i] != 0:
			n += 1
		i += 4
	return n


## The n x n cells whose top-left cell is center - ((n - 1) / 2, (n - 1) / 2). Not clipped.
static func square_cells(center: Vector2i, size: int) -> Array[Vector2i]:
	var rect: Rect2i = square_rect(center, size)
	var out: Array[Vector2i] = []
	for y: int in range(rect.position.y, rect.end.y):
		for x: int in range(rect.position.x, rect.end.x):
			out.push_back(Vector2i(x, y))
	return out


## The rect of square_cells(center, size). Not clipped. Sizes below 1 count as 1.
static func square_rect(center: Vector2i, size: int) -> Rect2i:
	var n: int = maxi(1, size)
	var half: int = (n - 1) >> 1
	return Rect2i(center - Vector2i(half, half), Vector2i(n, n))


func _mark_dirty(r: Rect2i) -> void:
	_dirty = _merge(_dirty, r)


# Rect2i.merge() with an empty rect keeps the empty rect's origin; this skips empty rects.
static func _merge(a: Rect2i, b: Rect2i) -> Rect2i:
	if not b.has_area():
		return a
	if not a.has_area():
		return b
	return a.merge(b)
