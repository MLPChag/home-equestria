extends "res://world/painting/core/brush_load.gd"
## The paint-reservoir brush of Mixing v2 (docs/DESIGN.md 2.16), palette "Easel 10".
## Reference: dip(), dipMixture() and brushHex() of docs/reference/mixlab/index.html.
##
## The brush holds an amount a[i] >= 0 of each pigment, sum <= 1.
## - Dip into pigment i (d = DIP_AMOUNT, or LIGHT_AMOUNT for a light touch): every a[k] *= 1 - d,
##   then a[i] += d. Afterwards every pigment whose share a[k] / sum < CLEANUP_SHARE is dropped.
## - Load-up: the LOAD_UP_RUN-th dip in a row into the same source (a pigment, or a well key)
##   sets the brush to that source only, at full strength (no cleanup). Another source or a rinse
##   resets the run. Light touches count as dips.
## - The colour is the spectral mix (PaintingSpectral) of the pigments with amount > MIN_PART, with
##   factor a[k] and the pigment tinting strength; one pigment alone is its own colour.
## - Painting never uses paint up. rinse() empties the brush.
##
## It extends PaintingBrushLoad only for the interface that scenes use (signal changed, dip, rinse,
## is_empty, is_full, load_count, loads, color, depth), so PaintingPaintSession.brush can hold either
## brush with one static type. The inherited classic constants (BASE_RGB, BASE_NAMES, Base) and
## the static PaintingBrushLoad.mix() describe the classic palette, not this one: use the PIGMENT_*
## constants. Pure logic, no Node dependency.

const Spectral := preload("res://world/painting/core/spectral.gd")

const PALETTE_NAME := "Easel 10"
const PIGMENT_COUNT := 10
## Visual order on the tray, left to right as the painter sees it (Paint_00 .. Paint_09).
const VISUAL_ORDER: PackedInt32Array = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
const PIGMENT_NAMES: PackedStringArray = ["Red", "Orange", "Yellow", "Green", "Teal", "Blue",
	"Purple", "Magenta", "Black", "White"]
const PIGMENT_HEX: PackedStringArray = [
	"#D4234A", "#F07A1A", "#FFD21F", "#2E9A3E", "#12938F", "#0E2F9A", "#6A2C91", "#D1338F",
	"#14161C", "#FFFFFF",
]
## 8-bit sRGB per pigment (the same values as PIGMENT_HEX).
const PIGMENT_RGB: Array[Color] = [
	Color(212.0 / 255.0, 35.0 / 255.0, 74.0 / 255.0),
	Color(240.0 / 255.0, 122.0 / 255.0, 26.0 / 255.0),
	Color(1.0, 210.0 / 255.0, 31.0 / 255.0),
	Color(46.0 / 255.0, 154.0 / 255.0, 62.0 / 255.0),
	Color(18.0 / 255.0, 147.0 / 255.0, 143.0 / 255.0),
	Color(14.0 / 255.0, 47.0 / 255.0, 154.0 / 255.0),
	Color(106.0 / 255.0, 44.0 / 255.0, 145.0 / 255.0),
	Color(209.0 / 255.0, 51.0 / 255.0, 143.0 / 255.0),
	Color(20.0 / 255.0, 22.0 / 255.0, 28.0 / 255.0),
	Color(1.0, 1.0, 1.0),
]
## Tinting strength per pigment (white is the strongest, so tints stay light).
const PIGMENT_STRENGTHS: PackedFloat64Array = [0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 1.0]

const DIP_AMOUNT := 0.35
const LIGHT_AMOUNT := 0.15
const LOAD_UP_RUN := 3
const CLEANUP_SHARE := 0.015
## Amounts at or below this do not take part in the colour (brushHex() of the lab).
const MIN_PART := 0.004
## is_full(): the sum of the amounts reaches this.
const FULL_SUM := 0.999
## loads() lists the pigments with at least this share.
const LOADSTRIP_SHARE := 0.1
const PIGMENT_KEY_PREFIX := "pigment"

var _a: PackedFloat64Array = PackedFloat64Array()
var _run_key: String = ""
var _run: int = 0
var _color: Color = EMPTY
var _color_dirty: bool = false


func _init() -> void:
	super()
	_a.resize(PIGMENT_COUNT)
	_a.fill(0.0)


## depth is kept for the PaintingBrushLoad interface (LoadStrip slot count): always PIGMENT_COUNT.
## The classic mix depth does not apply to this brush.
func set_depth(_d: int) -> void:
	depth = PIGMENT_COUNT


## Dips into pigment [param base] (0..PIGMENT_COUNT-1). [param light] = a light touch.
## An invalid index is ignored.
func dip(base: int, light: bool = false) -> void:
	if base < 0 or base >= PIGMENT_COUNT:
		push_warning("PaintingPigmentBrush.dip: invalid pigment %d" % base)
		return
	_advance_run(PIGMENT_KEY_PREFIX + str(base))
	if _run >= LOAD_UP_RUN:
		_a.fill(0.0)
		_a[base] = 1.0
	else:
		var d: float = LIGHT_AMOUNT if light else DIP_AMOUNT
		for k: int in PIGMENT_COUNT:
			_a[k] = _a[k] * (1.0 - d) + (d if k == base else 0.0)
		_cleanup()
	_touched()


