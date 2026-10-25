extends VBoxContainer
## Settings → Controls map (dev 2026-10-24: "how old games used to do it, with pictures of the
## controllers ... diagrams that point to each button with like wires"). Real photographs
## (world/ui/controls_map/*.jpg, public domain, credited in world/ui/credits/notices.json) with a
## labelled callout wire to every key or button. Keyboard callouts follow Settings bindings, so a
## rebound key moves its wire to the new key on the photo. Drawn in _draw() so the VR settings
## panel (a SubViewport) shows it the same as the desktop pages.

const KEYBOARD := preload("res://world/ui/controls_map/keyboard.jpg")
const MOUSE := preload("res://world/ui/controls_map/mouse.jpg")
const TOUCH := preload("res://world/ui/controls_map/touch_controllers.jpg")
const VIEWS := ["Keyboard", "Mouse", "VR controllers"]
const WIRE := Color(1.0, 0.83, 0.42)
const BOX := Color(0.06, 0.07, 0.09, 0.92)
const BOX_EDGE := Color(1.0, 0.83, 0.42, 0.55)
const TEXT := Color(0.95, 0.95, 0.92)
const KEY_TEXT := Color(1.0, 0.86, 0.5)

## Key centres on keyboard.jpg (1800 x 755 px), measured on the photo.
const KEY_IMAGE := Vector2(1800, 755)
## The part of each photo shown (source pixels): the keyboard's main block (no arrows, numeric pad or case
## border), the mouse alone (its USB receiver is painted out of mouse.jpg), the controllers without the white margins.
const KEY_CROP := Rect2(105, 145, 1050, 530)
const KEY_POS := {
	KEY_ESCAPE: Vector2(195, 192), KEY_F1: Vector2(325, 197), KEY_F2: Vector2(390, 197), KEY_F3: Vector2(455, 197),
	KEY_F4: Vector2(520, 197), KEY_F5: Vector2(625, 200), KEY_F6: Vector2(690, 200), KEY_F7: Vector2(755, 200),
	KEY_F8: Vector2(820, 200), KEY_F9: Vector2(918, 205), KEY_F10: Vector2(985, 205), KEY_F11: Vector2(1050, 207),
	KEY_F12: Vector2(1110, 208),
	KEY_QUOTELEFT: Vector2(190, 330), KEY_1: Vector2(248, 330), KEY_2: Vector2(312, 331), KEY_3: Vector2(378, 332),
	KEY_4: Vector2(444, 333), KEY_5: Vector2(510, 334), KEY_6: Vector2(577, 335), KEY_7: Vector2(644, 336),
	KEY_8: Vector2(711, 337), KEY_9: Vector2(777, 338), KEY_0: Vector2(844, 339), KEY_MINUS: Vector2(910, 340),
	KEY_EQUAL: Vector2(975, 340), KEY_BACKSPACE: Vector2(1080, 337),
	KEY_TAB: Vector2(195, 392), KEY_Q: Vector2(287, 397), KEY_W: Vector2(355, 398), KEY_E: Vector2(421, 399),
	KEY_R: Vector2(488, 400), KEY_T: Vector2(555, 400), KEY_Y: Vector2(621, 401), KEY_U: Vector2(688, 401),
	KEY_I: Vector2(753, 402), KEY_O: Vector2(821, 403), KEY_P: Vector2(887, 403), KEY_BRACKETLEFT: Vector2(950, 405),
	KEY_BRACKETRIGHT: Vector2(1015, 406), KEY_BACKSLASH: Vector2(1095, 408),
	KEY_CAPSLOCK: Vector2(190, 462), KEY_A: Vector2(298, 463), KEY_S: Vector2(365, 464), KEY_D: Vector2(432, 465),
	KEY_F: Vector2(500, 466), KEY_G: Vector2(568, 467), KEY_H: Vector2(636, 467), KEY_J: Vector2(703, 468),
	KEY_K: Vector2(771, 469), KEY_L: Vector2(837, 470), KEY_SEMICOLON: Vector2(902, 471), KEY_APOSTROPHE: Vector2(968, 472),
	KEY_ENTER: Vector2(1070, 470),
	KEY_SHIFT: Vector2(200, 527), KEY_Z: Vector2(325, 532), KEY_X: Vector2(393, 533), KEY_C: Vector2(462, 534),
	KEY_V: Vector2(530, 535), KEY_B: Vector2(600, 536), KEY_N: Vector2(668, 537), KEY_M: Vector2(735, 538),
	KEY_COMMA: Vector2(800, 540), KEY_PERIOD: Vector2(866, 541), KEY_SLASH: Vector2(932, 542),
	KEY_CTRL: Vector2(175, 605), KEY_ALT: Vector2(340, 600), KEY_SPACE: Vector2(635, 603),
	KEY_INSERT: Vector2(1205, 338), KEY_HOME: Vector2(1270, 338), KEY_PAGEUP: Vector2(1335, 340),
	KEY_DELETE: Vector2(1205, 403), KEY_END: Vector2(1270, 403), KEY_PAGEDOWN: Vector2(1335, 405),
	KEY_UP: Vector2(1270, 543), KEY_LEFT: Vector2(1205, 607), KEY_DOWN: Vector2(1272, 610), KEY_RIGHT: Vector2(1340, 607),
}

