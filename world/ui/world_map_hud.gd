extends CanvasLayer
## Desktop/live editor map. The same atlas can later be hosted by a VR wrist viewport.
signal expanded_changed(open: bool)
const MAP_VIEW := preload("res://world/ui/world_map_view.gd")
var tracked: Node3D
var map: Control
var expanded := false
var preferences_path := "user://world_map.cfg"
var panel: Panel
var toolbar: HBoxContainer
var title: Label
var status: Label
var ponies: OptionButton
var _pony_menu_ids: Array = []
var _place_menu_rows: Array = []
var places: OptionButton
var keep_zoom: CheckButton
var whole_map: Button
var _root: Control
var _timer := 0.0
var _pony_marker_clock := 0.0
var _previous_mouse_mode := Input.MOUSE_MODE_VISIBLE
var _selected: Dictionary = {}

func _ready() -> void:
	layer = 110
	_root = Control.new(); add_child(_root); _root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel = Panel.new(); _root.add_child(panel)
	var style := StyleBoxFlat.new(); style.bg_color = Color("13232f"); style.border_color = Color("587783")
	style.set_border_width_all(1); style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", style)
	title = Label.new(); title.text = ""; title.add_theme_color_override("font_color", Color("ffdc8c"))
	panel.add_child(title)
	map = MAP_VIEW.new(); map.preferences_path = preferences_path; panel.add_child(map)
	map.marker_selected.connect(func(marker): _selected = marker; _update_status())
	map.expand_requested.connect(func(): set_expanded(true))
	toolbar = HBoxContainer.new(); toolbar.add_theme_constant_override("separation", 5); panel.add_child(toolbar)
	_button("−", func(): map.zoom_at(0.8, map.size * 0.5))
	_button("+", func(): map.zoom_at(1.25, map.size * 0.5))
	whole_map = _button("Whole map", func(): map.frame_world())
	_button("Follow me", func(): map.follow())
	keep_zoom = CheckButton.new(); keep_zoom.text = "Keep zoom"; keep_zoom.focus_mode = Control.FOCUS_NONE
	keep_zoom.tooltip_text = "Remember this zoom when closing, reopening or restarting. You can still adjust it with the wheel or +/−."
	toolbar.add_child(keep_zoom)
	keep_zoom.toggled.connect(func(value): map.set_zoom_locked(value))
	map.zoom_lock_changed.connect(_update_zoom_lock)
	_update_zoom_lock(map.zoom_locked)
	places = OptionButton.new(); places.custom_minimum_size.x = 190; places.clip_text = true
	toolbar.add_child(places); places.add_item("Find a place…")
	var sorted: Array = map.markers.duplicate(); sorted.sort_custom(func(a,b): return a.name < b.name)
	for marker in sorted:
		places.add_item(marker.name); places.set_item_metadata(places.item_count - 1, marker)
	places.item_selected.connect(func(index):
		if index == 0: return
		var marker: Dictionary = places.get_item_metadata(index)
		map.select_marker(marker.id); map.center = marker.position; map.following = false
		if not map.zoom_locked: map.zoom = maxf(map.zoom, 1.8 if marker.get("local_place", false) else 0.15)
		map.queue_redraw())
	ponies=OptionButton.new(); ponies.custom_minimum_size.x=180; ponies.clip_text=true
	toolbar.add_child(ponies); ponies.add_item("Find a pony…")
	ponies.item_selected.connect(func(index):
		if index==0: return
		map.select_marker(str(ponies.get_item_metadata(index)))
		var marker: Dictionary=map.selected_marker()
		if marker.is_empty(): return
		map.center=marker.position; map.following=false
		if not map.zoom_locked: map.zoom=maxf(map.zoom,1.8)
		map.queue_redraw())
	_button("Close · M", func(): set_expanded(false))
	status = Label.new(); status.add_theme_font_size_override("font_size", 13); status.clip_text = true
	panel.add_child(status)
	_root.resized.connect(_layout); _layout(); _update_status()

func _button(text: String, callback: Callable) -> Button:
	var button := Button.new(); button.text = text; button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback); toolbar.add_child(button)
	return button

func _update_zoom_lock(locked: bool) -> void:
	keep_zoom.set_pressed_no_signal(locked)
	whole_map.disabled = locked
	whole_map.tooltip_text = "Turn off Keep zoom to show the whole map." if locked else ""

func bind(target: Node3D) -> void:
	tracked = target; update_location()

