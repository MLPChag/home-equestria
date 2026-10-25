extends Node
## Full cover while a game loads (dev 2026-09-24: "when you LOAD IN everything should be
## READY"). Desktop: a CanvasLayer over the window. Headset: a dark sphere around the camera
## drawn over everything, with the same text in front of the eyes. game.gd shows it before the
## first frame of the world and removes it once the ponies are out and the pipelines are warm.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")

const INK := Color("0e1420")
const GOLD := Color("edd6a2")
var _layer: CanvasLayer
var _label: Label
var _sphere: MeshInstance3D
var _label3d: Label3D

func setup(camera: Camera3D, xr: bool) -> void:
	# Seated VR has no room-scale rig (xr false) but still looks through the headset.
	xr = xr or camera is XRCamera3D
	_layer = CanvasLayer.new()
	_layer.layer = 120
	# The headset gets the sphere below; the layer stays on the desktop window, off the seated
	# virtual screen (world/ui/virtual_screen.gd).
	_layer.set_meta(&"no_virtual_screen", true)
	add_child(_layer)
	var back := ColorRect.new()
	back.color = INK
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(back)
	_label = Label.new()
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 34)
	_label.add_theme_color_override("font_color", GOLD)
	_layer.add_child(_label)
	if xr and camera != null:
		var mesh := SphereMesh.new()
		mesh.radius = 0.6
		mesh.height = 1.2
		mesh.flip_faces = true
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = INK
		mat.no_depth_test = true
		mat.render_priority = 100
		mesh.material = mat
		_sphere = MeshInstance3D.new()
		_sphere.name = "LoadingSphere"
		_sphere.mesh = mesh
		_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		camera.add_child(_sphere)
		_label3d = Label3D.new()
		_label3d.name = "LoadingText"
		_label3d.position = Vector3(0, 0, -0.45)
		_label3d.pixel_size = 0.0006
		_label3d.font_size = 48
		_label3d.no_depth_test = true
		_label3d.render_priority = 101
		_label3d.modulate = GOLD
		camera.add_child(_label3d)
	show_text("Loading Equestria…")

func show_text(text: String) -> void:
	if _label != null: _label.text = text
	if _label3d != null: _label3d.text = text

## Opening title (dev 2026-09-30): the game logo (dev 2026-10-08, world/ui/title/logo.png) on
## black, the same layout as the launch scene's card (world/ui/title_screen.gd), so the logo stays
## put while the world loads behind it. The loading line drops to a small note under it.
const LOGO := preload("res://world/ui/title/logo.png")
var _logos: Array[CanvasItem] = []
var _logos3d: Array[Sprite3D] = []
var _back: ColorRect

func show_logo() -> void:
	_back = _layer.get_child(0) as ColorRect
	_back.color = Color.BLACK
	_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_label.offset_bottom = -60
	_label.add_theme_font_size_override("font_size", 22)
	_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	_logos.append(logo_rect(_layer))
	if is_instance_valid(_sphere):
		(_sphere.mesh.surface_get_material(0) as StandardMaterial3D).albedo_color = Color.BLACK
		_label3d.position = Vector3(0, -0.2, -0.45); _label3d.pixel_size = 0.00035
		_label3d.modulate = Color(1, 1, 1, 0.45)
		_logos3d.append(logo_sprite(_sphere.get_parent()))

## Desktop logo: one centred TextureRect on `layer` (shared with the launch scene's card).
static func logo_rect(layer: CanvasLayer) -> TextureRect:
	var rect := TextureRect.new(); rect.texture = LOGO
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.anchor_left = 0.15; rect.anchor_right = 0.85
	rect.anchor_top = 0.04; rect.anchor_bottom = 0.84
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	return rect

## Headset logo: one sprite half a metre in front of the eyes, drawn over the cover sphere.
static func logo_sprite(camera: Node3D) -> Sprite3D:
	var sprite := Sprite3D.new(); sprite.texture = LOGO
	sprite.pixel_size = 0.30 / LOGO.get_width()
	sprite.position = Vector3(0, 0.05, -0.5)
	sprite.no_depth_test = true; sprite.render_priority = 102; sprite.shaded = false
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED; sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	camera.add_child(sprite)
	return sprite

## Title reveal: the black fades away over `seconds` while the logo stays, then the logo fades
## over `logo_seconds`, then the cover is gone.
func reveal(seconds: float, logo_seconds: float) -> void:
	if is_instance_valid(_label): _label.text = ""
	if is_instance_valid(_label3d): _label3d.text = ""
	var tree := Engine.get_main_loop() as SceneTree
	var sphere_mat: StandardMaterial3D = _sphere.mesh.surface_get_material(0) if is_instance_valid(_sphere) else null
	var t := 0.0
	while t < seconds:
		t += tree.root.get_process_delta_time() if tree.root.get_process_delta_time() > 0.0 else 1.0 / 60.0
		var a := 1.0 - smoothstep(0.0, 1.0, t / seconds)
		if is_instance_valid(_back): _back.color.a = a
		if sphere_mat != null: sphere_mat.albedo_color.a = a
		if not await SHUTDOWN.frame(self): return
	if not await SHUTDOWN.seconds(self, 0.6): return
	t = 0.0
	while t < logo_seconds:
		t += tree.root.get_process_delta_time() if tree.root.get_process_delta_time() > 0.0 else 1.0 / 60.0
		var a := 1.0 - smoothstep(0.0, 1.0, t / logo_seconds)
		for item: CanvasItem in _logos: if is_instance_valid(item): item.modulate.a = a
		for sprite: Sprite3D in _logos3d: if is_instance_valid(sprite): sprite.modulate.a = a
		if not await SHUTDOWN.frame(self): return
	for sprite: Sprite3D in _logos3d: if is_instance_valid(sprite): sprite.queue_free()
	finish()

func finish() -> void:
	if is_instance_valid(_sphere): _sphere.queue_free()
	if is_instance_valid(_label3d): _label3d.queue_free()
	queue_free()