## Keyboard callouts: [text, keys, side]. A key is a Settings action name (String: follows its
## binding) or a fixed keycode (int). Several keys fan several wires out of one label.
const KEYBOARD_CALLOUTS := [
	["Pause", [KEY_ESCAPE], "top"],
	["Quick save", [KEY_F5], "top"],
	["Saves", [KEY_F6], "top"],
	["Settings", [KEY_F7], "top"],
	["Quick load", [KEY_F8], "top"],
	["Quick slots", [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5], "left"],
	["Get up · stay awake", ["stand_up"], "left"],
	["Move", ["move_forward", "move_left", "move_back", "move_right"], "left"],
	["Use · hold hoof", [KEY_E], "left"],
	["Follow me / stop", [KEY_R], "left"],
	["Push to talk", ["voice_talk"], "left"],
	["Companion pace", [KEY_CAPSLOCK], "left"],
	["Sprint", ["move_sprint"], "left"],
	["Clothes", [KEY_U], "right"],
	["Briefcase", [KEY_I], "right"],
	["Fly (wings, sandals)", [KEY_F], "right"],
	["Pick up · put down · throw", [KEY_G], "right"],
	["Hug (hold)", [KEY_H], "right"],
	["Inspect a pony", [KEY_J], "right"],
	["Kiss (hold)", [KEY_K], "right"],
	["Turn carried pony", ["carry_turn"], "bottom"],
	["Map", [KEY_M], "bottom"],
	["Crouch · pony walk", [KEY_CTRL], "bottom"],
	["Walk (tap toggles)", ["move_walk"], "bottom"],
	["Sit (pony)", [KEY_Z], "bottom"],
	["Lie down (pony)", [KEY_X], "bottom"],
	["Cuddle", [KEY_C], "bottom"],
	["Jump · fly up · flap", ["move_jump"], "bottom"],
]

const MOUSE_IMAGE := Vector2(1000, 615)
const MOUSE_CROP := Rect2(20, 10, 660, 595)
const MOUSE_CALLOUTS := [
	["Left button · use, open, boop; hold to stroke; bank left in flight", [Vector2(300, 345)], "right"],
	["Right button · bank right in flight", [Vector2(140, 262)], "left"],
	["Wheel · choose your wake time", [Vector2(198, 352)], "left"],
	["Move the mouse · look around", [Vector2(430, 300)], "right"],
]

const TOUCH_IMAGE := Vector2(1600, 948)
const TOUCH_CROP := Rect2(110, 95, 1390, 760)
const TOUCH_CALLOUTS := [
	["Menu · settings", [Vector2(440, 356)], "left"],
	["Left stick · move (double-tap forward to run); click · map", [Vector2(442, 245)], "left"],
	["X · kiss", [Vector2(522, 322)], "top"],
	["Trigger · point and use", [Vector2(470, 418)], "left"],
	["Grip · grab (with trigger: pick up a pony)", [Vector2(545, 520), Vector2(1075, 520)], "bottom"],
	["B · hold to talk; tap to get up or land", [Vector2(1045, 270)], "top"],
	["A · jump, flap; hold in bed to sleep", [Vector2(1090, 322)], "right"],
	["Right stick · turn; click · companion pace", [Vector2(1160, 245)], "right"],
	["Trigger · point and use", [Vector2(1130, 418)], "right"],
]
const TOUCH_NOTE := "Turn your left hand palm up for its buttons, your right for the quick slots."

