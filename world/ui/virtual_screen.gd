extends Node3D
## Seated VR (dev 2026-10-01): the 2D HUD on a floating screen in the headset. A headset shows
## only the 3D view, so every ordinary CanvasLayer (menus, hotbar, prompts, chat, map, labels)
## draws into one window-sized SubViewport instead, shown on a quad that lazily follows the view.
##
## Input needs no forwarding: Godot routes GUI input to a root Control through its tree viewport
## (the window), while a CanvasLayer with custom_viewport only draws into that viewport. Window
## and SubViewport pixels match (no stretch mode, same size), so the mouse reaches the same
## Control it is drawn over. Needs confirming in the first headset session; if menus do not
## answer there, FORWARD_INPUT pushes the window's mouse and key events into the SubViewport.
##
## Popups (OptionButton lists, PopupMenu) are windows of their own, embedded where they live:
## the window, so the headset never showed them. Those under adopted layers move into this
## SubViewport, which embeds them, and while one is open the window's mouse and keys go to it.
## A layer keeps to the window with meta &"no_virtual_screen" (loading cover, wake, creator).
## docs/ANONPONY_DESIGN_2026_10_01.md, 6.4.

const WIDTH := 1.7             # metres across
const DISTANCE := 1.9          # metres in front of the eye
const DROP := 0.15             # centre below eye level, metres
const FOLLOW_ANGLE := deg_to_rad(30.0)
const SETTLE_ANGLE := deg_to_rad(2.0)
const FOLLOW_RATE := 4.0       # 1/s, easing back in front of the view
const RENDER_PRIORITY := 90    # under the loading cover (100), wake (110), creator (115), cursor (120)
const CURSOR_LAYER := 4096
const SKIP_META := &"no_virtual_screen"
## Fallback only (see above): off while Godot's own routing works.
const FORWARD_INPUT := false

var game: Node
var viewport: SubViewport
var screen: Sprite3D
var _camera: Camera3D
var _cursor_layer: CanvasLayer
var _arrow: Node2D
var _adopted: Array[int] = []   # instance ids of the layers drawing here
var _yaw := 0.0
var _placed := false
var _following := false
var _popups: Dictionary = {}   # popup instance id -> its original parent's instance id
var _popup_sweep := 0.0


func setup(host: Node) -> void:
	game = host
	_camera = _find_camera()
	viewport = SubViewport.new()
	viewport.name = "ScreenViewport"
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.gui_embed_subwindows = true
	add_child(viewport)
	screen = Sprite3D.new()
	screen.name = "Screen"
	screen.texture = viewport.get_texture()
	screen.shaded = false
	screen.double_sided = false
	screen.no_depth_test = true
	screen.render_priority = RENDER_PRIORITY
	screen.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	screen.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Placed every frame from the camera, so never physics-interpolated.
	screen.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(screen)
	_build_cursor()
	var root := get_tree().root
	root.size_changed.connect(_resize)
	_resize()
	for node: Node in root.find_children("*", "CanvasLayer", true, false): _adopt(node.get_instance_id())
	get_tree().node_added.connect(_on_node_added)
	set_process_input(true)
	print("[seated] virtual screen %dx%d" % [viewport.size.x, viewport.size.y])


## The SubViewport follows the window, so pixels (and mouse positions) stay one to one.
func _resize() -> void:
	var size := get_tree().root.size
	if size.x <= 0 or size.y <= 0: return
	viewport.size = size
	screen.pixel_size = WIDTH / float(size.x)


func _on_node_added(node: Node) -> void:
	# Deferred: the creator sets its opt-out meta right after adding the layer.
	if node is CanvasLayer: _adopt.call_deferred(node.get_instance_id())
	elif node is Popup: _adopt_popup.call_deferred(node.get_instance_id())


func _adopt(id: int) -> void:
	var layer := instance_from_id(id) as CanvasLayer
	if layer == null or not layer.is_inside_tree() or layer == _cursor_layer: return
	if layer.has_meta(SKIP_META) and bool(layer.get_meta(SKIP_META)): return
	if layer.custom_viewport != null: return
	# Layers inside other SubViewports (spatial panels, book pages) already draw where they belong.
	if layer.get_viewport() != get_tree().root: return
	layer.custom_viewport = viewport
	if id not in _adopted: _adopted.append(id)
	for popup: Node in layer.find_children("*", "Popup", true, false): _adopt_popup(popup.get_instance_id())


## A popup under an adopted layer moves into the SubViewport, which embeds and draws it. Its
## owner (an OptionButton) keeps its reference, and positions match because the SubViewport
## is the window's size.
func _adopt_popup(id: int) -> void:
	var popup := instance_from_id(id) as Popup
	if popup == null or not popup.is_inside_tree() or popup.get_parent() == viewport or _popups.has(id): return
	var layer := _layer_of(popup)
	if layer == null or layer.get_instance_id() not in _adopted: return
	if popup.visible: popup.hide()
	_popups[id] = popup.get_parent().get_instance_id()
	popup.reparent(viewport, false)


