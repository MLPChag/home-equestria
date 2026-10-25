extends Control
## A 2D atlas with world-coordinate markers; never renders another 3D camera.
signal marker_selected(marker: Dictionary)
signal expand_requested
signal zoom_lock_changed(locked: bool)
const LOCAL_PLACES := preload("res://world/ui/named_map_places.gd")
const PLACE_FONT := preload("res://world/ui/fonts/CelestiaMediumRedux.ttf")
var _local_refresh_at := 0
const PONY_DATA := preload("res://world/ui/pony_map_data.gd")
const ATLAS := preload("res://docs/reference/equestria-map.jpg")
const AERIAL := preload("res://world/ui/aerial_map_layer.gd")
const INK := Color("142331")
const GOLD := Color("ffdc8c")
const CYAN := Color("73ecff")
const MAX_ZOOM := 6.0 # Close enough to display the 0.25 m aerial pixels in full.
var markers: Array = []
var pony_markers: Array = []
var pony_data := PONY_DATA.new()
var center := Vector2.ZERO
var zoom := 0.05
var zoom_locked := false
var preferences_path := "user://world_map.cfg"
var compact := true
var label_font_size := 13
var following := true
var live_position := Vector2.ZERO
var live_heading := Vector2.UP
var has_position := false
var selected_id := ""
var hovered_id := ""
## Controller pointer on the VR map (map pixels), (-1, -1) when off the map.
var cursor := Vector2(-1, -1)
var _dragging := false
var _press := Vector2.ZERO
var _drag_distance := 0.0
var _save_pending := false
var _save_delay := 0.0
var _aerial := AERIAL.new()
## Live updates (10 Hz) redraw only once something moved at least this far on the map: the
## mini map spans kilometres, so a walking pony or player shifts a tiny fraction of a pixel.
const REDRAW_PIXELS := 0.25
const MARKER_KEYS := ["id", "tracking", "coat", "name", "icon_id", "kind"]
var _drawn_ponies: Array = []
var _drawn_live := Vector2.INF
var _drawn_heading := Vector2.ZERO

func _ready() -> void:
	add_to_group("world_map_views")
	set_process(false)
	_load_preferences()
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_aerial.changed.connect(_aerial_changed)
	add_child(_aerial)
	mouse_filter = Control.MOUSE_FILTER_STOP
	for region in WorldLayout.regions():
		if region.get("phase"): continue
		markers.append({"id": str(region.id), "name": str(region.name), "kind": str(region.kind),
			"position": Vector2(float(region.center[0]), float(region.center[2]))})
	markers.append_array(LOCAL_PLACES.defaults())
	resized.connect(queue_redraw)
	mouse_exited.connect(func(): hovered_id = ""; queue_redraw())

## Activities publish only when availability changes; no aerial rebake or polling.
func set_activity_markers(owner_id: String, values: Array[Dictionary]) -> void:
	markers = markers.filter(func(marker: Dictionary): return marker.get("activity_owner", "") != owner_id)
	for value: Dictionary in values:
		var marker: Dictionary = value.duplicate(true)
		marker.activity_owner = owner_id
		markers.append(marker)
	if selected_id.begins_with("activity:") and selected_marker().is_empty(): selected_id = ""
	queue_redraw()

func _aerial_changed() -> void:
	if not is_visible_in_tree(): return
	queue_redraw()
	var viewport := get_viewport()
	if viewport is SubViewport and viewport.render_target_update_mode in [SubViewport.UPDATE_DISABLED, SubViewport.UPDATE_ONCE]:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _load_preferences() -> void:
	if preferences_path.is_empty(): return
	var config := ConfigFile.new()
	if config.load(preferences_path) != OK: return
	var locked: Variant = config.get_value("view", "keep_zoom", false)
	var saved: Variant = config.get_value("view", "zoom", zoom)
	if not locked is bool or not locked: return
	if not (saved is float or saved is int) or not is_finite(float(saved)) or float(saved) <= 0: return
	zoom_locked = true
	zoom = clampf(float(saved), 0.008, MAX_ZOOM)

func set_zoom_locked(value: bool) -> void:
	if zoom_locked == value: return
	zoom_locked = value
	_save_pending = true
	save_preferences()
	zoom_lock_changed.emit(value)

func save_preferences() -> void:
	if not _save_pending: return
	_save_pending = false
	set_process(false)
	if preferences_path.is_empty(): return
	var config := ConfigFile.new()
	config.load(preferences_path)
	config.set_value("view", "keep_zoom", zoom_locked)
	config.set_value("view", "zoom", zoom)
	if config.save(preferences_path) != OK:
		push_warning("Could not save map zoom preference: " + preferences_path)

