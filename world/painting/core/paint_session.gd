extends RefCounted
## The painting facade for tools, rigs, UI and tests (docs/DESIGN.md 2.3, 2.4, 2.7, 2.8, 2.16,
## 4.3). It owns the canvas model, the brushes, the mixing wells, the colour journal and the
## history. Pure logic, no Node dependency.
##
## Touch protocol per tool: touch_begin() at contact, touch_move() each tick (gap fill with
## Geometry2D.bresenham_line, as Pixelorama v1.1.8 BaseDraw.draw_fill_gap, MIT), touch_break() at
## lift-off or off-canvas, touch_end() when the 0.25 s stroke timeout expires or the tool drops.
## The touch_* calls return the number of changed cells, so the tools can pulse the haptics on
## every painted and every erased cell.
##
## Mixing modes (setting mixing_mode, 2.16):
## - "paint" (default): brush = pigment_brush (PaintingPigmentBrush, palette "Easel 10", 10
##   pigments, spectral mixing), 4 mixing wells, wet canvas.
## - "classic": brush = classic_brush (PaintingBrushLoad, 6 pure colours, FIFO loads, sRGB average,
##   mix depth). No wells, no wet canvas. snap_to_palette() works in this mode only.
## Both modes name the brush colour after each dip (brush_named, color_discovered).
##
## Storage: the wells and the journal live in memory until open_storage() gives them files
## (main.gd calls it once; tests pass paths under user://_test/).

const CanvasModel := preload("res://world/painting/core/canvas_model.gd")
const BrushLoad := preload("res://world/painting/core/brush_load.gd")
const PigmentBrush := preload("res://world/painting/core/pigment_brush.gd")
const PaintHistory := preload("res://world/painting/core/paint_history.gd")
const Spectral := preload("res://world/painting/core/spectral.gd")
const ColorNames := preload("res://world/painting/core/color_names.gd")
const ColorJournal := preload("res://world/painting/core/color_journal.gd")
const PaintingIO := preload("res://world/painting/core/painting_io.gd")

const BRUSH := &"brush"
const SPONGE := &"sponge"
## A 1-cell graphite line: no dips, no wet mixing, no brush load.
const PENCIL := &"pencil"
const PENCIL_COLOR := Color8(58, 58, 66)
## The easel keeps a short history in memory only (no undo is exposed yet).
const HISTORY_STEPS := 50
const HISTORY_BYTES := 8388608      # 8 MiB
const MIN_BRUSH_SIZE := 1
const MAX_BRUSH_SIZE := 4
const MIN_SPONGE_SIZE := 1
const MAX_SPONGE_SIZE := 6

const MODE_PAINT := "paint"
const MODE_CLASSIC := "classic"
const MIXING_MODES: PackedStringArray = ["paint", "classic"]
const WELL_COUNT := 4
const WELLS_PATH := "user://wells.json"
const WELLS_VERSION := 1
## Results of touch_well().
const WELL_STORED := &"stored"
const WELL_DIPPED := &"dipped"

## Both modes: after every change of the active brush (dip, rinse, depth, mode switch). In paint
## mode loads = PaintingPigmentBrush.loads() (pigments with a share >= 10 %, largest first) and
## depth = 10 (the pigment count).
signal brush_changed(color: Color, loads: PackedInt32Array, depth: int)
## Paint mode only: after every change of the pigment brush. amounts: 10 values, sum <= 1.
signal brush_mix_changed(color: Color, amounts: PackedFloat64Array)
signal mixing_mode_changed(mode: String)
## A well was stored, emptied or loaded from the file.
signal wells_changed
## After every dip (pigment or well): the nearest named colour and its OKLab distance.
signal brush_named(name: String, distance: float)
## After a dip whose colour is within ColorNames.DISCOVER_DISTANCE of a name that is not in the
## journal yet. The journal already holds the new entry when this fires.
signal color_discovered(name: String, named_color: Color, brush_color: Color)
signal history_changed(can_undo: bool, can_redo: bool)
signal history_applied(action_name: String, rect: Rect2i, is_redo: bool)
signal canvas_resized(cols: int, rows: int, level: int)
signal canvas_replaced                   # after load_image / new_canvas
signal edited                            # any change that needs an autosave

