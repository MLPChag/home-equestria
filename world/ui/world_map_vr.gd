extends Node3D
## One flat 2D map texture in both eyes. No extra world camera or terrain rendering.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const MAP_VIEW := preload("res://world/ui/world_map_view.gd")
var opened := false
var preferences_path := "user://world_map.cfg"
var camera: Node3D
var left: XRController3D
var right: XRController3D
var body: CharacterBody3D
var viewport: SubViewport
var map: Control
var display: Sprite3D
var status: Label
var help: Label
var _timer := 0.0
## Right trigger on a dot selects it; a second press on the same dot within DOUBLE_CLICK
## teleports there (dev 2026-09-18). The rig hovers while the zone streams in, then lands
## on the first collider under the dot.
const DOUBLE_CLICK := 0.45
const HOVER := 400.0
@export var teleport_timeout_seconds := 120.0
var _click_id := ""
var _click_time := -10.0
var _teleporting := ""
var _teleport_error := ""
var _teleport_zone := ""
var _teleport_generation := 0
var _dream_suspended := false
var _dream_map_state := {}
signal saves_requested

func setup(head: Node3D, left_controller: XRController3D, right_controller: XRController3D, player_body: CharacterBody3D) -> void:
	camera = head; left = left_controller; right = right_controller; body = player_body
	viewport = SubViewport.new(); viewport.size = Vector2i(1200, 820)
	viewport.disable_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.gui_disable_input = true; add_child(viewport)
	var background := ColorRect.new(); background.color = Color("13232f")
	background.size = viewport.size; viewport.add_child(background)
	var title := Label.new(); title.text = "EQUESTRIA"
	title.position = Vector2(20, 8); title.add_theme_font_size_override("font_size", 28)
	background.add_child(title)
	map = MAP_VIEW.new(); map.position = Vector2(12, 52); map.size = Vector2(1176, 690)
	map.visible = false
	map.preferences_path = preferences_path
	map.compact = false; map.label_font_size = 20; background.add_child(map)
	status = Label.new(); status.position = Vector2(20, 748); status.add_theme_font_size_override("font_size", 20)
	background.add_child(status)
	help = Label.new(); help.position = Vector2(20, 779); help.add_theme_font_size_override("font_size", 18)
	background.add_child(help)
	map.zoom_lock_changed.connect(func(_locked): _update_help())
	_update_help()
	display = Sprite3D.new(); display.texture = viewport.get_texture(); display.pixel_size = 0.001
	display.shaded = false; display.no_depth_test = true; display.render_priority = 100
	display.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(display); display.hide()
	left.button_pressed.connect(_left_pressed); right.button_pressed.connect(_right_pressed)
	set_process(false)
	print("[map] VR map ready: left primary_click toggles")

func _left_pressed(action: StringName) -> void:
	if _dream_suspended: return
	if action == &"primary_click" and _teleporting == "": set_open(not opened)

func _right_pressed(action: StringName) -> void:
	if _dream_suspended or not opened or _teleporting != "": return
	if action==&"ax_button":saves_requested.emit();return
	if action == &"trigger_click":
		var marker: Dictionary = map.marker_at(_pointer_pixel())
		if marker.is_empty(): return
		var now := Time.get_ticks_msec() / 1000.0
		if marker.id == _click_id and now - _click_time < DOUBLE_CLICK: _teleport(marker)
		else: map.select_marker(marker.id)
		_click_id = marker.id; _click_time = now
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		return
	if action == &"primary_click":
		if not map.zoom_locked: map.zoom = 0.22
		map.follow(); viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	elif action == &"by_button":
		map.set_zoom_locked(not map.zoom_locked)
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _update_help() -> void:
	help.text = "Left click: close · Sticks: pan/zoom · Trigger: pick a dot, twice: teleport · Right click: find me · B: keep zoom %s · A: saves" % ("ON" if map.zoom_locked else "OFF")