func _process(delta: float) -> void:
	_save_delay -= delta
	if _save_delay <= 0: save_preferences()

func _exit_tree() -> void:
	save_preferences()

func world_to_map(point: Vector2) -> Vector2:
	return (point - center) * zoom + size * 0.5

func map_to_world(point: Vector2) -> Vector2:
	return (point - size * 0.5) / zoom + center

func set_location(position_3d: Vector3, forward: Vector3) -> void:
	var point := Vector2(position_3d.x, position_3d.z)
	var heading := Vector2(forward.x, forward.z)
	if heading.length_squared() < 0.0001: heading = live_heading
	heading = heading.normalized()
	var changed := not has_position or not _drawn_live.is_finite() \
		or point.distance_squared_to(_drawn_live) * zoom * zoom > REDRAW_PIXELS * REDRAW_PIXELS \
		or heading.distance_squared_to(_drawn_heading) > 0.0001
	live_position = point; live_heading = heading; has_position = true
	if following: center = live_position
	if changed: queue_redraw()

func follow() -> void:
	following = true
	if has_position: center = live_position
	queue_redraw()

func frame_world() -> void:
	if zoom_locked: return
	var bounds := _aerial.frame_bounds()
	if not _aerial.available():
		if markers.is_empty(): return
		bounds = Rect2(markers[0].position, Vector2.ZERO)
		for marker in markers: bounds = bounds.expand(marker.position)
		bounds = bounds.grow(700)
	center = bounds.get_center()
	zoom = minf(size.x / bounds.size.x, size.y / bounds.size.y)
	following = false; queue_redraw()

func zoom_at(factor: float, pixel: Vector2) -> void:
	var before := map_to_world(pixel)
	zoom = clampf(zoom * factor, 0.008, MAX_ZOOM)
	center += before - map_to_world(pixel)
	following = false; queue_redraw()
	if zoom_locked:
		_save_pending = true; _save_delay = 0.35
		set_process(true)

func select_marker(id: String) -> void:
	for marker in markers + pony_markers:
		if marker.id != id: continue
		selected_id = id; marker_selected.emit(marker); queue_redraw(); return

func marker_at(pixel: Vector2) -> Dictionary:
	var best := {}; var distance := 14.0
	for marker in markers:
		if marker.get("local_place", false) and LOCAL_PLACES.opacity(zoom) <= 0: continue
		var d := world_to_map(marker.position).distance_to(pixel)
		if d < distance: distance = d; best = marker
	# Drawn on top of place markers; allow selecting the actual coat-colored disc.
	var pony_distance := INF
	for marker in pony_markers:
		var d := world_to_map(marker.position).distance_to(pixel)
		# Exactly stacked discs (residents parked on one place point) resolve to the lowest id.
		if d <= pony_radius()+3 and (d < pony_distance or (d == pony_distance and marker.id < best.id)): pony_distance=d; best=marker
	return best

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed: zoom_at(1.25, event.position)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed: zoom_at(0.8, event.position)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if compact and event.pressed: expand_requested.emit()
			elif event.pressed: _dragging = true; _press = event.position; _drag_distance = 0
			else:
				_dragging = false
				if _drag_distance < 5:
					var marker := marker_at(event.position)
					if not marker.is_empty(): select_marker(marker.id)
		accept_event()
	elif event is InputEventMouseMotion:
		if _dragging:
			_drag_distance += event.relative.length()
			center -= event.relative / zoom; following = false
		var marker := marker_at(event.position)
		hovered_id = str(marker.get("id", "")); tooltip_text = str(marker.get("name", "")) + (" · " + str(marker.tracking) if marker.has("tracking") else "")
		if marker.has("position"): tooltip_text += " · X %.1f  Z %.1f" % [marker.position.x, marker.position.y]
		queue_redraw(); accept_event()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT: _dragging = false

