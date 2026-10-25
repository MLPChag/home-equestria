extends Node
## The opening's living backdrop (dev 2026-09-30: black, "Home:", then "Equestria", then "the
## black fades out into a preloaded view from a few choices: right above ponyville, in front
## of twilight's house, in front of fluttershy's cottage, in the everfree forest by Zecora's,
## or in the middle of town square, or sweet apple acres").
##
## The game boots its real world in title mode (game.gd `title_mode`): right after the save is
## restored this node remembers where the player really is, moves the (still, physics-off)
## player to the chosen view so that area and its ponies stream in behind the logo, and after
## the reveal hosts the title menu (world/ui/title_screen.gd in overlay mode). Continue fades to
## black, streams the player's real place back in and hands over control; nothing is saved
## while the title is up. Setting title/view picks a view; "random" (default) rolls each launch.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const MENU := preload("res://world/ui/title_screen.gd")
const COVER := preload("res://world/ui/loading_cover.gd")
## name: {stand: [x, z], look: [x, metres above its ground, z], height: metres above the ground
## (views from the air)} or {door: approximate door position, framed from that building's real
## front door once it is streamed in: back/side metres from the handle, lift of the look point}
const VIEWS := {
	"above_ponyville": {"stand": Vector2(40.0, -95.0), "height": 38.0, "look": Vector3(110.0, 0.0, -200.0)},
	"golden_oak": {"door": Vector3(-24.5, -11.3, -259.2), "back": 21.0, "side": 6.0, "lift": 7.0},
	"fluttershy_cottage": {"door": Vector3(156.12, -19.01, -12.05), "back": 13.0, "side": -4.0, "lift": 2.5},
	"zecora_hut": {"door": Vector3(-34.5, -37.4, 993.9), "back": 9.0, "side": 3.0, "lift": 1.8},
	"town_square": {"stand": Vector2(236.0, -247.0), "height": 1.2, "look": Vector3(246.0, 1.5, -264.0)},
	"sweet_apple_acres": {"stand": Vector2(30.0, -420.0), "look": Vector3(13.0, 4.0, -440.0)},
}
var game: Node
var view_name := ""
var menu: Node
var _body: Node3D
var _camera: Camera3D
var _return_position := Vector3.ZERO
var _return_yaw := 0.0
var _return_pitch := 0.0
var _yaw := 0.0
var _pitch := 0.0
var _time := 0.0
var _cloud: MeshInstance3D
var _hidden: Array[CanvasItem] = []
var _hidden_layers: Array[CanvasLayer] = []
var _hidden_wake: Array[GeometryInstance3D] = []
var _continuing := false

static func pick(setting: String) -> String:
	if VIEWS.has(setting): return setting
	var names: Array = VIEWS.keys()
	return names[randi() % names.size()]

## Right after the save is restored: remember the real place, go to the view.
func prepare(host: Node) -> void:
	game = host
	_body = game.player.get_node("Body") if game.xr_active else game.player
	_camera = game._find_camera(game.player)
	var settings := get_node_or_null("/root/Settings")
	view_name = pick(str(settings.get_value("title/view")) if settings != null else "random")
	_return_position = Vector3(_camera.global_position.x, _body.global_position.y, _camera.global_position.z)
	_return_yaw = _camera.global_rotation.y
	_return_pitch = _camera.rotation.x
	if _flat_rig():
		_return_position = _body.global_position
		_return_yaw = _body.rotation.y
		_return_pitch = float(_body.get("_pitch"))
	if "controls_locked" in _body: _body.controls_locked = true
	var view: Dictionary = VIEWS[view_name]
	var stand: Vector3
	var look: Vector3
	if view.has("door"):
		var door: Vector3 = view.door
		stand = door + Vector3(0, 0, float(view.back))
		look = door + Vector3.UP * float(view.lift)
	else:
		stand = Vector3(view.stand.x, 0, view.stand.y)
		look = view.look
	_frame(stand, look, float(view.get("height", 0.0)))
	_hide_wake()
	print("[title] view ", view_name)

## Once the building near the view is streamed in: frame it from its real front door.
func _refine() -> void:
	var view: Dictionary = VIEWS[view_name]
	if not view.has("door"): return
	var approx: Vector3 = view.door
	var best: Node3D = null
	for door: Node in get_tree().get_nodes_in_group("house_doors"):
		if door is Node3D and (door as Node3D).global_position.distance_to(approx) < 6.0:
			if best == null or (door as Node3D).global_position.distance_to(approx) < best.global_position.distance_to(approx): best = door
	if best == null: return
	var handle: Vector3 = best.handle_world() if best.has_method("handle_world") else best.global_position
	var out: Vector3 = best.global_basis.z.normalized(); out.y = 0; out = out.normalized()
	var side: Vector3 = out.cross(Vector3.UP).normalized()
	var stand: Vector3 = handle + out * float(view.back) + side * float(view.side)
	_frame(stand, handle + Vector3.UP * float(view.lift), 0.0)

## Put the player's eye at `stand` (on the ground, or `height` above it) looking at `look`.
func _frame(stand: Vector3, look: Vector3, height: float) -> void:
	var ground: float = stand.y
	if is_instance_valid(WorldTerrain.instance):
		var h: float = WorldTerrain.instance.height_at(stand)
		if is_finite(h): ground = h
	if not VIEWS[view_name].has("door") and is_instance_valid(WorldTerrain.instance):
		var lh: float = WorldTerrain.instance.height_at(look)
		if is_finite(lh): look.y += lh
	var feet := Vector3(stand.x, ground + height + 0.05, stand.z)
	var to := look - (feet + Vector3.UP * 1.65)
	_yaw = atan2(-to.x, -to.z)
	_pitch = clampf(atan2(to.y, Vector2(to.x, to.z).length()), -0.6, 0.4)
	_place(feet, _yaw)
	if not game.xr_active and not _camera is XRCamera3D:
		_body.set("_pitch", _pitch); _camera.rotation.x = _pitch
	if is_instance_valid(WorldTerrain.instance): WorldTerrain.instance.focus(feet)
	if height > 5.0: _add_cloud(feet)
	elif is_instance_valid(_cloud): _cloud.queue_free()

