extends Node3D
## Lightweight title: baked surroundings and a spatial menu. Gameplay loads on entry.
const PANEL := preload("res://world/ui/spatial_menu_panel.gd")
const CONTROLLER_POINTER := preload("res://world/ui/controller_pointer.gd")
const TITLE_TIME := preload("res://world/ui/title_time.gd")
const BAKED := preload("res://world/ui/baked_vistas.gd")
const GAME := "res://world/main.tscn"
const SAVE_FILE := preload("res://world/save_file.gd")
const SAVES_PATH := "res://world/game_saves.gd"
const PACKS := preload("res://tools/build/packs.gd")
## Save discovery shared with the in-game saved games panel (headers and screenshots only).
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const PREVIEW := preload("res://world/saves/save_preview.gd")
# Header labelling only; selected files are always validated by GameSaves.
# Keep this lightweight menu constant aligned with GameSaves.FORMAT.
const SAVE_HEADER_FORMAT := CATALOGUE.HEADER_FORMAT
## The menu wears the title words' own look (world/ui/title/: bubbly pink-to-lilac letters, a white
## outline, a soft purple shadow) and says no more than it must (dev 2026-10-02: "minimalist and
## pony-themed", not a blue card with gold trim and filler lines).
const PINK := Color("f6a6d9")
const LILAC := Color("c06fdb")
const PLUM := Color("6b3f86")
const MIST := Color("efd2f5")
const WHITE := Color(1, 1, 1)
## Settings and the dialogue setup keep light text: the card turns plum behind them.
const DEEP := Color(0.25, 0.13, 0.31, 0.93)
const FONT := preload("res://world/ui/fonts/CelestiaMediumRedux.ttf")
@export var time_preference_path := TITLE_TIME.PATH
@export var load_scenery := false
@export var game_scene := GAME
var panel: Node3D
var camera: Camera3D
var xr_origin: XROrigin3D
var controllers: Array[XRController3D] = []
var pointer: MeshInstance3D
var _controller_pointers: Dictionary = {}
var xr_active := false
## Seated VR (world/launch_config.gd seated()): the headset view with keyboard and mouse. The
## mouse ray drives the panel; controllers are not built and not needed.
var seated := false
var phase: Dictionary
var status: Label
var enter_button: Button
var quit_button: Button
var settings_button: Button
var credits_button: Button
var new_game_button: Button
var load_button: Button
var _saves: GDScript
const SEASON_NAMES := ["Spring", "Summer", "Autumn", "Winter"]   # weather.gd SEASONS order
## Load game: saves grouped by world, newest first, a page at a time (rows carry screenshots).
const LOAD_LIST_TOP := 92.0
const LOAD_LIST_HEIGHT := 600.0
const LOAD_ROW_HEIGHT := 104.0
const LOAD_HEADER_HEIGHT := 46.0
var _load_page: Control
var _load_list: Control
var _load_rows: Array[Button] = []
var _load_entries: Array[Dictionary] = []
var _load_pages: Array = []
var _load_page_index := 0
var _load_back: Button
var _load_newer: Button
var _load_older: Button
var _load_status: Label
## What Continue resumes (save_catalogue.gd newest()), shown beside the button.
var _continue_entry: Dictionary = {}
var continue_preview: Control
var continue_line: Label
## New game → choose the opening: the Everfree forest or skip to Golden Oak (dev 2026-10-23).
## Replaced the unused season page; a new game always starts in spring.
var _opening_page: Control
var _opening_buttons: Array[Button] = []
var _opening_back: Button
## Home page and settings page share the panel; one is visible at a time.
var _home_page: Control
var _settings_page: Control
var _credits_page: Control
var _credits_back: Button
## The shared tabbed page (world/ui/settings_page.gd, rows from Settings.TABS).
var _settings_ui: Control
var _provider_page:Control
var _provider_button:Button
var _setup_window: Window
## AI context (world/ui/ai_context_page.gd): what ponies remember, what a request sends, errors.
var _context_page: Control
var _context_button: Button
var _setup_start := false
var ready_for_entry := false
var entering := false
var scenery: Node3D
var _clock: Dictionary = {}
var _saved_cap := 0
var _request := ""
var _request_kind := ""
var _asset_requests: Array[String] = []
var _focused := 0
var _stick_wait := 0.0
var _recenter_wait := 0.4
var _owner: XRController3D
var _exit_requested := false
## Set by world/ui/title_vista.gd: the menu floats over the live world instead of a backdrop.
var overlay_host: Node = null
## New game / Load game staged a different world: entering reloads the game scene.
var _staged := false
const COVER := preload("res://world/ui/loading_cover.gd")
const GAME_SCRIPT := "res://world/game.gd"
## Card timing, seconds: black, the logo fades in on black, a hold, then the black fades away and
## leaves the menu, whose own logo sits exactly where the faded-in one was (dev 2026-10-02:
## "everything should be black except for the HOME: EQUESTRIA already on the title menu ... fade
## in the text, then fade OUT the black"; the logo image replaced the two words on 2026-10-08).
const CARD_BLACK := 0.8
## Title music (dev 2026-10-23: "black screen, game loads, as it fades in My little POOOONyyyy"):
## the trailer's piano theme starts this far into the launch card, loops on the title, and fades
## out when the game is entered.
const THEME := preload("res://world/ui/music/title_theme.ogg")
const THEME_AT := 1.0
const THEME_FADE := 1.5
var _music: AudioStreamPlayer
const CARD_LOGO := 1.6
const CARD_HOLD := 0.8
const CARD_REVEAL := 1.4
## The home page's logo, in panel pixels: big (dev 2026-10-08: "make it much bigger"), above the
## buttons and reaching past the panel's top edge, so it is a sprite on the panel, not a control.
const LOGO_RECT := Rect2(0, -380, 900, 696)
var _card_active := false
var _logo: Sprite3D
var _card_sphere: MeshInstance3D
var _card_time := 0.0
var _menu_card: Panel

static func bypass_title(args: PackedStringArray) -> bool:
	for flag in ["--skip-title", "--capture", "--probe", "--perf", "--perf-stereo", "--profile-runtime"]:
		if flag in args: return true
	return false