func _draw() -> void:
	_drawn_ponies = pony_markers; _drawn_live = live_position if has_position else Vector2.INF; _drawn_heading = live_heading
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size), Color("263f4b"))
	if _aerial.available():
		_aerial.draw_into(self)
	else:
		var top_left := WorldLayout.canon_to_world(Vector2.ZERO)
		var metres: float = WorldLayout.data().canon.m_per_px
		draw_texture_rect(ATLAS, Rect2(world_to_map(top_left), ATLAS.get_size() * metres * zoom), false, Color(0.78, 0.81, 0.81))
	var ordered := markers.duplicate()
	ordered.sort_custom(func(a, b):
		var ap: bool = a.id == selected_id or a.id == hovered_id
		var bp: bool = b.id == selected_id or b.id == hovered_id
		if ap != bp: return ap
		if bool(a.get("local_place", false)) != bool(b.get("local_place", false)): return bool(a.get("local_place", false))
		var ac: bool = bool(a.get("local_place", false)) and a.kind == "landmark"
		var bc: bool = bool(b.get("local_place", false)) and b.kind == "landmark"
		if ac != bc: return ac
		return a.position.distance_squared_to(live_position) < b.position.distance_squared_to(live_position))
	var labels: Array[Rect2] = []
	if has_position: labels.append(Rect2(world_to_map(live_position) - Vector2(16, 17), Vector2(69, 34)))
	var area := Rect2(Vector2(5, 5), size - Vector2(10, 10))
	if has_position:
		for marker in markers:
			if marker.id == selected_id: draw_dashed_line(world_to_map(live_position), world_to_map(marker.position), GOLD, 1.5, 6)
	for marker in ordered:
		var pixel := world_to_map(marker.position)
		if not area.has_point(pixel): continue
		var chosen: bool = marker.id == selected_id or marker.id == hovered_id
		var local: bool = marker.get("local_place", false)
		var alpha := LOCAL_PLACES.opacity(zoom) if local else 1.0
		if alpha <= 0: continue
		var color := GOLD if marker.kind in ["town", "city", "village", "sky_city", "farm"] else Color("acd2b0")
		draw_circle(pixel, 7 if chosen else 5, Color(INK, alpha))
		draw_circle(pixel, 4.5 if chosen else 3, Color(GOLD if chosen else color, alpha))
		if marker.get("activity", "") == "apple_bucking":
			# Two lobes, a tapered base and green leaf: visible even on the wrist map.
			draw_colored_polygon(PackedVector2Array([pixel+Vector2(-5,0),pixel+Vector2(5,0),pixel+Vector2(3,6),pixel+Vector2(-3,6)]), Color("f46950"))
			draw_circle(pixel+Vector2(-2,-1),3.5,Color("f46950"))
			draw_circle(pixel+Vector2(2,-1),3.5,Color("f46950"))
			draw_line(pixel+Vector2(0,-4),pixel+Vector2(4,-7),Color("a7d875"),2.5,true)
		var place_font: Font = PLACE_FONT if local else font
		var font_size: int = LOCAL_PLACES.FONT_SIZE if local else label_font_size
		var text_size := place_font.get_string_size(marker.name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var pos := pixel + Vector2(10, -11)
		pos.x = clampf(pos.x, 4, maxf(4, size.x - text_size.x - 12)); pos.y = clampf(pos.y, 4, maxf(4, size.y - 22))
		var box := Rect2(pos, text_size + Vector2(8, 6))
		var overlaps := false
		for occupied in labels:
			if occupied.intersects(box): overlaps = true; break
		if overlaps or (compact and labels.size() >= 4 and not chosen): continue
		labels.append(box.grow(3))
		draw_rect(box, Color(0, 0, 0, 0.86 * alpha))
		draw_string(place_font, pos + Vector2(4, font_size + 2), marker.name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(GOLD if chosen else Color.WHITE, alpha))
	_draw_ponies(font, area)
	if cursor.x >= 0:
		draw_arc(cursor, 9, 0, TAU, 24, CYAN, 2.0, true); draw_circle(cursor, 2, CYAN)
	if has_position:
		var pixel := world_to_map(live_position)
		if area.has_point(pixel):
			var side := Vector2(-live_heading.y, live_heading.x)
			var arrow := PackedVector2Array([pixel + live_heading * 12, pixel - live_heading * 8 + side * 8, pixel - live_heading * 4, pixel - live_heading * 8 - side * 8])
			draw_circle(pixel, 16, Color(0.02, 0.1, 0.15, 0.85))
			draw_colored_polygon(arrow, CYAN)
			draw_string_outline(font, pixel + Vector2(18, 5), "YOU", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 4, INK)
			draw_string(font, pixel + Vector2(18, 5), "YOU", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, CYAN)
	draw_string_outline(font, Vector2(size.x - 23, 23), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, INK)
	draw_string(font, Vector2(size.x - 23, 23), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
	var length_m := pow(10.0, floor(log(90.0 / zoom) / log(10.0)))
	if length_m * zoom < 35: length_m *= 5
	var from := Vector2(14, size.y - 16)
	draw_line(from, from + Vector2(length_m * zoom, 0), Color.WHITE, 2)
	var scale_text := "%.1f km" % (length_m / 1000) if length_m >= 1000 else "%d m" % int(length_m)
	draw_string_outline(font, from - Vector2(0, 7), scale_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 4, INK)
	draw_string(font, from - Vector2(0, 7), scale_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)


func update_ponies(reference: Node3D, force := false) -> void:
	var now := Time.get_ticks_msec()
	if force or now >= _local_refresh_at:
		_local_refresh_at = now + 2000
		var places: Array = LOCAL_PLACES.sample(reference)
		# Retain offline civic anchors when town is unloaded, never default residents.
		var seen := {}
		for place: Dictionary in places: seen[place.id] = true
		for place: Dictionary in LOCAL_PLACES.defaults():
			if not seen.has(place.id): places.append(place)
		var old: Array = markers.filter(func(row: Dictionary): return row.get("local_place", false))
		if old != places:
			markers = markers.filter(func(row: Dictionary): return not row.get("local_place", false))
			markers.append_array(places)
			if selected_id.begins_with("house:") and selected_marker().is_empty(): selected_id = ""
			queue_redraw()
	var next: Array = pony_data.sample(reference, force)
	if next != pony_markers:
		pony_markers = next
		if selected_id.begins_with("pony:") and selected_marker().is_empty(): selected_id=""
		if _ponies_moved(): queue_redraw()

## Whether the markers differ visibly from the ones last drawn.
func _ponies_moved() -> bool:
	if pony_markers.size() != _drawn_ponies.size(): return true
	var limit := REDRAW_PIXELS * REDRAW_PIXELS / maxf(zoom * zoom, 1e-12)
	for i in pony_markers.size():
		var a: Dictionary = pony_markers[i]; var b: Dictionary = _drawn_ponies[i]
		for key: String in MARKER_KEYS:
			if a.get(key) != b.get(key): return true
		var at: Vector2 = a.get("position", Vector2.INF)
		if not at.is_finite() or at.distance_squared_to(b.get("position", Vector2.INF)) > limit: return true
	return false

func selected_marker() -> Dictionary:
	for marker: Dictionary in markers + pony_markers:
		if marker.id == selected_id: return marker
	return {}

func pony_radius() -> float:
	return 7.0 if compact else (21.0 if label_font_size>=20 else 17.0)

func _draw_ponies(font: Font, area: Rect2) -> void:
	var radius := pony_radius()
	# Selected/hovered discs last so they draw on top.
	var order: Array = []; var top: Array = []
	for marker: Dictionary in pony_markers:
		if marker.id==selected_id or marker.id==hovered_id: top.append(marker)
		else: order.append(marker)
	order.append_array(top)
	var reach := area.grow(radius)
	for marker: Dictionary in order:
		var pixel := world_to_map(marker.position)
		if not reach.has_point(pixel): continue
		var chosen: bool=marker.id==selected_id or marker.id==hovered_id
		if chosen and has_position:
			draw_dashed_line(world_to_map(live_position),pixel,GOLD,1.5,6)
		draw_circle(pixel,radius+2,INK)
		draw_circle(pixel,radius,marker.coat)
		if marker.tracking=="Live" or chosen:
			draw_arc(pixel,radius,0,TAU,40,GOLD if chosen else Color(.95,.97,1,.9),1.5,true)
		else:
			for segment in 8: draw_arc(pixel,radius,segment*TAU/8,(segment+.55)*TAU/8,5,Color(.85,.9,.95),1.0,true)
		var icon: Dictionary=PONY_DATA.icons.get(marker.icon_id,{})
		if not icon.is_empty() and PONY_DATA.atlas!=null:
			var rect: Array=icon.rect
			# Inscribed square guarantees every mark pixel remains inside the circle.
			var side:=radius*sqrt(2.0)
			draw_texture_rect_region(PONY_DATA.atlas,Rect2(pixel-Vector2.ONE*side*.5,Vector2.ONE*side),Rect2(rect[0],rect[1],rect[2],rect[3]))
		if chosen and not compact:
			var label: String=marker.name
			var width:=font.get_string_size(label,HORIZONTAL_ALIGNMENT_LEFT,-1,label_font_size).x
			var at:=pixel+Vector2(radius+5,-label_font_size*.5)
			at.x=clampf(at.x,4,maxf(4,size.x-width-12)); at.y=clampf(at.y,4,maxf(4,size.y-label_font_size-8))
			draw_rect(Rect2(at-Vector2(3,0),Vector2(width+8,label_font_size+7)),INK)
			draw_string(font,at+Vector2(0,label_font_size),label,HORIZONTAL_ALIGNMENT_LEFT,-1,label_font_size,GOLD)