var canvas: CanvasModel                  # read-only for callers
## The active brush: classic_brush or pigment_brush (an PaintingPigmentBrush is an PaintingBrushLoad).
var brush: BrushLoad                     # read-only for callers
var classic_brush: BrushLoad             # read-only for callers
var pigment_brush: PigmentBrush          # read-only for callers
var history: PaintHistory                # read-only for callers
var journal: ColorJournal                # read-only for callers
## "paint" or "classic". Read-only; use set_mixing_mode().
var mixing_mode: String = MODE_PAINT

## Brush footprint: n x n current cells (2.3). Clamped to 1..4.
var brush_size: int = 1:
	set(v):
		brush_size = clampi(v, MIN_BRUSH_SIZE, MAX_BRUSH_SIZE)
## Sponge footprint in base cells; the square is sponge_size * 2^level current cells (2.4).
## Clamped to 1..6. Default 3.
var sponge_size: int = 3:
	set(v):
		sponge_size = clampi(v, MIN_SPONGE_SIZE, MAX_SPONGE_SIZE)
## When true, the brush paints only when it is full (2.2: N loads; paint mode: amounts sum to
## 0.999, so after a load-up). Default false.
var require_full_load: bool = false
## Paint mode (2.16): a brush cell over a different colour becomes the spectral 50/50 mix of the
## cell and the brush. Ignored in classic mode.
var wet_canvas: bool = true
## Name the brush colour after each dip (brush_named, color_discovered, the journal). The easel
## turns it off: the first lookup loads the 4961-name table, a visible stall in VR.
var name_dips: bool = true

# tool -> last cell of the touch. A tool without an entry has no contact and no gap-fill anchor.
var _last: Dictionary[StringName, Vector2i] = {}
var _wells: Array[PackedFloat64Array] = []   # an empty array is an empty well
var _wells_path: String = ""
# Wet canvas: the cells under the brush footprint at the previous applied point of this touch.
# They do not mix again until the brush leaves them (or lifts), as in the Mixing Lab.
var _wet_prev: Dictionary = {}
var _wet_cache: Dictionary = {}              # old 0xRRGGBB -> mixed Color for _wet_cache_brush
var _wet_cache_brush: int = -1


## The default mix depth is 5; the default mixing mode is "paint" (2.16).
func _init(cols: int = CanvasModel.BASE_COLS, rows: int = CanvasModel.BASE_ROWS,
		mix_depth: int = BrushLoad.DEFAULT_DEPTH, p_mixing_mode: String = MODE_PAINT) -> void:
	canvas = CanvasModel.new(cols, rows)
	classic_brush = BrushLoad.new(mix_depth)
	pigment_brush = PigmentBrush.new()
	history = PaintHistory.new(canvas, HISTORY_STEPS, HISTORY_BYTES)
	journal = ColorJournal.new("")
	for i: int in WELL_COUNT:
		_wells.append(PackedFloat64Array())
	if not MIXING_MODES.has(p_mixing_mode):
		push_warning("PaintingPaintSession: unknown mixing mode '%s'; using paint" % p_mixing_mode)
	mixing_mode = MODE_CLASSIC if p_mixing_mode == MODE_CLASSIC else MODE_PAINT
	brush = classic_brush if mixing_mode == MODE_CLASSIC else pigment_brush
	canvas.resized.connect(_on_canvas_resized)
	classic_brush.changed.connect(_on_brush_changed.bind(classic_brush))
	pigment_brush.changed.connect(_on_brush_changed.bind(pigment_brush))
	history.changed.connect(_on_history_changed)


## Switches the mixing mode. Commits open strokes and rinses both brushes. Returns false for an
## unknown mode (nothing changes). Emits mixing_mode_changed, then brush_changed.
func set_mixing_mode(mode: String) -> bool:
	if not MIXING_MODES.has(mode):
		push_warning("PaintingPaintSession: unknown mixing mode '%s'" % mode)
		return false
	if mode == mixing_mode:
		return true
	end_all_touches()
	var old: BrushLoad = brush
	mixing_mode = mode
	brush = classic_brush if mode == MODE_CLASSIC else pigment_brush
	_wet_prev.clear()
	old.rinse()             # inactive now: no brush_changed
	mixing_mode_changed.emit(mode)
	brush.rinse()
	return true


func is_paint_mode() -> bool:
	return mixing_mode == MODE_PAINT