## Idle titles only read checkpoint headers. Full validators pull in gameplay, so keep
## their script unloaded until a user chooses a checkpoint or confirms a new game.
func _save_api() -> GDScript:
	if _saves == null: _saves = load(SAVES_PATH) as GDScript
	return _saves

static func _header_number(value: Variant) -> float:
	return float(value) if (value is int or value is float) and is_finite(float(value)) else 0.0

func _catalogue() -> Array[Dictionary]:
	return CATALOGUE.catalogue()

func _ready() -> void:
	if overlay_host != null:
		_ready_overlay()
		return
	# Labs that watch the whole opening (tools/title/) live on the root, across the scene change.
	var args := preload("res://world/dev_tools.gd").user_args()
	var lab_at := args.find("--lab")
	if lab_at >= 0 and lab_at + 1 < args.size() and ResourceLoader.exists(args[lab_at + 1]) and get_tree().root.get_node_or_null("Lab") == null:
		var lab: Node = load(args[lab_at + 1]).new(); lab.name = "Lab"
		get_tree().root.add_child.call_deferred(lab)
	if bypass_title(preload("res://world/dev_tools.gd").user_args()):
		get_tree().change_scene_to_file.call_deferred(game_scene)
		return
	if game_scene == GAME and preload("res://world/launch_config.gd").should_ask():
		if not await _ask_play_mode(): return
	var iface := XRServer.find_interface("OpenXR")
	xr_active = iface != null and iface.is_initialized()
	seated = xr_active and preload("res://world/launch_config.gd").seated()
	if preload("res://world/launch_config.gd").require_vr() and not xr_active:
		preload("res://world/launch_config.gd").fail_required_vr(get_tree())
		return
	_saved_cap = Engine.max_fps
	if not xr_active: Engine.max_fps = 60
	_clock = {"hours": TimeOfDay.hours, "day": TimeOfDay.day, "paused": TimeOfDay.paused}
	TimeOfDay.paused = true
	_build_camera()
	scenery = BAKED.new()
	add_child(scenery)
	scenery.setup(camera)
	phase = {"name": scenery.view_name, "hours": TimeOfDay.hours}
	_build_panel()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if game_scene.is_empty():
		_finish_scenery() # Menu-only fixtures skip the animated card.
	else:
		panel.hide()
		_build_card()

## The launch card: everything black but the menu's own logo, which fades in where the menu draws
## it; then the black fades away around it. Desktop and headset alike: a black sphere around the
## camera, and the menu's logo sprite drawn over the sphere. The menu is in place (and hidden under the black) from the start.
## Desktop or VR each launch until remembered (world/ui/play_mode_prompt.gd). False when the
## game restarts into VR.
func _ask_play_mode() -> bool:
	var launch := preload("res://world/launch_config.gd")
	var prompt: CanvasLayer = preload("res://world/ui/play_mode_prompt.gd").new()
	add_child(prompt)
	var answer: Array = await prompt.chosen
	prompt.queue_free()
	var mode := str(answer[0])
	if bool(answer[1]):
		launch.write(mode)
		var settings: Node = get_tree().root.get_node_or_null("Settings")
		if settings != null: settings.set_value("vr/start_mode", mode)
	if mode == "off": return true
	launch.restart_in_vr(get_tree())
	return false

func _build_card() -> void:
	_card_active = true
	var mesh := SphereMesh.new(); mesh.radius = 0.6; mesh.height = 1.2; mesh.flip_faces = true
	var mat := StandardMaterial3D.new(); mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.BLACK; mat.no_depth_test = true; mat.render_priority = 100
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	_card_sphere = MeshInstance3D.new(); _card_sphere.mesh = mesh
	_card_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	camera.add_child(_card_sphere)
	_logo.modulate.a = 0.0
	panel.show()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _card_step(delta: float) -> void:
	_card_time += delta
	if _card_time >= THEME_AT: _start_music()
	# The headset pose settles in the first moments: re-centre the menu under the black.
	if xr_active and _recenter_wait > 0:
		_recenter_wait -= delta
		if _recenter_wait <= 0: recenter()
	var logo := smoothstep(CARD_BLACK, CARD_BLACK + CARD_LOGO, _card_time)
	var reveal_from := CARD_BLACK + CARD_LOGO + CARD_HOLD
	var black := 1.0 - smoothstep(reveal_from, reveal_from + CARD_REVEAL, _card_time)
	# The menu's own logo takes over where the home page shows; first launch opens the setup page
	# instead, so there the logo fades away with the black.
	var keep := 1.0 if _home_page != null and _home_page.visible else black
	_logo.modulate.a = logo * keep
	((_card_sphere.mesh as SphereMesh).material as StandardMaterial3D).albedo_color.a = black
	if _card_time >= reveal_from + CARD_REVEAL:
		_card_active = false
		_logo.visible = _home_page.visible
		if is_instance_valid(_card_sphere): _card_sphere.queue_free()
		_card_sphere = null
		_finish_scenery()

## Hosted over the live world by world/ui/title_vista.gd: its camera and controllers, no
## backdrop, no clock changes; Continue hands back to the vista.
func _ready_overlay() -> void:
	var game: Node = overlay_host.game
	xr_active = game.xr_active
	camera = game._find_camera(game.player)
	phase = {"name": str(overlay_host.view_name).capitalize(), "hours": TimeOfDay.hours}
	if xr_active:
		for side: String in ["Left", "Right"]:
			var controller: XRController3D = game.player.find_child("XRController" + side, true, false) as XRController3D
			if controller == null: continue
			controllers.append(controller)
			controller.button_pressed.connect(_controller_pressed.bind(controller))
			controller.button_released.connect(_controller_released.bind(controller))
		_make_pointer()
	elif camera is XRCamera3D:
		# Seated VR: the mouse ray points; this dot shows where, and the seated mouse dot
		# (world/ui/headset_cursor.gd) stays out of the way while the menu is up.
		_make_pointer()
		var cursor: Node = get_tree().get_first_node_in_group("headset_cursor")
		if cursor != null and cursor.has_method("hide_for"): cursor.hide_for(self)
	_build_panel()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_finish_scenery()