## A moved popup no longer dies with its owner: free it once the owner is gone.
func _sweep_popups() -> void:
	for id: int in _popups.keys():
		var popup := instance_from_id(id) as Popup
		if popup == null: _popups.erase(id); continue
		if instance_from_id(int(_popups[id])) == null:
			_popups.erase(id)
			popup.queue_free()


static func _layer_of(node: Node) -> CanvasLayer:
	var at := node.get_parent()
	while at != null:
		if at is CanvasLayer: return at as CanvasLayer
		if at is Viewport: return null
		at = at.get_parent()
	return null


func _popup_open() -> bool:
	for id: int in _popups.keys():
		var popup := instance_from_id(id) as Popup
		if popup != null and popup.visible: return true
	return false


func _input(event: InputEvent) -> void:
	if not (event is InputEventMouse or event is InputEventKey): return
	if FORWARD_INPUT or _popup_open():
		viewport.push_input(event, true)
		get_viewport().set_input_as_handled()


## Leaving the world: layers that outlive it (on the root) go back to the window.
func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added): get_tree().node_added.disconnect(_on_node_added)
	# Popups go home before the SubViewport is freed, so their owners keep valid references.
	for id: int in _popups.keys():
		var popup := instance_from_id(id) as Popup
		var home := instance_from_id(int(_popups[id])) as Node
		if popup == null: continue
		if home != null and home.is_inside_tree(): popup.reparent(home, false)
		else: popup.queue_free()
	_popups.clear()
	for id: int in _adopted:
		var layer := instance_from_id(id) as CanvasLayer
		# Godot refuses a null custom viewport; hand surviving layers back to the window.
		if layer != null and layer.custom_viewport == viewport and layer.is_inside_tree(): layer.custom_viewport = get_tree().root
	_adopted.clear()


## A plain arrow drawn on the screen itself, where the window's mouse is, while the mouse points
## at a Control (the headset never shows the system cursor). Elsewhere the 3D mouse dot
## (world/ui/headset_cursor.gd) takes over.
func _build_cursor() -> void:
	_cursor_layer = CanvasLayer.new()
	_cursor_layer.name = "ScreenCursor"
	_cursor_layer.layer = CURSOR_LAYER
	_cursor_layer.custom_viewport = viewport
	add_child(_cursor_layer)
	_arrow = Node2D.new()
	_arrow.name = "Arrow"
	_cursor_layer.add_child(_arrow)
	var points := PackedVector2Array([Vector2(0, 0), Vector2(0, 21), Vector2(5, 16), Vector2(9, 25),
		Vector2(13, 23), Vector2(9, 15), Vector2(15, 15)])
	var fill := Polygon2D.new()
	fill.polygon = points
	fill.color = Color(1, 1, 1)
	_arrow.add_child(fill)
	var edge := Line2D.new()
	edge.points = points
	edge.closed = true
	edge.width = 1.5
	edge.default_color = Color(0.05, 0.05, 0.08)
	edge.joint_mode = Line2D.LINE_JOINT_SHARP
	_arrow.add_child(edge)
	_arrow.hide()


func _process(delta: float) -> void:
	var root := get_tree().root
	_popup_sweep -= delta
	if _popup_sweep <= 0.0:
		_popup_sweep = 1.0
		_sweep_popups()
	_arrow.visible = Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and (root.gui_get_hovered_control() != null or _popup_open())
	if _arrow.visible: _arrow.position = root.get_mouse_position()
	if not is_instance_valid(_camera) or not _camera.is_inside_tree(): _camera = _find_camera()
	if _camera == null: return
	var eye := _camera.global_position
	if not eye.is_finite(): return
	var forward := -_camera.global_basis.z
	forward.y = 0.0
	var view_yaw := atan2(-forward.x, -forward.z) if forward.length_squared() > 1e-6 else _yaw
	if not _placed:
		_yaw = view_yaw
		_placed = true
	# Lazy follow: the screen stays put until the view has turned well away, then eases back.
	var off := absf(angle_difference(_yaw, view_yaw))
	if off > FOLLOW_ANGLE: _following = true
	if _following:
		_yaw = lerp_angle(_yaw, view_yaw, 1.0 - exp(-FOLLOW_RATE * delta))
		if absf(angle_difference(_yaw, view_yaw)) < SETTLE_ANGLE: _following = false
	var facing := Basis(Vector3.UP, _yaw)
	screen.global_transform = Transform3D(facing, eye + facing * Vector3(0.0, -DROP, -DISTANCE))


func _find_camera() -> Camera3D:
	if game == null or not is_instance_valid(game.get("player")): return null
	return game._find_camera(game.player) as Camera3D