## Dips into pigment / base colour [param base] of the active palette. [param light] (a light
## touch) applies in paint mode only. Then names the brush colour (discovery). An invalid index
## is ignored.
func dip(base: int, light: bool = false) -> void:
	if base < 0 or base >= palette_count():
		push_warning("PaintingPaintSession.dip: invalid colour %d" % base)
		return
	if mixing_mode == MODE_PAINT:
		pigment_brush.dip(base, light)
	else:
		classic_brush.dip(base)
	_discover()


func rinse() -> void:
	brush.rinse()


## The classic mix depth (kept in paint mode for a later switch).
func set_mix_depth(d: int) -> void:
	classic_brush.set_depth(d)


## The brush has paint: any paint, or a full brush when require_full_load is true.
func can_paint() -> bool:
	if brush.is_empty():
		return false
	return brush.is_full() or not require_full_load


# --- palette (both modes) -----------------------------------------------------------------

## The number of colours on the palette: 10 pigments (paint) or 6 base colours (classic).
func palette_count() -> int:
	return PigmentBrush.PIGMENT_COUNT if mixing_mode == MODE_PAINT else BrushLoad.BASE_RGB.size()


## The blob colour of index [param i] in the active palette; EMPTY for a wrong index.
func palette_color(i: int) -> Color:
	if i < 0 or i >= palette_count():
		return BrushLoad.EMPTY
	return PigmentBrush.PIGMENT_RGB[i] if mixing_mode == MODE_PAINT else BrushLoad.BASE_RGB[i]


## The name of index [param i] in the active palette ("White" ... in paint mode, "white" ... in
## classic mode); "" for a wrong index.
func palette_name(i: int) -> String:
	if i < 0 or i >= palette_count():
		return ""
	return PigmentBrush.PIGMENT_NAMES[i] if mixing_mode == MODE_PAINT else BrushLoad.BASE_NAMES[i]


## All blob colours of the active palette, by index.
func palette_colors() -> Array[Color]:
	var out: Array[Color] = []
	for i: int in palette_count():
		out.append(palette_color(i))
	return out


# --- wells (paint mode) -------------------------------------------------------------------

## True when well [param i] holds no mixture (also for a wrong index).
func is_well_empty(i: int) -> bool:
	return i < 0 or i >= WELL_COUNT or _wells[i].is_empty()


## A copy of the normalised mixture in well [param i] (10 values); empty for an empty well.
func well_mixture(i: int) -> PackedFloat64Array:
	return PackedFloat64Array() if is_well_empty(i) else _wells[i].duplicate()


## The colour of well [param i]; EMPTY for an empty well.
func well_color(i: int) -> Color:
	return BrushLoad.EMPTY if is_well_empty(i) else PigmentBrush.mixture_color(_wells[i])


## Stores the brush mixture (normalised) in well [param i]. Only in paint mode, with paint on
## the brush and an empty well. Saves the wells. Returns true when stored.
func store_well(i: int) -> bool:
	if mixing_mode != MODE_PAINT or i < 0 or i >= WELL_COUNT or not _wells[i].is_empty() \
			or pigment_brush.is_empty():
		return false
	_wells[i] = pigment_brush.snapshot()
	save_wells()
	wells_changed.emit()
	return true


## Dips into well [param i] like into a pigment (normal or light; the load-up run counts per
## well, key "well<i>"). Only in paint mode and for a full well. Then names the brush colour.
## Returns true when dipped.
func dip_well(i: int, light: bool = false) -> bool:
	if mixing_mode != MODE_PAINT or is_well_empty(i):
		return false
	if not pigment_brush.dip_mixture(_wells[i], "well%d" % i, light):
		return false
	_discover()
	return true


## The palette action of a touch on well [param i]: an empty well stores the brush (WELL_STORED),
## a full well is dipped (WELL_DIPPED); &"" when nothing happened (classic mode, empty brush on
## an empty well, wrong index).
func touch_well(i: int, light: bool = false) -> StringName:
	if is_well_empty(i):
		return WELL_STORED if store_well(i) else &""
	return WELL_DIPPED if dip_well(i, light) else &""


## Empties all wells (the menu "Empty wells"). Saves the wells.
func clear_wells() -> void:
	for i: int in WELL_COUNT:
		_wells[i] = PackedFloat64Array()
	save_wells()
	wells_changed.emit()


## Gives the wells and the journal their files and loads both. Before this call they live in
## memory only. "" for a path keeps that part in memory.
func open_storage(wells_path: String = WELLS_PATH,
		journal_path: String = ColorJournal.PATH) -> void:
	_wells_path = wells_path
	load_wells()
	journal.set_file_path(journal_path)
	journal.load_file()