## Map pixel under the right controller's ray, (-1, -1) when it misses the map.
func _pointer_pixel() -> Vector2:
	var origin := display.to_local(right.global_position)
	var direction := display.global_basis.inverse() * -right.global_basis.z
	if direction.z >= -0.00001: return Vector2(-1, -1)
	var distance := -origin.z / direction.z
	if distance < 0.0: return Vector2(-1, -1)
	var point := origin + direction * distance
	var pixel := Vector2(point.x, -point.y) / display.pixel_size + Vector2(viewport.size) * 0.5 - map.position
	return pixel if Rect2(Vector2.ZERO, map.size).has_point(pixel) else Vector2(-1, -1)

func _teleport(marker: Dictionary) -> void:
	if _dream_suspended or _teleporting != "": return
	_teleport_generation += 1
	var generation := _teleport_generation
	_teleporting = str(marker.name)
	_teleport_error = ""
	var target := Vector3(marker.position.x, 0, marker.position.y)
	var ground: float = WorldTerrain.instance.height_at(target)
	if not is_finite(ground): ground = body.global_position.y
	var zone := _destination_zone(marker, target)
	_teleport_zone = zone
	ZoneManager.prioritize_zone(zone)
	# Cloudsdale's ground is its platforms, not the heightmap hundreds of metres below.
	if zone != "": ground = maxf(ground, ZoneManager.zone_origin(zone).y)
	# Hover: the open map keeps controls locked, and flight has no gravity.
	body.flying = true
	body.teleport(Vector3(target.x, ground + HOVER, target.z))
	var deadline := Time.get_ticks_msec() + int(teleport_timeout_seconds * 1000)
	var landing := Vector3.INF
	while Time.get_ticks_msec() < deadline:
		# Observe collision only after physics has seen newly attached destination bodies.
		if not await SHUTDOWN.physics_frame(self) or not _teleport_current(generation): return
		if zone != "" and not ZoneManager.is_ready(zone): continue
		landing = _landing_point(target, ground, zone)
		if landing.is_finite(): break
		if not await SHUTDOWN.seconds(self, 0.1) or not _teleport_current(generation): return
	if not _teleport_current(generation): return
	if not landing.is_finite():
		_teleport_error = "%s is not ready for landing. You're safely hovering; retry or close the map to fly." % _teleporting
		print("[map] ", _teleport_error)
		_teleporting = ""
		_release_teleport_priority()
		return
	body.flying = false
	body.teleport(landing + Vector3.UP * 0.5)
	print("[map] teleported to %s at %s" % [_teleporting, body.global_position.round()])
	_teleporting = ""
	_release_teleport_priority()
	set_open(false)

func _teleport_current(generation: int) -> bool:
	return generation == _teleport_generation and not _dream_suspended and is_inside_tree() and not is_queued_for_deletion() and is_instance_valid(body) and not body.is_queued_for_deletion()

func _release_teleport_priority() -> void:
	var manager := get_node_or_null("/root/ZoneManager")
	if manager != null and not _teleport_zone.is_empty() and str(manager.get("_priority_zone")) == _teleport_zone:
		manager.prioritize_zone("")
	_teleport_zone = ""

## Suspend controller-signal input as well as drawing/processing. Keep opened intact,
## and never overwrite the dream/sleep controller's current player input lock on restore.
func set_dream_suspended(value: bool) -> void:
	if value == _dream_suspended: return
	_dream_suspended = value
	if value:
		_dream_map_state = {"processing": is_processing(), "viewport_mode": viewport.render_target_update_mode if is_instance_valid(viewport) else SubViewport.UPDATE_DISABLED}
		set_process(false)
		if is_instance_valid(viewport): viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		if not _teleporting.is_empty():
			_teleport_generation += 1
			_teleport_error = "%s travel paused for sleep. Retry from the map after waking." % _teleporting
			_teleporting = ""
			_release_teleport_priority()
	else:
		set_process(bool(_dream_map_state.get("processing", false)))
		if is_instance_valid(viewport): viewport.render_target_update_mode = int(_dream_map_state.get("viewport_mode", SubViewport.UPDATE_DISABLED))
		_dream_map_state.clear()

