extends RefCounted
## Colour names for discovery (docs/DESIGN.md 2.16). data/colornames.json is color-name-list
## 14.51.0 "best of" (David Aerne / meodai, MIT): 4961 entries, hex without '#' -> name.
## nearest() finds the named colour nearest to a colour in OKLab, with the same OKLab as the
## Mixing Lab (spectral.js new Color(hex).OKLab, through the reflectance spectrum).
##
## The table loads lazily on the first nearest() call (or warm_up()). The OKLab values are kept
## sorted by L, so nearest() scans outward from the L of the query and stops when the L gap alone
## is larger than the best distance found. Pure static logic, no Node dependency.

const Spectral := preload("res://world/painting/core/spectral.gd")

const DATA_PATH := "res://world/painting/core/colornames.json"
## Closer than this to a named colour: the brush colour has that name (discovered).
const DISCOVER_DISTANCE := 0.022
## Closer than this: "very close".
const CLOSE_DISTANCE := 0.044

static var _loaded_path: String = ""
static var _names: PackedStringArray = PackedStringArray()   # sorted by L
static var _rgb: PackedInt32Array = PackedInt32Array()        # 0xRRGGBB, sorted by L
static var _order: PackedInt32Array = PackedInt32Array()      # index in the JSON file
static var _l: PackedFloat64Array = PackedFloat64Array()
static var _a: PackedFloat64Array = PackedFloat64Array()
static var _b: PackedFloat64Array = PackedFloat64Array()


## The named colour nearest to [param c] in OKLab: {name: String, hex: String ("#RRGGBB"),
## color: Color, distance: float}. On equal distances the earlier entry of the file wins (as in
## the Mixing Lab). Empty Dictionary when the table cannot load.
static func nearest(c: Color) -> Dictionary:
	if not _ensure_loaded():
		return {}
	var q: PackedFloat64Array = Spectral.to_oklab64(c)
	var n: int = _l.size()
	var start: int = _lower_bound(q[0])
	var best: int = -1
	var best_d2: float = INF
	var lo: int = start - 1
	var hi: int = start
	while lo >= 0 or hi < n:
		var lo_gap: float = q[0] - _l[lo] if lo >= 0 else INF
		var hi_gap: float = _l[hi] - q[0] if hi < n else INF
		var i: int
		if lo_gap <= hi_gap:
			if lo_gap * lo_gap > best_d2:
				break
			i = lo
			lo -= 1
		else:
			if hi_gap * hi_gap > best_d2:
				break
			i = hi
			hi += 1
		var dl: float = _l[i] - q[0]
		var da: float = _a[i] - q[1]
		var db: float = _b[i] - q[2]
		var d2: float = dl * dl + da * da + db * db
		if d2 < best_d2 or (best >= 0 and d2 == best_d2 and _order[i] < _order[best]):
			best_d2 = d2
			best = i
	if best < 0:
		return {}
	var rgb: int = _rgb[best]
	var named := Color8((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
	return {
		"name": _names[best],
		"hex": "#" + named.to_html(false).to_upper(),
		"color": named,
		"distance": sqrt(best_d2),
	}


## The number of named colours (0 when the table cannot load).
static func count() -> int:
	return _l.size() if _ensure_loaded() else 0


## Loads the table now (call it at boot to keep the first dip smooth). True when loaded.
static func warm_up() -> bool:
	return _ensure_loaded()


## Loads [param path] instead of DATA_PATH (tests). Returns true when it holds at least one entry.
static func load_from(path: String) -> bool:
	_names = PackedStringArray()
	_rgb = PackedInt32Array()
	_order = PackedInt32Array()
	_l = PackedFloat64Array()
	_a = PackedFloat64Array()
	_b = PackedFloat64Array()
	_loaded_path = path
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("PaintingColorNames: cannot read %s (error %d)" % [path, FileAccess.get_open_error()])
		return false
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		push_error("PaintingColorNames: %s does not hold a JSON object" % path)
		return false
	var rows: Array = []   # [L, a, b, rgb, name, order]
	var order: int = 0
	var dict: Dictionary = data
	for key: Variant in dict:
		var hex: String = str(key).trim_prefix("#")
		if hex.length() != 6 or not hex.is_valid_hex_number():
			continue
		var rgb: int = hex.hex_to_int()
		var lab: PackedFloat64Array = Spectral.to_oklab64(
				Color8((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF))
		rows.append([lab[0], lab[1], lab[2], rgb, str(dict[key]), order])
		order += 1
	rows.sort_custom(func(x: Array, y: Array) -> bool:
		return x[0] < y[0] or (x[0] == y[0] and x[5] < y[5]))
	for row: Array in rows:
		_l.append(row[0])
		_a.append(row[1])
		_b.append(row[2])
		_rgb.append(row[3])
		_names.append(row[4])
		_order.append(row[5])
	return not _l.is_empty()


static func _ensure_loaded() -> bool:
	if _loaded_path == "":
		load_from(DATA_PATH)
	return not _l.is_empty()


# The first index whose L is >= [param l].
static func _lower_bound(l: float) -> int:
	var lo: int = 0
	var hi: int = _l.size()
	while lo < hi:
		@warning_ignore("integer_division")
		var mid: int = (lo + hi) / 2
		if _l[mid] < l:
			lo = mid + 1
		else:
			hi = mid
	return lo