var font_size := 18
var redraw := Callable()
var _view := 0
var _tabs: Array[Button] = []
var _canvas: Control
var controls: Array = []

func setup(text_size: int, on_redraw := Callable()) -> void:
	font_size = text_size; redraw = on_redraw
	add_theme_constant_override("separation", 6)
	var bar := HBoxContainer.new(); bar.add_theme_constant_override("separation", 6); add_child(bar)
	for i in VIEWS.size():
		var b := Button.new(); b.text = VIEWS[i]; b.toggle_mode = true
		b.custom_minimum_size = Vector2(text_size * 6, text_size * 1.9)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", text_size)
		b.pressed.connect(show_view.bind(i))
		bar.add_child(b); _tabs.append(b)
	controls = _tabs.duplicate()
	_canvas = Control.new(); _canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_map); _canvas.resized.connect(_canvas.queue_redraw)
	add_child(_canvas)
	if not Settings.changed.is_connected(_on_settings): Settings.changed.connect(_on_settings)
	show_view(0)

func open() -> void:
	show(); _canvas.queue_redraw(); _changed()

func show_view(index: int) -> void:
	_view = index
	for i in _tabs.size(): _tabs[i].set_pressed_no_signal(i == index)
	_canvas.queue_redraw(); _changed()

func view_name() -> String:
	return VIEWS[_view]

func _on_settings(key: String) -> void:
	if key.begins_with("bind:") and is_instance_valid(_canvas): _canvas.queue_redraw(); _changed()

func _changed() -> void:
	if redraw.is_valid(): redraw.call()

# ------------------------------------------------------------------ resolving callouts
## [label text, targets in image pixels] for the current view.
func callouts() -> Array:
	var out: Array = []
	match _view:
		0:
			for entry: Array in KEYBOARD_CALLOUTS:
				var names: Array = []
				var points: Array = []
				for key: Variant in entry[1]:
					var code: int = Settings.binding(key) if key is String else int(key)
					if code == 0: continue
					if not names.has(Settings.key_name(code)): names.append(Settings.key_name(code))
					if KEY_POS.has(code): points.append(KEY_POS[code])
				var keys_text := "/".join(names) if names.size() <= 4 else "%s–%s" % [names[0], names[-1]]
				out.append(["%s · %s" % [keys_text if not keys_text.is_empty() else "unbound", entry[0]], points, entry[2]])
		1:
			for entry: Array in MOUSE_CALLOUTS: out.append([entry[0], entry[1], entry[2]])
		2:
			for entry: Array in TOUCH_CALLOUTS: out.append([entry[0], entry[1], entry[2]])
	return out

func _image() -> Texture2D:
	return [KEYBOARD, MOUSE, TOUCH][_view]

func _image_size() -> Vector2:
	return [KEY_IMAGE, MOUSE_IMAGE, TOUCH_IMAGE][_view]

# ------------------------------------------------------------------ drawing
func _crop() -> Rect2:
	return [KEY_CROP, MOUSE_CROP, TOUCH_CROP][_view]