## Reads the wells file (open_storage() path). A missing or broken file, or a broken well, gives
## empty wells. A file that is not a wells file (bad JSON, no "wells" list) is moved aside to
## wells.broken-<unix time>.json first (PaintingPaintingIO.move_aside_broken), so the next save does
## not overwrite it. Emits wells_changed.
func load_wells() -> void:
	for i: int in WELL_COUNT:
		_wells[i] = PackedFloat64Array()
	if _wells_path != "" and FileAccess.file_exists(_wells_path):
		var json := JSON.new()
		var rows: Variant = null
		if json.parse(FileAccess.get_file_as_string(_wells_path)) == OK and json.data is Dictionary:
			rows = (json.data as Dictionary).get("wells")
		if rows is Array:
			for i: int in mini((rows as Array).size(), WELL_COUNT):
				_wells[i] = _valid_mixture((rows as Array)[i])
		else:
			push_warning("PaintingPaintSession: %s holds no wells; the wells are empty" % _wells_path)
			PaintingIO.move_aside_broken(_wells_path)
	wells_changed.emit()


## Writes the wells file atomically. OK without a path (memory only).
func save_wells() -> Error:
	if _wells_path == "":
		return OK
	var err: Error = DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(_wells_path).get_base_dir())
	if err != OK:
		return err
	var rows: Array = []
	for w: PackedFloat64Array in _wells:
		rows.append(null if w.is_empty() else Array(w))
	var doc: Dictionary = {
		"version": WELLS_VERSION,
		"palette": PigmentBrush.PALETTE_NAME,
		"pigments": Array(PigmentBrush.PIGMENT_NAMES),
		"wells": rows,
	}
	return PaintingIO.write_atomic(_wells_path, JSON.stringify(doc, "\t").to_utf8_buffer())


## The wells file path ("" = memory only).
func get_wells_path() -> String:
	return _wells_path


# --- discovery ----------------------------------------------------------------------------

## The named colour nearest to the brush colour (PaintingColorNames.nearest()); {} for an empty brush.
func name_brush() -> Dictionary:
	if brush.is_empty():
		return {}
	return ColorNames.nearest(brush.color())


## True when the wet canvas applies (wet_canvas on and paint mode).
func is_wet() -> bool:
	return wet_canvas and mixing_mode == MODE_PAINT


# --- touches ------------------------------------------------------------------------------

## Starts (or restarts) the touch of [param tool] at [param cell], without gap fill.
## Returns the number of changed cells. A cell off the canvas acts as touch_break().
func touch_begin(tool: StringName, cell: Vector2i) -> int:
	if not _valid_tool(tool):
		return 0
	_last.erase(tool)
	if tool == BRUSH:
		_wet_prev.clear()
	return touch_move(tool, cell)


## Continues the touch: applies the footprint along the line from the last cell to [param cell].
## Without a last cell (after a break) it starts at [param cell]. Returns the changed cells.
func touch_move(tool: StringName, cell: Vector2i) -> int:
	if not _valid_tool(tool):
		return 0
	if not canvas.in_bounds(cell):
		touch_break(tool)
		return 0
	var points: Array[Vector2i] = [cell]
	if _last.has(tool):
		points = Geometry2D.bresenham_line(_last[tool], cell)
		if points.size() > 1:
			points.pop_front()   # the last cell was painted in the previous tick
	_last[tool] = cell
	var changed: int = 0
	if tool == BRUSH:
		if not can_paint():
			return 0
		var color: Color = brush.color()
		for p: Vector2i in points:
			changed += _apply_footprint(tool, p, color)
	elif tool == PENCIL:
		for p: Vector2i in points:
			changed += _apply_footprint(tool, p, PENCIL_COLOR)
	else:
		for p: Vector2i in points:
			changed += _apply_footprint(tool, p, CanvasModel.EMPTY)
	if changed > 0:
		edited.emit()
	return changed


## Lift-off or off-canvas: the next cell gets no gap fill. The stroke stays open.
func touch_break(tool: StringName) -> void:
	_last.erase(tool)
	if tool == BRUSH:
		_wet_prev.clear()


## Ends the touch. Commits the open stroke when it belongs to [param tool].
func touch_end(tool: StringName) -> void:
	touch_break(tool)
	if history.get_open_tool() == tool:
		history.end_stroke()