func _make_pointer() -> void:
	pointer = MeshInstance3D.new()
	# Seated VR moves it from mouse events, between physics ticks.
	if seated or not xr_active: pointer.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var dot := SphereMesh.new(); dot.radius = 0.006; dot.height = 0.012
	pointer.mesh = dot
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = PINK
	pointer.material_override = material
	pointer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(pointer); pointer.hide()
	for controller in controllers:
		var ray := CONTROLLER_POINTER.new()
		ray.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(ray); ray.set_color(WHITE)
		_controller_pointers[controller] = ray

func _build_camera() -> void:
	if xr_active:
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Quality.set_xr_mode(true)
		xr_origin = XROrigin3D.new()
		add_child(xr_origin)
		camera = XRCamera3D.new()
		xr_origin.add_child(camera)
		for side in ([] if seated else ["left_hand", "right_hand"]):
			var controller := XRController3D.new()
			controller.tracker = StringName(side)
			controller.pose = &"aim"
			xr_origin.add_child(controller)
			controllers.append(controller)
			controller.button_pressed.connect(_controller_pressed.bind(controller))
			controller.button_released.connect(_controller_released.bind(controller))
		_make_pointer()
	else:
		camera = Camera3D.new()
		camera.fov = 50.0
		add_child(camera)
		camera.position = Vector3.ZERO
	camera.near = 0.05
	camera.far = 9000.0
	camera.current = true