## Words of `text` wrapped to `width`; the first line keeps the "KEY · " prefix.
func _wrap(text: String, width: float, font: Font, fs: int) -> PackedStringArray:
	var lines := PackedStringArray()
	var line := ""
	for word in text.split(" "):
		var trial := word if line.is_empty() else line + " " + word
		if not line.is_empty() and font.get_string_size(trial, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > width:
			lines.append(line); line = word
		else: line = trial
	if not line.is_empty(): lines.append(line)
	return lines

func _draw_map() -> void:
	var area := Rect2(Vector2.ZERO, _canvas.size)
	if area.size.x < 50 or area.size.y < 50: return
	var font := get_theme_default_font()
	var fs := clampi(int(area.size.y / 46.0), 11, maxi(11, font_size - 2))
	var text_h := fs * 1.25
	var pad := Vector2(fs * 0.55, fs * 0.35)
	var gap := fs * 0.45
	var items := callouts()
	# Measure every label, wrapped to its band's width.
	for item: Array in items:
		var limit: float = area.size.x * (0.24 if item[2] in ["left", "right"] else 0.2)
		var lines := _wrap(item[0], limit - pad.x * 2.0, font, fs)
		var w := 0.0
		for l in lines: w = maxf(w, font.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
		item.append(lines)                                                      # [3]
		item.append(Vector2(w + pad.x * 2.0, lines.size() * text_h + pad.y * 2.0))  # [4]
	var col := {"left": 0.0, "right": 0.0}
	for item: Array in items:
		if col.has(item[2]): col[item[2]] = maxf(col[item[2]], (item[4] as Vector2).x)
	var lead := fs * 1.4  # room for the wires' leads between labels and photo
	var inner_left: float = area.position.x + col.left + (lead if col.left > 0.0 else 0.0)
	var inner_right: float = area.end.x - col.right - (lead if col.right > 0.0 else 0.0)
	var band := {"top": _band_rows(items, "top", area.size.x, gap), "bottom": _band_rows(items, "bottom", area.size.x, gap)}
	var band_h := {}
	for side: String in band:
		var h := 0.0
		for row: Array in band[side]: h += _row_height(row) + gap
		band_h[side] = h + (lead if h > 0.0 else 0.0)
	var note_h := text_h + gap if _view == 2 else 0.0
	var photo_area := Rect2(Vector2(inner_left, area.position.y + band_h.top), Vector2(inner_right - inner_left, area.size.y - band_h.top - band_h.bottom - note_h))
	var crop := _crop()
	var scale := minf(photo_area.size.x / crop.size.x, photo_area.size.y / crop.size.y)
	var photo := Rect2(photo_area.position + (photo_area.size - crop.size * scale) * 0.5, crop.size * scale)
	_canvas.draw_texture_rect_region(_image(), photo, crop)
	_canvas.draw_rect(photo, Color(1, 1, 1, 0.22), false, 1.0)
	for item: Array in items:
		var pts: Array = (item[1] as Array).map(func(p: Vector2) -> Vector2: return photo.position + (p - crop.position) * scale)
		item.append(pts)                                   # [5]
		item.append(_centre(pts, photo))                   # [6]
	var boxes: Array = []  # [rect, lines, anchor, targets]
	# Each side column keeps its labels level with their keys and each top/bottom row keeps them
	# over/under theirs, pushed apart and slid back inside. Then the order within each group is
	# reshuffled while that removes wire crossings, counting the other groups' wires too.
	# The top and bottom rows hug the photo, which sits well inside its area when the side columns
	# limit its width; the side columns fit between them.
	var band_y := {
		"top": maxf(area.position.y, photo.position.y - band_h.top),
		"bottom": minf(area.end.y - band_h.bottom - note_h + lead, photo.end.y + lead),
	}
	var col_top: float = band_y.top + band_h.top - lead + gap if band_h.top > 0.0 else area.position.y
	var col_floor: float = band_y.bottom - lead if band_h.bottom > 0.0 else area.end.y - note_h
	var groups: Array = []  # [items in order, layout callable]
	for side: String in ["left", "right"]:
		var group: Array = items.filter(func(i: Array) -> bool: return i[2] == side)
		group.sort_custom(func(a: Array, b: Array) -> bool: return a[6].y < b[6].y)
		groups.append([group, func(order: Array) -> Array: return _column_boxes(order, side, area, col_top, col_floor, gap)])
	for side: String in ["top", "bottom"]:
		var y: float = band_y[side]
		for row: Array in band[side]:
			row.sort_custom(func(a: Array, b: Array) -> bool: return a[6].x < b[6].x)
			var row_y := y
			groups.append([row, func(order: Array) -> Array: return _row_boxes(order, side, row_y, area, gap)])
			y += _row_height(row) + gap
	var placed: Array = []
	for g: Array in groups: placed.append((g[1] as Callable).call(g[0]))
	for round in 3:
		var changed := false
		for gi in groups.size():
			var others: Array = []
			for gj in groups.size():
				if gj != gi: others.append_array(placed[gj])
			var result: Array = _untangle(groups[gi][0], groups[gi][1], others)
			if result[0] != groups[gi][0]:
				changed = true
				groups[gi][0] = result[0]
			placed[gi] = result[1]
		if not changed: break
	for g_boxes: Array in placed: boxes.append_array(g_boxes)
	for box: Array in boxes:
		for target: Vector2 in box[3]: _wire(box[2], target, box[0])
	for box: Array in boxes: _label(box[0], box[1], font, fs, text_h, pad)
	if _view == 2:
		_canvas.draw_string(font, Vector2(area.position.x, area.end.y - fs * 0.3), TOUCH_NOTE, HORIZONTAL_ALIGNMENT_CENTER, area.size.x, fs, Color(TEXT, 0.8))

## Boxes for a column of labels in `order`: each wants to sit level with its target, pushed down
## below the one above it, then slid back up above the floor.
func _column_boxes(order: Array, side: String, area: Rect2, top: float, floor_y: float, gap: float) -> Array:
	var ys: Array = []
	for i in order.size():
		var h: float = (order[i][4] as Vector2).y
		var want: float = (order[i][6] as Vector2).y - h * 0.5
		ys.append(maxf(want, top if i == 0 else float(ys[i - 1]) + (order[i - 1][4] as Vector2).y + gap))
	for i in range(order.size() - 1, -1, -1):
		var h: float = (order[i][4] as Vector2).y
		var limit: float = floor_y - h if i == order.size() - 1 else float(ys[i + 1]) - h - gap
		ys[i] = maxf(area.position.y, minf(float(ys[i]), limit))
	var out: Array = []
	for i in order.size():
		var size: Vector2 = order[i][4]
		var rect := Rect2(Vector2(area.position.x if side == "left" else area.end.x - size.x, ys[i]), size)
		out.append([rect, order[i][3], Vector2(rect.end.x if side == "left" else rect.position.x, rect.get_center().y), order[i][5]])
	return out

## Boxes for one top/bottom row of labels in `order`, the same push-apart and slide-back across.
func _row_boxes(order: Array, side: String, y: float, area: Rect2, gap: float) -> Array:
	var xs: Array = []
	for k in order.size():
		var w: float = (order[k][4] as Vector2).x
		xs.append(maxf((order[k][6] as Vector2).x - w * 0.5, area.position.x if k == 0 else float(xs[k - 1]) + (order[k - 1][4] as Vector2).x + gap))
	for k in range(order.size() - 1, -1, -1):
		var w: float = (order[k][4] as Vector2).x
		var limit: float = area.end.x - w if k == order.size() - 1 else float(xs[k + 1]) - w - gap
		xs[k] = maxf(area.position.x, minf(float(xs[k]), limit))
	var row_h := _row_height(order)
	var out: Array = []
	for k in order.size():
		var size: Vector2 = order[k][4]
		var rect := Rect2(Vector2(xs[k], y + (row_h - size.y if side == "top" else 0.0)), size)
		out.append([rect, order[k][3], Vector2(rect.get_center().x, rect.end.y if side == "top" else rect.position.y), order[k][5]])
	return out

## Lays `group` out with `layout` and swaps pairs of labels while that lowers the wire crossings
## (among its own wires and against `others`). Returns [order, boxes].
func _untangle(group: Array, layout: Callable, others: Array) -> Array:
	var order := group.duplicate()
	var boxes: Array = layout.call(order)
	var best := _crossings(boxes, others)
	var improved := best > 0
	var passes := 0
	while improved and passes < 12:
		improved = false
		passes += 1
		for i in order.size():
			for j in range(i + 1, order.size()):
				var trial := order.duplicate()
				var swap: Variant = trial[i]
				trial[i] = trial[j]
				trial[j] = swap
				var trial_boxes: Array = layout.call(trial)
				var count := _crossings(trial_boxes, others)
				if count < best:
					best = count; order = trial; boxes = trial_boxes; improved = true
		if best == 0: break
	return [order, boxes]

const DOT_CLEARANCE := 11.0

## Number of crossings of the wires of `boxes` (label anchor to key, as drawn) with each other
## and with the wires of `others`.
func _crossings(boxes: Array, others: Array = []) -> int:
	var paths: Array = []  # [box index, path]; boxes from `others` get negative indices
	for i in boxes.size():
		for target: Vector2 in boxes[i][3]: paths.append([i, _wire_path(boxes[i][2], target, boxes[i][0])])
	var own := paths.size()
	for i in others.size():
		for target: Vector2 in others[i][3]: paths.append([-1 - i, _wire_path(others[i][2], target, others[i][0])])
	var count := 0
	for m in own:
		for n in range(m + 1, paths.size()):
			if paths[m][0] == paths[n][0]: continue
			var a: PackedVector2Array = paths[m][1]
			var b: PackedVector2Array = paths[n][1]
			for s in a.size() - 1:
				for u in b.size() - 1:
					if Geometry2D.segment_intersects_segment(a[s], a[s + 1], b[u], b[u + 1]) != null: count += 1
	# A wire running over another key's dot reads as wired to it: count that like two crossings.
	for m in paths.size():
		var key: Vector2 = paths[m][1][-1]
		for n in own:
			if paths[m][0] == paths[n][0]: continue
			var path: PackedVector2Array = paths[n][1]
			for s in path.size() - 1:
				if Geometry2D.get_closest_point_to_segment(key, path[s], path[s + 1]).distance_to(key) < DOT_CLEARANCE:
					count += 2
					break
	return count

## Labels of one band split into rows that fit `width`, in target order.
func _band_rows(items: Array, side: String, width: float, gap: float) -> Array:
	var group: Array = items.filter(func(i: Array) -> bool: return i[2] == side)
	if group.is_empty(): return []
	var rows: Array = [[]]
	var used := 0.0
	for item: Array in group:
		var w: float = (item[4] as Vector2).x + gap
		if used + w > width and not rows[-1].is_empty():
			rows.append([]); used = 0.0
		rows[-1].append(item); used += w
	return rows

func _row_height(row: Array) -> float:
	var h := 0.0
	for item: Array in row: h = maxf(h, (item[4] as Vector2).y)
	return h

func _label(rect: Rect2, lines: PackedStringArray, font: Font, fs: int, text_h: float, pad: Vector2) -> void:
	_canvas.draw_rect(rect, BOX, true)
	_canvas.draw_rect(rect, BOX_EDGE, false, 1.0)
	for i in lines.size():
		var pos := rect.position + Vector2(pad.x, pad.y + text_h * i + fs * 0.98)
		var line: String = lines[i]
		var split := line.find(" · ") if i == 0 else -1
		if split > 0:
			var key_part := line.substr(0, split)
			_canvas.draw_string(font, pos, key_part, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, KEY_TEXT)
			var kx := font.get_string_size(key_part, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			_canvas.draw_string(font, pos + Vector2(kx, 0), " · ", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(TEXT, 0.55))
			var dx := font.get_string_size(key_part + " · ", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			_canvas.draw_string(font, pos + Vector2(dx, 0), line.substr(split + 3), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, TEXT)
		else:
			_canvas.draw_string(font, pos, line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, TEXT)

## Average of a callout's targets, or the photo centre when its key is not on the photo.
func _centre(points: Array, photo: Rect2) -> Vector2:
	if points.is_empty(): return photo.get_center()
	var sum := Vector2.ZERO
	for p: Vector2 in points: sum += p
	return sum / points.size()

## The wire from a label to its key, like an old manual's leader line: straight out of the label,
## then one 45-degree bend onto the key (straight across when the key is too close for a bend).
func _wire_path(from: Vector2, to: Vector2, rect: Rect2) -> PackedVector2Array:
	var path := PackedVector2Array([from])
	if is_equal_approx(from.x, rect.end.x) or is_equal_approx(from.x, rect.position.x):
		var dir := 1.0 if is_equal_approx(from.x, rect.end.x) else -1.0
		var lead := from + Vector2(10.0 * dir, 0)
		path.append(lead)
		var bend := Vector2(to.x - dir * absf(to.y - from.y), from.y)
		if (bend.x - lead.x) * dir > 0.0: path.append(bend)
	else:
		var dir := 1.0 if is_equal_approx(from.y, rect.end.y) else -1.0
		var lead := from + Vector2(0, 8.0 * dir)
		path.append(lead)
		var bend := Vector2(from.x, to.y - dir * absf(to.x - from.x))
		if (bend.y - lead.y) * dir > 0.0: path.append(bend)
	path.append(to)
	return path

func _wire(from: Vector2, to: Vector2, rect: Rect2) -> void:
	var path := _wire_path(from, to, rect)
	var shadow := Color(0, 0, 0, 0.6)
	_canvas.draw_polyline(path, shadow, 3.4, true)
	_canvas.draw_polyline(path, WIRE, 1.6, true)
	_canvas.draw_circle(to, 5.0, shadow)
	_canvas.draw_circle(to, 3.4, WIRE)
	_canvas.draw_arc(to, 8.0, 0.0, TAU, 20, Color(WIRE, 0.8), 1.4, true)
	_canvas.draw_circle(from, 2.4, WIRE)
