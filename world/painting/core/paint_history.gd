extends RefCounted
## Undo and redo for the canvas (docs/DESIGN.md 2.8). An own stack, not Godot's UndoRedo, so
## old steps can drop by memory size. Pattern from Pixelorama v1.1.8 src/Tools/BaseDraw.gd (MIT):
## collect the diff while the stroke is open, commit one step at the stroke end.
##
## Stroke steps store (cell index, old RGBA32, new RGBA32) triples in a PackedInt32Array. RGBA32
## is Color.to_rgba32() stored as a signed 32-bit value; read it with Color.hex(v & 0xFFFFFFFF).
## Snapshot steps store full images (double resolution, clear canvas, snap to palette).

const CanvasModel := preload("res://world/painting/core/canvas_model.gd")

const DEFAULT_MAX_STEPS := 500
const DEFAULT_MAX_BYTES := 268435456      # 256 MiB
const BYTES_PER_CELL := 12
## Step names of stroke steps per tool. Unknown tools give "Paint".
const STROKE_NAMES: Dictionary = {&"brush": "Paint", &"sponge": "Erase", &"pencil": "Draw"}

signal changed(can_undo: bool, can_redo: bool)

var max_steps: int
var max_bytes: int


class Step:
	extends RefCounted
	var name: String = ""
	var triples: PackedInt32Array = PackedInt32Array()   # stroke step
	var rect: Rect2i = Rect2i()
	var before: Image = null                             # snapshot step; null for a stroke
	var after: Image = null
	var before_level: int = 0
	var after_level: int = 0
	var bytes: int = 0


var _canvas: CanvasModel
var _steps: Array[Step] = []
var _index: int = 0                 # steps [0, _index) are applied
var _bytes: int = 0                 # sum of Step.bytes over _steps

var _open_tool: StringName = &""
var _open_triples: PackedInt32Array = PackedInt32Array()
var _open_pos: Dictionary = {}      # cell index -> position of its triple in _open_triples


func _init(p_canvas: CanvasModel, p_max_steps: int = DEFAULT_MAX_STEPS,
		p_max_bytes: int = DEFAULT_MAX_BYTES) -> void:
	_canvas = p_canvas
	max_steps = maxi(1, p_max_steps)
	max_bytes = maxi(1, p_max_bytes)


## Records one cell change of [param tool]. Opens a stroke for the tool. When a stroke of the
## other tool is open, commits that stroke first. Per cell, the stroke keeps the first old colour
## and the last new colour. The caller has already written the new colour into the canvas.
func record(tool: StringName, cell: Vector2i, old_color: Color, new_color: Color) -> void:
	var idx: int = _canvas.index_of(cell)
	if idx < 0:
		return
	if _open_tool != &"" and _open_tool != tool:
		end_stroke()
	if _open_tool == &"":
		_open_tool = tool
		_open_triples = PackedInt32Array()
		_open_pos = {}
	var new32: int = _rgba32(new_color)
	if _open_pos.has(idx):
		_open_triples[int(_open_pos[idx]) + 2] = new32
	else:
		_open_pos[idx] = _open_triples.size()
		_open_triples.push_back(idx)
		_open_triples.push_back(_rgba32(old_color))
		_open_triples.push_back(new32)


## Commits the open stroke when a cell changed. Returns true when a step was added.
@warning_ignore("integer_division")
func end_stroke() -> bool:
	if _open_tool == &"":
		return false
	var tool: StringName = _open_tool
	var src: PackedInt32Array = _open_triples
	_open_tool = &""
	_open_triples = PackedInt32Array()
	_open_pos = {}

	var kept := PackedInt32Array()
	var rect := Rect2i()
	var cols: int = maxi(1, _canvas.get_cols())
	var i: int = 0
	while i + 2 < src.size():
		if src[i + 1] != src[i + 2]:
			kept.push_back(src[i])
			kept.push_back(src[i + 1])
			kept.push_back(src[i + 2])
			rect = _merge(rect, Rect2i(src[i] % cols, src[i] / cols, 1, 1))
		i += 3
	if kept.is_empty():
		return false
	var step := Step.new()
	step.name = STROKE_NAMES.get(tool, "Paint")
	step.triples = kept
	step.rect = rect
	step.bytes = (kept.size() / 3) * BYTES_PER_CELL
	_push(step)
	return true