func _label(text: String, y: float, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.position = Vector2(66, y)
	label.size.x = 768
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", FONT)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	_page().add_child(label)
	return label


## Controls are built into whichever page is being assembled (home by default).
var _building: Control
func _page() -> Control:
	return _building if _building != null else panel.content

func _style(color: Color, border: Color, width := 3, radius := 38) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 30
	style.content_margin_right = 30
	style.shadow_color = Color(0.42, 0.22, 0.52, 0.18)
	style.shadow_size = 6
	style.shadow_offset = Vector2(0, 3)
	return style

## No card on the home page (the title words and buttons stand on the world), a light card behind
## the load and new-game lists, plum behind settings (their text is light).
func _set_card(light: bool) -> void:
	if _menu_card == null: return
	_menu_card.visible = not (light and _home_page != null and _home_page.visible)
	var style := _style(Color(1.0, 0.97, 1.0, 0.86) if light else DEEP, WHITE, 4, 40)
	style.shadow_color = Color(0.42, 0.22, 0.52, 0.28); style.shadow_size = 22; style.shadow_offset = Vector2.ZERO
	_menu_card.add_theme_stylebox_override("panel", style)

func _button(text: String, y: float, primary: bool) -> Button:
	var button := Button.new()
	button.text = text
	button.position = Vector2(170, y)
	button.size = Vector2(560, 100)
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_font_override("font", FONT)
	button.add_theme_font_size_override("font_size", 36)
	button.add_theme_color_override("font_color", WHITE if primary else PLUM)
	button.add_theme_color_override("font_hover_color", WHITE)
	button.add_theme_color_override("font_focus_color", WHITE)
	button.add_theme_color_override("font_pressed_color", WHITE)
	button.add_theme_color_override("font_disabled_color", Color(PLUM, 0.4))
	button.add_theme_stylebox_override("normal", _style(LILAC, WHITE, 4) if primary else _style(Color(1, 1, 1, 0.92), MIST))
	button.add_theme_stylebox_override("hover", _style(PINK, WHITE, 4))
	button.add_theme_stylebox_override("pressed", _style(LILAC.darkened(0.12), WHITE, 4))
	button.add_theme_stylebox_override("focus", _style(PINK, WHITE, 4))
	button.add_theme_stylebox_override("disabled", _style(Color(1, 1, 1, 0.55), MIST))
	button.mouse_entered.connect(panel.refresh)
	button.mouse_exited.connect(panel.refresh)
	button.focus_entered.connect(panel.refresh)
	button.focus_exited.connect(panel.refresh)
	_page().add_child(button)
	return button

func _build_panel() -> void:
	panel = PANEL.new()
	panel.name = "HomePanel"
	add_child(panel)
	_menu_card = Panel.new()
	_menu_card.size = PANEL.PIXELS
	_menu_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.content.add_child(_menu_card)
	_set_card(true)
	_home_page = Control.new(); _home_page.name = "Home"; _home_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_home_page.size = PANEL.PIXELS
	panel.content.add_child(_home_page)
	_building = _home_page
	# The game logo (world/ui/title/logo.png, dev 2026-10-08), no tagline (dev 2026-09-30): fitted
	# into LOGO_RECT in the panel's plane, a hair in front, over the launch card's black sphere.
	_logo = Sprite3D.new(); _logo.texture = COVER.LOGO
	var logo_size := Vector2(COVER.LOGO.get_size())
	_logo.pixel_size = PANEL.PIXEL_SIZE * minf(LOGO_RECT.size.x / logo_size.x, LOGO_RECT.size.y / logo_size.y)
	var logo_centre := (LOGO_RECT.get_center() - Vector2(PANEL.PIXELS) * 0.5) * PANEL.PIXEL_SIZE
	_logo.position = Vector3(logo_centre.x, -logo_centre.y, 0.004)
	_logo.no_depth_test = true; _logo.render_priority = 102; _logo.shaded = false
	_logo.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED; _logo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	panel.add_child(_logo)
	# Only the home page shows it; during the launch card the card fades it instead.
	_home_page.visibility_changed.connect(func() -> void: if not _card_active: _logo.visible = _home_page.visible)
	_continue_entry = CATALOGUE.newest(_catalogue())
	var has_checkpoint := not _continue_entry.is_empty()
	enter_button = _button("Continue" if has_checkpoint else "Play", 330, true)
	enter_button.disabled = true
	enter_button.pressed.connect(_enter_pressed)
	enter_button.size.y = 90
	if has_checkpoint: _build_continue_preview()
	new_game_button = _button("New game", 466, false)
	new_game_button.pressed.connect(_new_game)
	load_button = _button("Load game", 542, false)
	load_button.pressed.connect(_open_load)
	settings_button = _button("Settings", 618, false)
	settings_button.pressed.connect(_open_settings)
	quit_button = _button("Quit", 694, false)
	quit_button.pressed.connect(_quit)
	credits_button = _button("Credits", 694, false)
	credits_button.pressed.connect(_open_credits)
	credits_button.size.x = 270
	quit_button.position.x = 460; quit_button.size.x = 270
	for b in [new_game_button, load_button, settings_button, credits_button, quit_button]: b.size.y = 68
	# Only loading and problems are ever written here.
	status = _label("", 770, 26, WHITE)
	status.add_theme_color_override("font_outline_color", PLUM); status.add_theme_constant_override("outline_size", 8)
	if xr_active and not seated:
		var hint := _label("Point and pull the trigger", 806, 22, WHITE)
		hint.add_theme_color_override("font_outline_color", PLUM); hint.add_theme_constant_override("outline_size", 8)
	_building = null
	_set_card(true)
	_build_settings_page()
	_build_credits_page()
	_build_load_page()
	_build_opening_page()
	_setup_start = not has_checkpoint
	_provider_page=preload("res://world/ui/provider_settings.gd").new()
	panel.content.add_child(_provider_page);_provider_page.setup(panel)
	_provider_page.closed.connect(_close_provider)
	_context_page = preload("res://world/ui/ai_context_page.gd").new()
	panel.content.add_child(_context_page); _context_page.setup(panel)
	_context_page.closed.connect(_close_context)
	_place_panel()
	if not bool(Settings.get_value("setup/completed")) and _installation_problem().is_empty():
		_provider_page.setup_mode = true
		_open_provider()
	panel.refresh()


## The screenshot of what Continue resumes and one line about it, beside the Continue button
## (dev 2026-10-15: "its really unclear what save games are what").
func _build_continue_preview() -> void:
	enter_button.position.x = 342; enter_button.size.x = 388
	continue_preview = _thumbnail(_page(), Rect2(170, 330, 160, 90), str(_continue_entry.get("preview", "")))
	continue_line = Label.new()
	continue_line.text = CATALOGUE.line(_continue_entry) if not bool(_continue_entry.newer) else "Made by a newer version of the game · " + str(_continue_entry.world_name)
	continue_line.position = Vector2(40, 426); continue_line.size = Vector2(820, 34)
	continue_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	continue_line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	continue_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	continue_line.add_theme_font_override("font", FONT)
	continue_line.add_theme_font_size_override("font_size", 25)
	continue_line.add_theme_color_override("font_color", WHITE)
	continue_line.add_theme_color_override("font_outline_color", PLUM); continue_line.add_theme_constant_override("outline_size", 7)
	_page().add_child(continue_line)


## A framed screenshot (or a soft placeholder when the save has none: old saves, headsets).
func _thumbnail(parent: Control, rect: Rect2, path: String) -> Control:
	var frame := Panel.new()
	frame.position = rect.position; frame.size = rect.size
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := _style(Color(MIST, 0.95), WHITE, 3, 12)
	style.shadow_size = 4
	frame.add_theme_stylebox_override("panel", style)
	parent.add_child(frame)
	var texture := PREVIEW.texture(path)
	if texture != null:
		var picture := TextureRect.new()
		picture.texture = texture
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		picture.position = Vector2(3, 3); picture.size = rect.size - Vector2(6, 6)
		picture.clip_contents = true
		picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(picture)
	else:
		var none := Label.new(); none.text = "No picture"
		none.size = rect.size; none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; none.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		none.add_theme_font_override("font", FONT); none.add_theme_font_size_override("font_size", 18)
		none.add_theme_color_override("font_color", Color(PLUM, 0.7)); none.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(none)
	return frame


## Load page: every checkpoint grouped by world (the world played last first), newest first
## inside each, a page at a time; the first row is what Continue resumes. Picking one stages it
## and enters.
func _build_load_page() -> void:
	_load_page = Control.new(); _load_page.name = "LoadGame"; _load_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_load_page.size = PANEL.PIXELS
	_load_page.visible = false
	panel.content.add_child(_load_page)
	_building = _load_page
	_label("Load game", 30, 44, LILAC)
	_load_list = Control.new(); _load_list.name = "Rows"; _load_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_load_list.position = Vector2(0, LOAD_LIST_TOP); _load_list.size = Vector2(PANEL.PIXELS.x, LOAD_LIST_HEIGHT)
	_load_page.add_child(_load_list)
	var y := LOAD_LIST_TOP + LOAD_LIST_HEIGHT + 8
	_load_newer = _button("Newer", y, false)
	_load_newer.position.x = 66; _load_newer.size = Vector2(240, 66)
	_load_newer.pressed.connect(_turn_load_page.bind(-1))
	_load_back = _button("Back", y, true)
	_load_back.position.x = 330; _load_back.size = Vector2(240, 66)
	_load_back.pressed.connect(_close_load)
	_load_older = _button("Older", y, false)
	_load_older.position.x = 594; _load_older.size = Vector2(240, 66)
	_load_older.pressed.connect(_turn_load_page.bind(1))
	_load_status = _label("", y + 74, 22, PLUM)
	_building = null


func _open_load() -> void:
	if not ready_for_entry: return
	var entries := _catalogue()
	var groups := CATALOGUE.groups(entries)
	# Pages of {header} / {entry} items; a world continued on a new page repeats its header.
	_load_entries.clear(); _load_pages.clear()
	var page: Array = []
	var used := 0.0
	for group: Dictionary in groups:
		var header := {"group": group, "continued": false}
		if used + LOAD_HEADER_HEIGHT + LOAD_ROW_HEIGHT > LOAD_LIST_HEIGHT and not page.is_empty():
			_load_pages.append(page); page = []; used = 0.0
		page.append(header); used += LOAD_HEADER_HEIGHT
		for entry: Dictionary in group.entries:
			if used + LOAD_ROW_HEIGHT > LOAD_LIST_HEIGHT:
				_load_pages.append(page); page = [{"group": group, "continued": true}]; used = LOAD_HEADER_HEIGHT
			page.append({"entry": entry}); used += LOAD_ROW_HEIGHT
			_load_entries.append(entry)
	if not page.is_empty(): _load_pages.append(page)
	_home_page.visible = false
	_load_page.visible = true
	_set_card(true)
	_show_load_page(0)
	_focused = 0
	var first: Control = _load_rows[0] if not _load_rows.is_empty() else _load_back
	first.grab_focus()
	panel.refresh()


func _turn_load_page(step: int) -> void:
	var target := clampi(_load_page_index + step, 0, maxi(0, _load_pages.size() - 1))
	if target == _load_page_index: return
	_show_load_page(target)
	var focus: Control = (_load_rows[0] if step > 0 else _load_rows[-1]) if not _load_rows.is_empty() else _load_back
	focus.grab_focus()
	_focused = maxi(0, _focus_list().find(focus))
	panel.refresh()


func _show_load_page(index: int) -> void:
	_load_page_index = index
	for child in _load_list.get_children(): child.free()
	_load_rows.clear()
	var y := 0.0
	var items: Array = _load_pages[index] if index < _load_pages.size() else []
	_building = _load_list
	for item: Dictionary in items:
		if item.has("group"):
			_load_header(item.group, bool(item.continued), y); y += LOAD_HEADER_HEIGHT
		else:
			_load_rows.append(_load_row(item.entry, y)); y += LOAD_ROW_HEIGHT
	_building = null
	_load_newer.visible = index > 0
	_load_older.visible = index < _load_pages.size() - 1
	var worlds := 0
	for page: Array in _load_pages:
		for item: Dictionary in page:
			if item.has("group") and not bool(item.continued): worlds += 1
	if _load_entries.is_empty(): _load_status.text = "No saved games yet"
	else:
		_load_status.text = "%d saved games in %d world%s" % [_load_entries.size(), worlds, "" if worlds == 1 else "s"]
		if _load_pages.size() > 1: _load_status.text += " · page %d of %d" % [index + 1, _load_pages.size()]
	panel.refresh()


func _load_header(group: Dictionary, continued: bool, y: float) -> void:
	var label := Label.new()
	var details: Array[String] = [str(group.form)]
	if not str(group.world_started).is_empty(): details.append("started " + str(group.world_started))
	label.text = str(group.world_name) + (" (continued)" if continued else "") + "  —  " + " · ".join(details)
	label.position = Vector2(70, y + 6); label.size = Vector2(760, 36)
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font", FONT)
	label.add_theme_font_size_override("font_size", 27)
	label.add_theme_color_override("font_color", LILAC)
	_load_list.add_child(label)


## One save: screenshot, what kind of save and when in the game, where and as whom, when saved.
func _load_row(entry: Dictionary, y: float) -> Button:
	var button := _button("", y, false)
	button.position.x = 66; button.size = Vector2(768, LOAD_ROW_HEIGHT - 8)
	button.pressed.connect(_pick_entry.bind(entry))
	_thumbnail(button, Rect2(8, 7, 146, 82), str(entry.get("preview", "")))
	var lines: Array = [
		[CATALOGUE.kind_text(entry) + " · " + CATALOGUE.game_time_text(entry), 25, PLUM, 6.0],
		[" · ".join(([str(entry.place)] if not str(entry.place).is_empty() else []) + [str(entry.form)]), 21, PLUM, 38.0],
		["Saved " + CATALOGUE.when_text(float(entry.saved_at)) + " · " + CATALOGUE.play_text(float(entry.play_seconds)), 19, Color(PLUM, 0.72), 64.0]]
	for spec: Array in lines:
		var label := Label.new(); label.text = str(spec[0])
		label.position = Vector2(170, float(spec[3])); label.size = Vector2(586, 30)
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_override("font", FONT)
		label.add_theme_font_size_override("font_size", int(spec[1]))
		label.add_theme_color_override("font_color", spec[2])
		button.add_child(label)
	if bool(entry.archived): button.modulate.a = 0.85
	return button


func _pick_entry(entry: Dictionary) -> void:
	if entering: return
	var saves := _save_api()
	if saves == null or not saves.stage(entry):
		_load_status.text = "That save cannot be loaded (invalid or from another version)."
		panel.refresh()
		return
	_load_status.text = "Loading %s…" % CATALOGUE.kind_text(entry).to_lower()
	_staged = true
	enter_game()


## A new game always starts in spring (dev 2026-10-01). New game first asks how it opens
## (dev 2026-10-23: the Everfree skip must be offered on New game, desktop and VR alike).
func _new_game() -> void:
	if entering or not ready_for_entry: return
	_open_opening()


## The Play/Continue button. With no save to continue, Play starts a new game, so it asks how
## it opens first. enter_game() itself stays direct for fixtures and the setup flow; the
## creator panel (world/life/pony_creator.gd) offers the same choice on desktop.
func _enter_pressed() -> void:
	if is_instance_valid(_setup_window) or entering or not ready_for_entry: return
	if bool(Settings.get_value("setup/completed")) and not _staged and game_scene == GAME and CATALOGUE.newest(_catalogue()).is_empty():
		_open_opening(); return
	enter_game()


func _open_opening() -> void:
	_home_page.visible = false
	_opening_page.visible = true
	_set_card(true)
	# Focus starts on the current Settings → World → Opening choice.
	_focused = 1 if str(Settings.get_value(OPENING_KEY)) == "skip" else 0
	_opening_buttons[_focused].grab_focus()
	panel.refresh()


const OPENING_KEY := "world/opening"
const OPENINGS := [["play", "Everfree forest opening\n(Tutorial/controls, recommended!)"], ["skip", "Skip, wake in Golden Oak"]]

## Opening page: New game asks whether to play the forest opening or skip it. The answer is
## Settings "world/opening" (read by world/life/arrival_story.gd), so it stays the default.
func _build_opening_page() -> void:
	_opening_page = Control.new(); _opening_page.name = "NewGameOpening"; _opening_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_opening_page.size = PANEL.PIXELS
	_opening_page.visible = false
	panel.content.add_child(_opening_page)
	_building = _opening_page
	_label("New game", 52, 44, LILAC)
	_label("How does it start?", 112, 28, PLUM)
	var y := 200.0
	for option: Array in OPENINGS:
		var button := _button(str(option[1]), y, false)
		button.size.y = 120 if str(option[0]) == "play" else 84
		if str(option[0]) == "play": button.add_theme_font_size_override("font_size", 30)
		button.pressed.connect(_choose_opening.bind(str(option[0])))
		_opening_buttons.append(button)
		y += button.size.y + 16
	_opening_back = _button("Back", y + 16, true)
	_opening_back.size.y = 76
	_opening_back.pressed.connect(_close_opening)
	_building = null


func _close_opening() -> void:
	_opening_page.visible = false
	_home_page.visible = true
	_set_card(true)
	_focused = 1
	new_game_button.grab_focus()
	panel.refresh()


func _opening_open() -> bool:
	return _opening_page != null and _opening_page.visible


func _choose_opening(opening: String) -> void:
	if entering or not ready_for_entry: return
	Settings.set_value(OPENING_KEY, opening)
	_start_new_game(0)


## The season follows the day count (world/weather/weather.gd: day / season length), so a
## new game starts on the first day of the chosen season. New games pass spring (0).
func _start_new_game(season: int) -> void:
	if entering or not ready_for_entry: return
	_setup_start = false
	var start_day: int = season * maxi(1, int(Settings.season_days()))
	if not _clock.is_empty(): _clock.day = start_day
	else: TimeOfDay.day = start_day
	var saves := _save_api()
	if saves == null:
		_load_failed("game"); return
	var world: String = saves.stage_new_game(start_day)
	_staged = true
	status.text = "New game (%s): %s" % [SEASON_NAMES[season], world]
	_opening_page.visible = false
	_home_page.visible = true
	enter_game()


func _close_load() -> void:
	_load_page.visible = false
	_home_page.visible = true
	_set_card(true)
	_focused = 2
	load_button.grab_focus()
	panel.refresh()


func _load_open() -> bool:
	return _load_page != null and _load_page.visible


## Settings page: the shared tabbed page, plus the dialogue provider button. Values live
## in the Settings autoload and apply immediately.
func _build_settings_page() -> void:
	_settings_page = Control.new(); _settings_page.name = "Settings"; _settings_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_settings_page.size = PANEL.PIXELS
	_settings_page.visible = false
	panel.content.add_child(_settings_page)
	_settings_ui = preload("res://world/ui/settings_page.gd").new()
	_settings_ui.position = Vector2(40, 28)
	_settings_page.add_child(_settings_ui)
	_settings_ui.setup(Vector2(820, 790), 22, "Back", xr_active and not seated)
	_settings_ui.redraw = panel.refresh
	_settings_ui.back_requested.connect(_close_settings)
	_context_button = Button.new(); _context_button.text = "AI context"
	_context_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL; _context_button.add_theme_font_size_override("font_size", 22)
	_context_button.pressed.connect(_open_context)
	_context_button.focus_entered.connect(panel.refresh)
	_settings_ui.footer.add_child(_context_button)


func _open_settings() -> void:
	_set_card(false)
	_home_page.visible = false
	_settings_page.visible = true
	Settings.message = ""
	_settings_ui.refresh()
	_focused = 0
	(_settings_ui.focusables()[0] as Control).grab_focus()
	panel.refresh()


func _close_settings() -> void:
	_settings_page.visible = false
	_home_page.visible = true
	_set_card(true)
	_focused = 0
	settings_button.grab_focus()
	panel.refresh()


func _settings_open() -> bool:
	return _settings_page != null and _settings_page.visible

func _build_credits_page() -> void:
	_credits_page = preload("res://world/ui/credits_page.gd").new(); _credits_page.name = "Credits"
	panel.content.add_child(_credits_page)
	_credits_page.setup(PANEL.PIXELS)
	_credits_page.redraw = panel.refresh
	_credits_back = _credits_page.back_button
	_credits_page.back_requested.connect(_close_credits)
	_credits_page.hide()

func _credits_open() -> bool:
	return _credits_page != null and _credits_page.visible

func _open_credits() -> void:
	_home_page.hide(); _credits_page.show(); _set_card(true)
	_focused = 0; _credits_back.grab_focus(); panel.refresh()

func _close_credits() -> void:
	_credits_page.hide(); _home_page.show(); _set_card(true)
	_focused = _focus_list().find(credits_button)
	credits_button.grab_focus(); panel.refresh()

func _open_provider()->void:
	if _provider_page.setup_mode and OS.get_name() in ["Windows", "Linux", "macOS"]:
		if is_instance_valid(_setup_window): _setup_window.show(); return
		_setup_window = preload("res://world/ui/ai_setup_window.gd").new()
		add_child(_setup_window); _setup_window.close_requested.connect(_quit)
		_setup_window.open(_provider_page)
		status.text = "Complete AI setup in the desktop window."
		panel.press(false); panel.refresh(); return
	if not _provider_page.setup_mode:
		_open_settings(); _settings_ui.show_tab("AI Settings"); return
	_set_card(false)
	_settings_page.hide();_home_page.hide();_provider_page.open();_focused=0;panel.refresh()

func _close_provider()->void:
	if _provider_page.setup_mode:
		if not bool(Settings.get_value("setup/completed")): _quit(); return
		if is_instance_valid(_setup_window):
			_provider_page.reparent(panel.content); _provider_page.panel = panel
			_provider_page.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
			_provider_page.size = Vector2(900,840)
			_setup_window.hide(); _setup_window.queue_free(); _setup_window = null
		status.text = ""
		_provider_page.setup_mode = false
		_setup_start = CATALOGUE.newest(_catalogue()).is_empty()
		_provider_page.hide(); _home_page.show(); _set_card(true); enter_button.grab_focus(); panel.refresh()
		return
	_provider_page.hide(); _open_settings(); _settings_ui.show_tab("AI Settings")


func _open_context() -> void:
	_set_card(false)
	_settings_page.hide(); _home_page.hide(); _context_page.open(); _focused = 0; panel.refresh()

func _close_context() -> void:
	_context_page.hide(); _settings_page.show(); _set_card(false); _context_button.grab_focus()
	_focused = maxi(0, _settings_ui.focusables().find(_context_button)); panel.refresh()


func _focus_list() -> Array:
	if _context_page != null and _context_page.visible: return _context_page.controls
	if _provider_page!=null and _provider_page.visible:return _provider_page.controls
	if _credits_open(): return _credits_page.focusables()
	if _settings_open(): return _settings_ui.focusables()
	if _opening_open(): return _opening_buttons + [_opening_back]
	if _load_open():
		var visible_rows: Array = _load_rows.duplicate()
		for pager: Button in [_load_newer, _load_back, _load_older]:
			if pager.visible: visible_rows.append(pager)
		return visible_rows
	return [enter_button, new_game_button, load_button, settings_button, credits_button, quit_button]

func _place_panel() -> void:
	if overlay_host != null:
		# Level in front of the eyes, a little left and low so the view stays in sight.
		var facing := Basis(Vector3.UP, camera.global_rotation.y)
		panel.global_transform = Transform3D(facing, camera.global_position + facing * Vector3(-0.95, -0.2, -2.3))
		return
	panel.global_transform = camera.global_transform
	panel.global_position = camera.global_transform * Vector3(-0.68, -0.18, -2.25)

func recenter() -> void:
	if overlay_host != null:
		_place_panel(); return
	if xr_origin == null: return
	# Recenter the spatial menu; the baked world retains its stable heading.
	_place_panel()

func _request_asset(path: String, kind: String) -> void:
	var error := ResourceLoader.load_threaded_request(path, "PackedScene")
	if error != OK:
		_load_failed(kind)
		return
	_request = path
	_request_kind = kind
	if path not in _asset_requests: _asset_requests.append(path)

func _poll_asset() -> void:
	if _request.is_empty(): return
	var progress: Array = []
	var state := ResourceLoader.load_threaded_get_status(_request, progress)
	if state == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		status.text = "Entering Equestria… %d%%" % int(float(progress[0]) * 100) if not progress.is_empty() else "Entering Equestria…"
		panel.refresh()
		return
	var path := _request
	var kind := _request_kind
	_request = ""
	if state != ResourceLoader.THREAD_LOAD_LOADED:
		if state == ResourceLoader.THREAD_LOAD_FAILED: ResourceLoader.load_threaded_get(path)
		_asset_requests.erase(path)
		_load_failed(kind)
		return
	var packed := ResourceLoader.load_threaded_get(path) as PackedScene
	_asset_requests.erase(path)
	if packed == null:
		_load_failed(kind)
		return
	set_process(false)
	_finish_entry.call_deferred(packed)

var _download: Node

func _installation_problem() -> String:
	return PACKS.installation_problem(OS.has_feature("android") and OS.has_feature("template"), ResourceLoader.exists)

func _start_music() -> void:
	if _music != null: return
	var stream := THEME.duplicate() as AudioStreamOggVorbis
	stream.loop = true
	_music = AudioStreamPlayer.new(); _music.name = "TitleMusic"; _music.stream = stream
	Settings.route(_music, "Music")
	add_child(_music); _music.play()

func _fade_music() -> void:
	if _music == null or not _music.playing: return
	create_tween().tween_property(_music, "volume_db", -40.0, THEME_FADE)

func _finish_scenery() -> void:
	_start_music()   # a title without the launch card still plays it
	var problem := _installation_problem()
	ready_for_entry = problem.is_empty()
	enter_button.disabled = not ready_for_entry
	new_game_button.disabled = not ready_for_entry
	load_button.disabled = not ready_for_entry
	if not ready_for_entry: _focused = 3 # Settings stays usable while data is absent.
	_focus_button(0)
	status.text = problem
	panel.refresh()
	# Quest: fetch this version's data from its GitHub release, then reload the title with it.
	if not ready_for_entry and OS.has_feature("android") and _download == null:
		_download = preload("res://world/ui/quest_data_download.gd").new()
		add_child(_download)
		_download.progress.connect(func(text: String) -> void: status.text = text; panel.refresh())
		_download.finished.connect(func() -> void: get_tree().reload_current_scene.call_deferred())
		_download.start()
	print("TITLE READY phase=%s hours=%.2f spatial_panel=true xr=%s" % [phase.name, phase.hours, xr_active] if ready_for_entry else "TITLE DATA MISSING: gameplay entry disabled")

func _load_failed(kind: String) -> void:
	entering = false
	ready_for_entry = true
	enter_button.disabled = false
	status.text = "Could not enter. Please try again."
	panel.refresh()
	push_warning("[title] Could not load %s" % kind)

func enter_game() -> void:
	if is_instance_valid(_setup_window): return
	if entering or not ready_for_entry: return
	if not bool(Settings.get_value("setup/completed")):
		_provider_page.setup_mode = true; _open_provider(); return
	_fade_music()
	if not _staged and game_scene == GAME:
		# The same entry the home page previews and every list shows first.
		var newest := CATALOGUE.newest(_catalogue())
		_setup_start = newest.is_empty()
		if not newest.is_empty():
			var saves := _save_api()
			if saves == null or not saves.stage(newest):
				status.text = "The most recent save could not be loaded. Use Load game to choose another."
				panel.refresh()
				return
			_staged = true
	if _setup_start and ready_for_entry:
		_setup_start = false
		_start_new_game(0)
		return
	if entering or not ready_for_entry: return
	entering = true
	enter_button.disabled = true
	status.text = "Entering Equestria…"
	panel.refresh()
	if overlay_host != null:
		if _staged:
			# A different world (new game, another save): boot it fresh, no title again.
			get_tree().change_scene_to_file.call_deferred(GAME)
		else:
			overlay_host.continue_game()
		return
	# Nothing from the world scene is requested until this explicit action.
	_request_asset(game_scene, "game")

func _finish_entry(packed: PackedScene) -> void:
	_restore_clock()
	# The world script is first loaded after entry, never while the title idles.
	if game_scene == GAME:
		var game_script := load(GAME_SCRIPT) as GDScript
		if game_script != null: game_script.set("title_mode", false)
	var error := get_tree().change_scene_to_packed(packed)
	if error != OK:
		set_process(true)
		_load_failed("game")

func _process(delta: float) -> void:
	if _card_active:
		_card_step(delta); return
	if panel == null: return
	_poll_asset()
	if is_instance_valid(_setup_window): return
	if not xr_active: return
	if _recenter_wait > 0:
		_recenter_wait -= delta
		if _recenter_wait <= 0: recenter()
	# Seated: no controllers. Pointing them every frame would clear the mouse hover (point_at
	# (-1, -1)), so the mouse path in _input drives the panel instead.
	if seated: return
	_stick_wait = maxf(0, _stick_wait - delta)
	if _owner != null and not _owner.get_has_tracking_data():
		panel.point_at(Vector2(-1, -1))
		panel.press(false)
		_owner = null
	var hit := Vector2(-1, -1)
	for controller in controllers:
		var ray: Node3D = _controller_pointers[controller]
		if not controller.get_has_tracking_data():
			ray.hide()
			continue
		var stick := controller.get_vector2("primary")
		if absf(stick.y) > 0.65 and _stick_wait <= 0:
			_focus_button(1 if stick.y < 0 else -1)
			_stick_wait = 0.3
		var candidate: Vector2 = panel.ray_to_pixel(controller.global_position, -controller.global_basis.z)
		if candidate.x >= 0: ray.aim(controller.global_position, panel.pixel_to_world(candidate))
		else: ray.hide()
		if _owner != null and controller != _owner: continue
		if candidate.x >= 0 and hit.x < 0:
			hit = candidate
	panel.point_at(hit)

func _focus_button(step: int) -> void:
	if _load_open() and not _load_rows.is_empty():
		# Past the last row of a page the next page opens instead of wrapping (and back up).
		if step > 0 and _focused == _load_rows.size() - 1 and _load_page_index < _load_pages.size() - 1:
			_turn_load_page(1); return
		if step < 0 and _focused == 0 and _load_page_index > 0:
			_turn_load_page(-1); return
	var buttons: Array = _focus_list()
	_focused = wrapi(_focused + step, 0, buttons.size())
	var button: Control = buttons[_focused]
	if button is Button and button.disabled:
		_focused = wrapi(_focused + (1 if step >= 0 else -1), 0, buttons.size())
		button = buttons[_focused]
	button.grab_focus()
	panel.refresh()

func _controller_pressed(action: StringName, controller: XRController3D) -> void:
	if panel == null or _card_active or entering or is_instance_valid(_setup_window): return
	if action == &"primary_click": recenter()
	if action == &"grip_click" and _provider_page.visible:_close_provider();return
	if action == &"grip_click" and _context_page != null and _context_page.visible: _close_context(); return
	if action == &"grip_click" and _settings_open(): _close_settings(); return
	if action == &"grip_click" and _credits_open(): _close_credits(); return
	if action == &"grip_click" and _load_open(): _close_load(); return
	if action == &"grip_click" and _opening_open(): _close_opening(); return
	if action != &"trigger_click" or _owner != null: return
	if not controller.get_has_tracking_data(): return
	var pixel: Vector2 = panel.ray_to_pixel(controller.global_position, -controller.global_basis.z)
	if pixel.x >= 0:
		_owner = controller
		panel.point_at(pixel)
		panel.press(true)

func _controller_released(action: StringName, controller: XRController3D) -> void:
	if action == &"trigger_click" and _owner == controller:
		panel.point_at(panel.ray_to_pixel(controller.global_position, -controller.global_basis.z) if controller.get_has_tracking_data() else Vector2(-1, -1))
		panel.press(false)
		_owner = null

func _input(event: InputEvent) -> void:
	if panel == null or _card_active or entering or is_instance_valid(_setup_window): return
	if ((_provider_page!=null and _provider_page.visible) or (_settings_open() and _settings_ui.current_tab() == "AI Settings")) and event is InputEventKey:
		if event.pressed and not event.echo and event.keycode==KEY_ESCAPE:
			if _settings_open(): _close_settings()
			else: _close_provider()
		elif event.pressed and not event.echo and event.keycode==KEY_TAB:_focus_button(-1 if event.shift_pressed else 1)
		else:panel.send_key(event)
		get_viewport().set_input_as_handled();return
	if _settings_open() and event is InputEventKey and not _settings_ui.capturing.is_empty():
		panel.send_key(event); get_viewport().set_input_as_handled(); return
	if xr_active and not seated:return
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		var pixel: Vector2 = panel.ray_to_pixel(camera.project_ray_origin(event.position), camera.project_ray_normal(event.position))
		panel.point_at(pixel)
		if pointer != null:
			pointer.visible = pixel.x >= 0
			if pointer.visible: pointer.global_position = panel.pixel_to_world(pixel)
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			panel.press(event.pressed)
		elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and _load_open():
			_turn_load_page(1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1)
		elif event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and pixel.x >= 0:
			# The settings list scrolls with the wheel.
			var wheel := event.duplicate() as InputEventMouseButton
			wheel.position = pixel; wheel.global_position = pixel
			panel.viewport.push_input(wheel, true); panel.refresh()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		if event.pressed and not event.echo and event.keycode in [KEY_UP, KEY_DOWN, KEY_TAB]:
			_focus_button(1 if event.keycode != KEY_UP else -1)
		elif event.pressed and not event.echo and event.keycode == KEY_HOME and camera is XRCamera3D:
			# Seated VR: Home re-centres the view, then the menu in front of it.
			XRServer.center_on_hmd(XRServer.RESET_BUT_KEEP_TILT, false)
			recenter()
		elif event.pressed and not event.echo and _context_page != null and _context_page.visible and event.keycode == KEY_ESCAPE:
			_close_context()
		elif event.pressed and not event.echo and _settings_open() and event.keycode == KEY_ESCAPE:
			_close_settings()
		elif event.pressed and not event.echo and _credits_open() and event.keycode == KEY_ESCAPE:
			_close_credits()
		elif event.pressed and not event.echo and _load_open() and event.keycode == KEY_ESCAPE:
			_close_load()
		elif event.pressed and not event.echo and _opening_open() and event.keycode == KEY_ESCAPE:
			_close_opening()
		else:
			panel.send_key(event)
		get_viewport().set_input_as_handled()

func _quit() -> void:
	if _exit_requested: return
	_exit_requested = true
	get_tree().quit()

func _restore_clock() -> void:
	if _clock.is_empty(): return
	# Child exit notifications precede ours. Disconnect the presentation sky before
	# restoring shared time, including when the window closes during loading.
	var sky := get_node_or_null("WorldEnvironment")
	if sky != null:
		var callback := Callable(sky, "_on_time_changed")
		if TimeOfDay.time_changed.is_connected(callback): TimeOfDay.time_changed.disconnect(callback)
	TimeOfDay.day = _clock.day
	TimeOfDay.hours = _clock.hours
	TimeOfDay.paused = _clock.paused
	# The player's own FPS cap (Settings), not whatever the menu found at start.
	Engine.max_fps = Settings.fps_cap()
	_clock.clear()

func _exit_tree() -> void:
	_restore_clock()
	# Collect a requested resource even when the window closes mid-load.
	for path in _asset_requests:
		if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED or ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS or ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_FAILED:
			ResourceLoader.load_threaded_get(path)
	_asset_requests.clear(); _request = ""