func _destination_zone(marker: Dictionary, target: Vector3) -> String:
	var region: Dictionary = WorldLayout.region(str(marker.get("id", "")))
	var authored := str(region.get("zone", ""))
	if authored in ZoneManager.zone_ids(): return authored
	# Pony dots do not have region IDs. Unlike ground navigation, map travel includes sky zones.
	return ZoneManager.zone_contains(target, true)

func _landing_point(target: Vector3, ground: float, zone: String) -> Vector3:
	var space := body.get_world_3d().direct_space_state
	var sky := zone != "" and bool(ZoneManager._defs[zone].get("flight_only", false))
	# A dot can lie in a gap between cloud platforms or directly on another character.
	for radius in [0.0, 2.0, 4.0, 8.0, 16.0]:
		for index in (1 if radius == 0.0 else 8):
			var point: Vector3 = target + Vector3(cos(index * TAU / 8), 0, sin(index * TAU / 8)) * radius
			var from := Vector3(point.x, ground + 1500.0, point.z)
			var query := PhysicsRayQueryParameters3D.create(from, Vector3(point.x, ground - 100.0, point.z), 1, [body.get_rid()])
			var hit := space.intersect_ray(query)
			if hit.is_empty() or hit.collider is CharacterBody3D or hit.normal.y < 0.7: continue
			if sky and not ZoneManager._loaded[zone].is_ancestor_of(hit.collider): continue
			var safe := true
			for offset in [Vector3(.3,0,0), Vector3(-.3,0,0), Vector3(0,0,.3), Vector3(0,0,-.3)]:
				query.from = hit.position + offset + Vector3.UP * .3
				query.to = hit.position + offset - Vector3.UP * .3
				var support := space.intersect_ray(query)
				if support.is_empty() or support.collider is CharacterBody3D or support.normal.y < .7:
					safe = false; break
			if safe: return hit.position
	return Vector3.INF

func set_open(value: bool) -> void:
	if _dream_suspended: return
	if value and get_meta("save_menu_open",false):return
	if opened == value: return
	opened = value; body.controls_locked = value; display.visible = value; set_process(value)
	map.visible = value
	if value:
		# Place a stable panel in front of the head, not attached to each head tremor.
		global_transform = Transform3D(Basis.IDENTITY, camera.global_position)
		var forward := -camera.global_basis.z; forward.y = 0
		if forward.length_squared() < 0.01: forward = Vector3.FORWARD
		display.global_position = camera.global_position + forward.normalized() * 1.15 + Vector3.DOWN * 0.08
		display.look_at(camera.global_position, Vector3.UP, true)
		map.update_ponies(camera,true)
		_update_location()
		if map.zoom_locked: map.follow()
		else: map.frame_world()
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	else:
		map.cursor = Vector2(-1, -1); map.hovered_id = ""
		map.save_preferences()
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

func _update_location() -> void:
	map.set_location(camera.global_position, -camera.global_basis.z)
	map.update_ponies(camera)
	var nearest := WorldLayout.nearest(camera.global_position)
	if _teleporting != "": status.text = "Teleporting to %s: loading …" % _teleporting; return
	if _teleport_error != "": status.text = _teleport_error; return
	status.text = "%s  ·  X %.0f  Z %.0f  ·  Cyan = you · Circles = ponies" % [nearest.get("name", "Equestria"), camera.global_position.x, camera.global_position.z]

func _process(delta: float) -> void:
	if _dream_suspended: return
	_timer += delta
	if _timer < 0.1: return
	var elapsed := minf(_timer, 0.2); _timer = 0
	var pan := left.get_vector2("primary")
	if pan.length() > 0.2:
		map.center += Vector2(pan.x, -pan.y) * elapsed * 430 / map.zoom
		map.following = false
	var zoom_input := right.get_vector2("primary").y
	if absf(zoom_input) > 0.2: map.zoom_at(exp(zoom_input * elapsed * 1.8), map.size * 0.5)
	map.cursor = _pointer_pixel()
	map.hovered_id = str(map.marker_at(map.cursor).get("id", "")) if map.cursor.x >= 0 else ""
	_update_location(); map.queue_redraw()
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _exit_tree() -> void:
	_teleport_generation += 1
	_release_teleport_priority()
	if is_instance_valid(body): body.controls_locked = false