func is_stroke_open() -> bool:
	return _open_tool != &""


## The tool of the open stroke; &"" when none.
func get_open_tool() -> StringName:
	return _open_tool


## Adds a snapshot step. Ends the open stroke first. Keeps the images as given, so callers pass
## copies (canvas.get_image_copy()).
func add_snapshot_action(action_name: String, before: Image, after: Image, before_level: int,
		after_level: int) -> void:
	end_stroke()
	if before == null or after == null:
		push_error("PaintingPaintHistory.add_snapshot_action: null image")
		return
	var step := Step.new()
	step.name = action_name
	step.before = before
	step.after = after
	step.before_level = before_level
	step.after_level = after_level
	step.rect = Rect2i(Vector2i.ZERO, after.get_size())
	step.bytes = before.get_data().size() + after.get_data().size()
	_push(step)


## Ends the open stroke first. Returns {} when there is nothing to undo, else
## {"name": String, "rect": Rect2i} with the changed rect in the resulting canvas.
func undo() -> Dictionary:
	end_stroke()
	if _index <= 0:
		return {}
	_index -= 1
	var step: Step = _steps[_index]
	var rect: Rect2i = _apply(step, false)
	_emit_changed()
	return {"name": step.name, "rect": rect}


## Ends the open stroke first (a commit drops the redo steps). Same result as undo().
func redo() -> Dictionary:
	end_stroke()
	if _index >= _steps.size():
		return {}
	var step: Step = _steps[_index]
	_index += 1
	var rect: Rect2i = _apply(step, true)
	_emit_changed()
	return {"name": step.name, "rect": rect}


func can_undo() -> bool:
	return _index > 0


func can_redo() -> bool:
	return _index < _steps.size()


## Drops every step and the open stroke (without a commit).
func clear_history() -> void:
	_open_tool = &""
	_open_triples = PackedInt32Array()
	_open_pos = {}
	_steps.clear()
	_index = 0
	_bytes = 0
	_emit_changed()


func get_undo_name() -> String:
	return _steps[_index - 1].name if _index > 0 else ""


func get_redo_name() -> String:
	return _steps[_index].name if _index < _steps.size() else ""


## Steps in the stack, redo steps included.
func get_step_count() -> int:
	return _steps.size()


## Bytes of all steps in the stack (stroke: 12 per cell; snapshot: both image data sizes).
func get_bytes() -> int:
	return _bytes


func _push(step: Step) -> void:
	while _steps.size() > _index:
		var dropped: Step = _steps.pop_back()
		_bytes -= dropped.bytes
	_steps.push_back(step)
	_bytes += step.bytes
	_index += 1
	# Drop the oldest steps over either limit. The newest step always stays.
	while _steps.size() > 1 and (_steps.size() > max_steps or _bytes > max_bytes):
		var oldest: Step = _steps.pop_front()
		_bytes -= oldest.bytes
		_index -= 1
	_emit_changed()


func _apply(step: Step, use_new: bool) -> Rect2i:
	if step.before == null:
		return _canvas.apply_triples(step.triples, use_new)
	if use_new:
		_canvas.set_image(step.after, step.after_level)
	else:
		_canvas.set_image(step.before, step.before_level)
	return Rect2i(Vector2i.ZERO, _canvas.get_size())


func _emit_changed() -> void:
	changed.emit(can_undo(), can_redo())


# RGBA32 as a signed 32-bit value (alpha 0 counts as EMPTY, as in PaintingCanvasModel.set_cell).
static func _rgba32(c: Color) -> int:
	if c.a8 == 0:
		return 0
	var v: int = c.to_rgba32()
	return v - 0x100000000 if v >= 0x80000000 else v


static func _merge(a: Rect2i, b: Rect2i) -> Rect2i:
	if not b.has_area():
		return a
	if not a.has_area():
		return b
	return a.merge(b)