## Dips into a stored mixture (a well): like a pigment dip, but it adds the normalised
## [param mixture] (PIGMENT_COUNT amounts). The load-up run counts per [param source_key]
## (for example "well0"; keys that start with PIGMENT_KEY_PREFIX belong to the pigments).
## Returns false (and changes nothing) for a wrong size or an empty mixture.
func dip_mixture(mixture: PackedFloat64Array, source_key: String, light: bool = false) -> bool:
	if mixture.size() != PIGMENT_COUNT:
		push_warning("PaintingPigmentBrush.dip_mixture: %d amounts, expected %d" % [
			mixture.size(), PIGMENT_COUNT])
		return false
	var m := PackedFloat64Array()
	m.resize(PIGMENT_COUNT)
	var sum: float = 0.0
	for k: int in PIGMENT_COUNT:
		var v: float = mixture[k]
		m[k] = v if (is_finite(v) and v > 0.0) else 0.0
		sum += m[k]
	if not (sum > 0.0):
		return false
	var total: float = maxf(1e-9, sum)
	_advance_run(source_key)
	if _run >= LOAD_UP_RUN:
		for k: int in PIGMENT_COUNT:
			_a[k] = m[k] / total
	else:
		var d: float = LIGHT_AMOUNT if light else DIP_AMOUNT
		for k: int in PIGMENT_COUNT:
			_a[k] = _a[k] * (1.0 - d) + m[k] / total * d
		_cleanup()
	_touched()
	return true


## Empties the brush and resets the load-up run.
func rinse() -> void:
	_a.fill(0.0)
	_run_key = ""
	_run = 0
	_touched()


## True when no pigment takes part in the colour (color() is EMPTY).
func is_empty() -> bool:
	for v: float in _a:
		if v > MIN_PART:
			return false
	return true


## The amounts sum to FULL_SUM or more (after a load-up, or many dips).
func is_full() -> bool:
	return total() >= FULL_SUM


## loads().size().
func load_count() -> int:
	return loads().size()


## For the classic LoadStrip: the pigments with a share of LOADSTRIP_SHARE or more, each once,
## the largest amount first (the lower index first on a tie).
func loads() -> PackedInt32Array:
	var t: float = total()
	var idx: Array[int] = []
	if t > 0.0:
		for k: int in PIGMENT_COUNT:
			if _a[k] / t >= LOADSTRIP_SHARE:
				idx.append(k)
	idx.sort_custom(func(x: int, y: int) -> bool:
		return _a[x] > _a[y] or (_a[x] == _a[y] and x < y))
	return PackedInt32Array(idx)


## EMPTY when empty, else mixture_color(amounts()). Cached until the amounts change.
func color() -> Color:
	if _color_dirty:
		_color = mixture_color(_a)
		_color_dirty = false
	return _color


## A copy of the amounts (PIGMENT_COUNT values, sum <= 1).
func amounts() -> PackedFloat64Array:
	return _a.duplicate()


## The sum of the amounts (0..1).
func total() -> float:
	var t: float = 0.0
	for v: float in _a:
		t += v
	return t


## The amounts divided by their sum (zeros for an empty brush). Wells store this.
func snapshot() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(PIGMENT_COUNT)
	out.fill(0.0)
	var t: float = total()
	if t > 0.0:
		for k: int in PIGMENT_COUNT:
			out[k] = _a[k] / t
	return out


## The pigment index when exactly one pigment takes part in the colour (the colour is then that
## pigment's colour, at any load); -1 when the brush is empty or mixed. With is_full() true it is
## the "fully loaded, pure" state of the Mixing Lab.
func pure_index() -> int:
	var found: int = -1
	for k: int in PIGMENT_COUNT:
		if _a[k] > MIN_PART:
			if found >= 0:
				return -1
			found = k
	return found


## Dips in a row into the same source so far (LOAD_UP_RUN loads up). 0 after a rinse.
func run_count() -> int:
	return _run


func pigment_count() -> int:
	return PIGMENT_COUNT


func pigment_color(i: int) -> Color:
	return PIGMENT_RGB[i] if i >= 0 and i < PIGMENT_COUNT else EMPTY


func pigment_name(i: int) -> String:
	return PIGMENT_NAMES[i] if i >= 0 and i < PIGMENT_COUNT else ""


## The colour of a mixture of the palette pigments ([param amounts]: PIGMENT_COUNT values,
## any scale). EMPTY when no amount is above MIN_PART; one pigment alone gives its own colour.
static func mixture_color(amounts: PackedFloat64Array) -> Color:
	var colors: Array[Color] = []
	var factors := PackedFloat64Array()
	var strengths := PackedFloat64Array()
	for k: int in mini(amounts.size(), PIGMENT_COUNT):
		if amounts[k] > MIN_PART:
			colors.append(PIGMENT_RGB[k])
			factors.append(amounts[k])
			strengths.append(PIGMENT_STRENGTHS[k])
	if colors.is_empty():
		return EMPTY
	if colors.size() == 1:
		return Color8(colors[0].r8, colors[0].g8, colors[0].b8)
	return Spectral.mix(colors, factors, strengths)


func _advance_run(key: String) -> void:
	_run = _run + 1 if key == _run_key else 1
	_run_key = key


# Drops the pigments whose share is below CLEANUP_SHARE (cleanup() of the lab).
func _cleanup() -> void:
	var t: float = total()
	if t == 0.0:
		return
	for k: int in PIGMENT_COUNT:
		if _a[k] / t < CLEANUP_SHARE:
			_a[k] = 0.0


func _touched() -> void:
	_color_dirty = true
	changed.emit()
