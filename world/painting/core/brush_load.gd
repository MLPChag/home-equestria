extends RefCounted
## The brush load model (docs/DESIGN.md 2.2). A FIFO queue of up to [member depth] base colours.
## The brush colour is the per-channel mean of the loads in 8-bit sRGB integers, rounded half up:
## c = (sum + n / 2) / n with integer division. Pure logic, no Node dependency.

enum Base { WHITE, BLACK, RED, YELLOW, GREEN, BLUE }

## Indexed by [enum Base]. All channels are 0 or 255, so these values are exact.
const BASE_RGB: Array[Color] = [
	Color(1, 1, 1), Color(0, 0, 0), Color(1, 0, 0),
	Color(1, 1, 0), Color(0, 1, 0), Color(0, 0, 1),
]
const BASE_NAMES: PackedStringArray = ["white", "black", "red", "yellow", "green", "blue"]
const MIN_DEPTH := 1
const MAX_DEPTH := 8
## The default mix depth is 5.
const DEFAULT_DEPTH := 5
const EMPTY := Color(0, 0, 0, 0)

## 8-bit channels of BASE_RGB, for the integer mean.
const _BASE_R: PackedInt32Array = [255, 0, 255, 255, 0, 0]
const _BASE_G: PackedInt32Array = [255, 0, 0, 255, 255, 0]
const _BASE_B: PackedInt32Array = [255, 0, 0, 0, 0, 255]

## Emitted when the loads or the depth change.
signal changed

## The mix depth N. The setter clamps to MIN_DEPTH..MAX_DEPTH. Shrinking drops the oldest loads.
var depth: int:
	set = set_depth

## Cache of all_mixes() per depth (the set never changes).
static var _mix_cache: Dictionary = {}

var _loads: PackedInt32Array = PackedInt32Array()


## A new brush is empty.
func _init(p_depth: int = DEFAULT_DEPTH) -> void:
	set_depth(p_depth)


func set_depth(d: int) -> void:
	var clamped: int = clampi(d, MIN_DEPTH, MAX_DEPTH)
	var dropped: bool = false
	while _loads.size() > clamped:
		_loads.remove_at(0)
		dropped = true
	if clamped == depth and not dropped:
		return
	depth = clamped
	changed.emit()


## Pushes one load of [param base] at the end of the queue. Pops the oldest load while the queue
## holds more than [member depth] loads. An invalid base is ignored.
func dip(base: int) -> void:
	if base < 0 or base >= BASE_RGB.size():
		push_warning("PaintingBrushLoad.dip: invalid base %d" % base)
		return
	_loads.push_back(base)
	while _loads.size() > depth:
		_loads.remove_at(0)
	changed.emit()


## Empties the brush.
func rinse() -> void:
	_loads.clear()
	changed.emit()


func is_empty() -> bool:
	return _loads.is_empty()


func is_full() -> bool:
	return _loads.size() >= depth


func load_count() -> int:
	return _loads.size()


## A copy of the loads, oldest first.
func loads() -> PackedInt32Array:
	return _loads.duplicate()


## EMPTY when the brush is empty, else mix(loads()).
func color() -> Color:
	if _loads.is_empty():
		return EMPTY
	return mix(_loads)


## sRGB integer mean of the bases, rounded half up, alpha 1. EMPTY for an empty array.
@warning_ignore("integer_division")
static func mix(bases: PackedInt32Array) -> Color:
	var n: int = 0
	var r: int = 0
	var g: int = 0
	var b: int = 0
	for base: int in bases:
		if base < 0 or base >= _BASE_R.size():
			continue
		r += _BASE_R[base]
		g += _BASE_G[base]
		b += _BASE_B[base]
		n += 1
	if n == 0:
		return EMPTY
	var half: int = n / 2
	return _color8((r + half) / n, (g + half) / n, (b + half) / n)


## The distinct colours of all full brushes at [param p_depth] (multisets of size p_depth over
## the 6 bases), in a fixed order. Sizes: 44, 85, 146, 231 for N = 3, 4, 5, 6.
static func all_mixes(p_depth: int) -> PackedColorArray:
	return _mixes(p_depth).duplicate()


## The full-brush mix at [param p_depth] nearest to [param c] (sRGB Euclidean distance on 8-bit
## channels; the first of equal distances wins). Alpha is 1.
static func nearest_mix(c: Color, p_depth: int) -> Color:
	var r: int = c.r8
	var g: int = c.g8
	var b: int = c.b8
	var best: Color = EMPTY
	var best_d: int = 0x7FFFFFFF
	for m: Color in _mixes(p_depth):
		var dr: int = m.r8 - r
		var dg: int = m.g8 - g
		var db: int = m.b8 - b
		var dist: int = dr * dr + dg * dg + db * db
		if dist < best_d:
			best_d = dist
			best = m
			if dist == 0:
				break
	return best


# The cached mix list for a depth. Callers inside this script must not change it.
static func _mixes(p_depth: int) -> PackedColorArray:
	var d: int = clampi(p_depth, MIN_DEPTH, MAX_DEPTH)
	if not _mix_cache.has(d):
		var seen: Dictionary = {}   # rgba32 -> Color; keeps the insertion order
		var combo: Array[int] = []
		combo.resize(d)
		_collect_mixes(combo, 0, 0, seen)
		_mix_cache[d] = PackedColorArray(seen.values())
	return _mix_cache[d]


# Non-decreasing combinations with repetition: combo[i] >= combo[i - 1]. Arrays and
# Dictionaries are references, so the leaves write into the caller's [param seen].
static func _collect_mixes(combo: Array[int], pos: int, start: int, seen: Dictionary) -> void:
	if pos == combo.size():
		var c: Color = mix(PackedInt32Array(combo))
		var key: int = c.to_rgba32()
		if not seen.has(key):
			seen[key] = c
		return
	for base: int in range(start, BASE_RGB.size()):
		combo[pos] = base
		_collect_mixes(combo, pos + 1, base, seen)


static func _color8(r: int, g: int, b: int) -> Color:
	return Color(r / 255.0, g / 255.0, b / 255.0, 1.0)