## Breaks the touches of all tools and commits the open stroke.
func end_all_touches() -> void:
	touch_break(BRUSH)
	touch_break(SPONGE)
	touch_break(PENCIL)
	history.end_stroke()


## True between a touch_begin()/touch_move() on the canvas and the next touch_break()/touch_end().
func is_touching(tool: StringName) -> bool:
	return _last.has(tool)


func undo() -> bool:
	end_all_touches()
	return _emit_applied(history.undo(), false)


func redo() -> bool:
	end_all_touches()
	return _emit_applied(history.redo(), true)


## One undo step (a snapshot). False at the maximum size.
func double_resolution() -> bool:
	end_all_touches()
	if not canvas.can_double():
		return false
	var before: Image = canvas.get_image_copy()
	var before_level: int = canvas.level
	canvas.double_resolution()
	history.add_snapshot_action("Double resolution", before, canvas.get_image_copy(),
			before_level, canvas.level)
	edited.emit()
	return true


## One undo step (a snapshot). Does nothing on an empty canvas.
func clear_canvas() -> void:
	end_all_touches()
	if canvas.count_painted() == 0:
		return
	var before: Image = canvas.get_image_copy()
	canvas.clear()
	history.add_snapshot_action("Clear canvas", before, canvas.get_image_copy(), canvas.level,
			canvas.level)
	edited.emit()


## Classic mode only (2.9): maps each painted cell to the nearest full-brush mix at the current
## mix depth. One undo step when a cell changed. Returns the number of changed cells. In paint
## mode it does nothing and returns 0 (the pigment palette has no finite set of mixes).
func snap_to_palette() -> int:
	if mixing_mode != MODE_CLASSIC:
		return 0
	end_all_touches()
	var before: Image = canvas.get_image_copy()
	var data: PackedByteArray = before.get_data()
	var depth: int = classic_brush.depth
	var cache: Dictionary[int, int] = {}   # 0xRRGGBB -> nearest mix as 0xRRGGBB
	var changed: int = 0
	for i: int in range(0, data.size(), 4):
		if data[i + 3] == 0:
			continue
		var key: int = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2]
		if not cache.has(key):
			var m: Color = BrushLoad.nearest_mix(Color8(data[i], data[i + 1], data[i + 2]), depth)
			cache[key] = (m.r8 << 16) | (m.g8 << 8) | m.b8
		var snapped: int = cache[key]
		if snapped == key and data[i + 3] == 255:
			continue
		data[i] = (snapped >> 16) & 0xFF
		data[i + 1] = (snapped >> 8) & 0xFF
		data[i + 2] = snapped & 0xFF
		data[i + 3] = 255
		changed += 1
	if changed == 0:
		return 0
	var after: Image = Image.create_from_data(before.get_width(), before.get_height(), false,
			Image.FORMAT_RGBA8, data)
	canvas.set_image(after, canvas.level)   # stores a copy, so the step may keep after
	history.add_snapshot_action("Snap to palette", before, after, canvas.level, canvas.level)
	edited.emit()
	return changed


## A new empty document. Clears the history (not an undo step).
func new_canvas(cols: int = CanvasModel.BASE_COLS, rows: int = CanvasModel.BASE_ROWS) -> void:
	end_all_touches()
	canvas.set_image(Image.create_empty(maxi(1, cols), maxi(1, rows), false, Image.FORMAT_RGBA8), 0)
	history.clear_history()
	canvas_replaced.emit()


## Opens [param img] (a copy is stored). Clears the history (not an undo step).
func load_image(img: Image, p_level: int = 0) -> void:
	end_all_touches()
	canvas.set_image(img, p_level)
	history.clear_history()
	canvas_replaced.emit()


## The cells that [param tool] changes at [param cell], not clipped to the canvas.
func footprint(tool: StringName, cell: Vector2i) -> Array[Vector2i]:
	return CanvasModel.square_cells(cell, footprint_size(tool))


## The rect of footprint(), not clipped to the canvas.
func footprint_rect(tool: StringName, cell: Vector2i) -> Rect2i:
	return CanvasModel.square_rect(cell, footprint_size(tool))


## The footprint side in current cells: brush_size for the brush, sponge_size * 2^level for the
## sponge.
func footprint_size(tool: StringName) -> int:
	if tool == SPONGE:
		return sponge_size << canvas.level
	if tool == PENCIL:
		return 1
	return brush_size