func update_location() -> void:
	if not is_instance_valid(tracked) or not tracked.is_inside_tree() or map == null: return
	map.set_location(tracked.global_position, -tracked.global_basis.z)
	if _pony_marker_clock <= 0.0:
		map.update_ponies(tracked)
		_pony_marker_clock = 0.5 if expanded else 2.0
	# The pony finder lives on the toolbar, which only shows when expanded.
	if expanded:
		_update_pony_menu()
		_update_place_menu()
	_update_status()

func _process(delta: float) -> void:
	var profiling := preload("res://tools/crowd_cpu_profile.gd")
	if not profiling.enabled:
		_profiled_process(delta)
		return
	var started := Time.get_ticks_usec()
	_profiled_process(delta)
	profiling.record("world_map_hud", started)


func _profiled_process(delta: float) -> void:
	_pony_marker_clock -= delta
	_timer += delta
	if _timer < 0.1: return
	_timer = 0; update_location()

func set_expanded(open: bool) -> void:
	if open and get_meta("save_menu_open",false):return
	if expanded == open: return
	expanded = open
	_pony_marker_clock = 0.0
	if open:
		_previous_mouse_mode = Input.mouse_mode; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_update_pony_menu()
	else:
		Input.mouse_mode = _previous_mouse_mode
		map.following = true
		map.save_preferences()
	map.compact = not open; map._dragging = false
	_layout()
	if open and not map.zoom_locked: map.frame_world()
	else: map.follow()
	expanded_changed.emit(open)

func contains_screen(point: Vector2) -> bool:
	return panel != null and panel.get_global_rect().has_point(point)

func _layout() -> void:
	var screen := get_viewport().get_visible_rect().size
	panel.size = Vector2(minf(1100, screen.x - 32), minf(760, screen.y - 32)) if expanded else Vector2(310, 248)
	panel.position = (screen - panel.size) * 0.5 if expanded else Vector2(screen.x - panel.size.x - 16, 16)
	# No title on the mini map (dev: "remove the LIVE MAP text").
	title.position = Vector2(12, 8); title.text = "EQUESTRIA"; title.visible = expanded
	toolbar.position = Vector2(12, 36); toolbar.visible = expanded
	map.position = Vector2(8, 78 if expanded else 8)
	map.size = panel.size - Vector2(16, 122 if expanded else 40)
	if not expanded and not map.zoom_locked: map.zoom = map.size.x / 4400.0
	status.position = Vector2(12, panel.size.y - 32); status.size = Vector2(panel.size.x - 24, 28)
	map.queue_redraw()

func _update_status() -> void:
	if status == null: return
	if not map.has_position: status.text = "Waiting for live position…"; return
	var p: Vector2 = map.live_position
	if expanded and not _selected.is_empty():
		_selected=map.selected_marker()
		if _selected.is_empty():
			status.text="Pony is no longer assigned"; return
		var distance: float = p.distance_to(_selected.position)
		var text := "%.2f km" % (distance / 1000) if distance >= 1000 else "%d m" % roundi(distance)
		status.text = "%s · X %.1f  Z %.1f · %s straight-line" % [str(_selected.name)+(" · "+str(_selected.tracking) if _selected.has("tracking") else ""), _selected.position.x, _selected.position.y, text]
	else:
		var nearest := WorldLayout.nearest(Vector3(p.x, 0, p.y))
		status.text = "%s · X %.0f  Z %.0f" % [nearest.get("name", "Equestria"), p.x, p.y]

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed: return
	if get_viewport().gui_get_focus_owner() is LineEdit: return
	if event.physical_keycode == KEY_M:
		set_expanded(not expanded); get_viewport().set_input_as_handled()
	elif expanded and event.physical_keycode == KEY_ESCAPE:
		set_expanded(false); get_viewport().set_input_as_handled()


func _update_pony_menu() -> void:
	if ponies==null: return
	var sorted: Array=map.pony_markers.duplicate()
	sorted.sort_custom(func(a,b): return a.name<b.name)
	var ids: Array=sorted.map(func(row): return row.id)
	if ids==_pony_menu_ids: return
	_pony_menu_ids=ids; ponies.clear(); ponies.add_item("Find a pony…")
	for row: Dictionary in sorted:
		ponies.add_item(row.name); ponies.set_item_metadata(ponies.item_count-1,row.id)


func _update_place_menu() -> void:
	if places == null: return
	var sorted: Array = map.markers.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary): return a.name < b.name)
	var rows: Array = sorted.map(func(row: Dictionary): return [row.id, row.name, row.position])
	if rows == _place_menu_rows: return
	_place_menu_rows = rows
	places.clear(); places.add_item("Find a place…")
	for marker: Dictionary in sorted:
		places.add_item(marker.name)
		places.set_item_metadata(places.item_count - 1, marker)