## Seated VR and AnonPony rigs: the rig's own place, not the tracked head or the pony's eye.
func _flat_rig() -> bool:
	return not game.xr_active and (_body.get("headset_view") == true or _body.get("form_driver") != null)

## Same placement as a loaded save (game_saves._restore): eye over `feet`, facing `yaw`.
func _place(feet: Vector3, yaw: float) -> void:
	if game.xr_active:
		_body.get_node("XROrigin").rotate_y(yaw - _camera.global_rotation.y)
	else:
		_body.rotation.y = yaw
	var eye_feet := Vector3(_camera.global_position.x, _body.global_position.y, _camera.global_position.z)
	if _flat_rig(): eye_feet = _body.global_position
	_body.global_position += feet - eye_feet
	if "velocity" in _body: _body.velocity = Vector3.ZERO

## A soft cloud to stand on for the view from the air, so the headset has a floor.
func _add_cloud(feet: Vector3) -> void:
	if is_instance_valid(_cloud): _cloud.queue_free()
	var mesh := SphereMesh.new(); mesh.radius = 2.2; mesh.height = 1.2; mesh.radial_segments = 24; mesh.rings = 10
	var material := StandardMaterial3D.new(); material.albedo_color = Color(1, 1, 1); material.roughness = 1.0
	material.rim_enabled = true; material.rim = 0.4
	mesh.material = material
	_cloud = MeshInstance3D.new(); _cloud.name = "TitleCloud"; _cloud.mesh = mesh
	_cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_cloud); _cloud.global_position = feet - Vector3.UP * 0.55

## After loading: frame, fade the black away under the logo, then show the menu.
func reveal(cover: Node) -> void:
	_refine()
	_hide_hud(true)
	for i in 4:
		if not await SHUTDOWN.frame(self): return
	if cover.has_method("reveal"): await cover.reveal(1.6, 1.1)
	else: cover.finish()
	menu = MENU.new()
	menu.name = "TitleMenu"
	menu.overlay_host = self
	game.add_child(menu)

func _physics_process(delta: float) -> void:
	# No artificial sway in any headset: only the real head turns the view.
	if _continuing or game == null or game.xr_active or _camera is XRCamera3D or not is_instance_valid(_body): return
	# A slow look around, like standing there for a moment.
	_time += delta
	_body.rotation.y = _yaw + sin(_time * 0.07) * 0.06

## The menu's Continue: back to where the save left the player, then play.
func continue_game() -> void:
	if _continuing: return
	_continuing = true
	var cover: Node = COVER.new()
	cover.name = "LoadingCover"; game.add_child(cover); cover.setup(_camera, game.xr_active)
	if is_instance_valid(menu): menu.queue_free()
	if is_instance_valid(_cloud): _cloud.queue_free()
	_place(_return_position, _return_yaw)
	if not game.xr_active and not _camera is XRCamera3D:
		_body.set("_pitch", _return_pitch)
		_camera.rotation.x = _return_pitch
	if is_instance_valid(WorldTerrain.instance): WorldTerrain.instance.focus(_return_position)
	if not await SHUTDOWN.frame(self): return
	if not await game._load_everything(cover): return
	cover.finish()
	_hide_hud(false)
	if "controls_locked" in _body: _body.controls_locked = false
	_body.set_physics_process(true)
	game.saves.ready_to_save = true
	game.title_active = false
	print("[title] continue")
	queue_free()

## The HUD (hotbar, map, pause menu) stays hidden behind the title. So do a fresh world's wake
## eyelids and words (world/life/arrival_wake.gd), built on the headset camera before the title:
## drawn over everything, they would leave the title black in any headset.
func _hide_hud(hide: bool) -> void:
	if hide:
		for node: Node in game.find_children("*", "CanvasLayer", true, false):
			var layer := node as CanvasLayer
			if layer.visible and not str(layer.get_path()).contains("LoadingCover"):
				layer.visible = false; _hidden_layers.append(layer)
		_hide_wake()
		if is_instance_valid(game.pause_menu): game.pause_menu.process_mode = Node.PROCESS_MODE_DISABLED
		if is_instance_valid(game.inventory) and "hud_hidden" in game.inventory: game.inventory.hud_hidden = true
	else:
		if is_instance_valid(game.inventory) and "hud_hidden" in game.inventory: game.inventory.hud_hidden = false
		for layer: CanvasLayer in _hidden_layers:
			if is_instance_valid(layer): layer.visible = true
		_hidden_layers.clear()
		for shape: GeometryInstance3D in _hidden_wake:
			if is_instance_valid(shape): shape.visible = true
		_hidden_wake.clear()
		if is_instance_valid(game.pause_menu): game.pause_menu.process_mode = Node.PROCESS_MODE_INHERIT

## Also at prepare, so the title-mode loading logo shows over the cover in the headset.
func _hide_wake() -> void:
	if not is_instance_valid(_camera): return
	for wake_name: String in ["WakeEyelids", "WakeWords"]:
		for node: Node in _camera.find_children(wake_name, "GeometryInstance3D", true, false):
			var shape := node as GeometryInstance3D
			if shape.visible: shape.visible = false; _hidden_wake.append(shape)