# Writes [param color] into the footprint at [param center] and records each change. With the wet
# canvas, a brush cell that holds a different colour gets the spectral mix of both, once per
# entry of the cell into the footprint.
func _apply_footprint(tool: StringName, center: Vector2i, color: Color) -> int:
	var rect: Rect2i = CanvasModel.square_rect(center, footprint_size(tool))
	var x0: int = maxi(rect.position.x, 0)
	var y0: int = maxi(rect.position.y, 0)
	var x1: int = mini(rect.end.x, canvas.get_cols())
	var y1: int = mini(rect.end.y, canvas.get_rows())
	var wet: bool = tool == BRUSH and is_wet()
	var under: Dictionary = {}
	var changed: int = 0
	for y: int in range(y0, y1):
		for x: int in range(x0, x1):
			var c := Vector2i(x, y)
			var old: Color = canvas.get_cell(c)
			var new_color: Color = color
			if wet:
				under[c] = true
				if _wet_prev.has(c):
					continue
				if old.a8 != 0 and _rgb24(old) != _rgb24(color):
					new_color = _wet_mix(old, color)
			if canvas.set_cell(c, new_color):
				history.record(tool, c, old, new_color)
				changed += 1
	if wet:
		_wet_prev = under
	return changed


# The spectral 50/50 mix (strength 1 for both) of a cell colour and the brush colour, cached for
# the current brush colour.
func _wet_mix(cell: Color, brush_color: Color) -> Color:
	var b: int = _rgb24(brush_color)
	if b != _wet_cache_brush:
		_wet_cache.clear()
		_wet_cache_brush = b
	var key: int = _rgb24(cell)
	var hit: Variant = _wet_cache.get(key)
	if hit != null:
		return hit
	var cols: Array[Color] = [cell, brush_color]
	var mixed: Color = Spectral.mix(cols, PackedFloat64Array([0.5, 0.5]),
			PackedFloat64Array([1.0, 1.0]))
	_wet_cache[key] = mixed
	return mixed


# Names the brush colour after a dip and records a discovery (2.16).
func _discover() -> void:
	if not name_dips or brush.is_empty():
		return
	var c: Color = brush.color()
	var hit: Dictionary = ColorNames.nearest(c)
	if hit.is_empty():
		return
	var name: String = hit["name"]
	var distance: float = hit["distance"]
	brush_named.emit(name, distance)
	if distance < ColorNames.DISCOVER_DISTANCE and not journal.has(name):
		journal.add(name, String(hit["hex"]), "#" + c.to_html(false).to_upper())
		color_discovered.emit(name, hit["color"] as Color, c)


# A clean, normalised mixture from file data, or an empty array.
static func _valid_mixture(v: Variant) -> PackedFloat64Array:
	if not (v is Array) or (v as Array).size() != PigmentBrush.PIGMENT_COUNT:
		return PackedFloat64Array()
	var out := PackedFloat64Array()
	var sum: float = 0.0
	for x: Variant in v:
		if not (x is int or x is float) or not is_finite(float(x)) or float(x) < 0.0:
			return PackedFloat64Array()
		out.append(float(x))
		sum += float(x)
	if not (sum > 0.0):
		return PackedFloat64Array()
	for k: int in out.size():
		out[k] = out[k] / sum
	return out


static func _rgb24(c: Color) -> int:
	return (c.r8 << 16) | (c.g8 << 8) | c.b8


func _valid_tool(tool: StringName) -> bool:
	if tool == BRUSH or tool == SPONGE or tool == PENCIL:
		return true
	push_warning("PaintingPaintSession: unknown tool '%s'" % tool)
	return false


func _emit_applied(result: Dictionary, is_redo: bool) -> bool:
	if result.is_empty():
		return false
	history_applied.emit(String(result["name"]), result["rect"] as Rect2i, is_redo)
	edited.emit()
	return true


func _on_canvas_resized(cols: int, rows: int) -> void:
	canvas_resized.emit(cols, rows, canvas.level)


func _on_brush_changed(source: BrushLoad) -> void:
	if source != brush:
		return
	var c: Color = brush.color()
	brush_changed.emit(c, brush.loads(), brush.depth)
	if brush == pigment_brush:
		brush_mix_changed.emit(c, pigment_brush.amounts())


func _on_history_changed(can_undo: bool, can_redo: bool) -> void:
	history_changed.emit(can_undo, can_redo)
