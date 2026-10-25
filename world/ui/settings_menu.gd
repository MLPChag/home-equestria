extends Node3D
const DESKTOP_OWNER := preload("res://player/desktop_action_owner.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const VIEW := preload("res://world/player_view.gd")
## In-game settings World Panel: the shared settings page (world/ui/settings_page.gd,
## rows from Settings.TABS). Desktop: F7. VR: left controller menu button, right ray +
## trigger; in VR it also carries Continue / Saved games / Quit, since the desktop Escape
## pause menu has no headset counterpart. Claims both hands and movement like the saves
## panel and restores them on close.
var ui: Node
var panel: Node3D
var pointer: Node3D
var content: Control
var canvas: CanvasLayer
var page: Control
## world/ui/pause_menu.gd: quit / saves actions offered on the VR panel.
var pause: Node
## VR only: the desktop pause menu's AI & voice and Support pages live on this panel too
## (dev 2026-09-29: "add all the settings on desktop to vr. ALL"), with an on-panel keyboard.
var provider: Control
var keyboard: Control
var support: VBoxContainer
var credits: Control
var _support_status: Label
var _page_name := "settings"
var opened := false
var _armed := false
var _mouse_mode: int
var _old_lock := false
var _input_states: Dictionary = {}
var _old_physics := true

func setup(inventory_ui: Node, pause_menu: Node = null) -> void:
	ui = inventory_ui; pause = pause_menu
	if ui._desktop:
		canvas = CanvasLayer.new(); canvas.layer = 150; add_child(canvas)
		content = PanelContainer.new(); content.custom_minimum_size = Vector2(900, 820); canvas.add_child(content); canvas.hide()
	else:
		panel = preload("res://world/ui/spatial_menu_panel.gd").new(); add_child(panel); panel.hide(); content = panel.content
		pointer = preload("res://world/ui/controller_pointer.gd").new(); add_child(pointer)
	_rebuild()

func _rebuild() -> void:
	for child in content.get_children(): child.free()
	page = preload("res://world/ui/settings_page.gd").new()
	if ui._desktop:
		page.setup(Vector2(880, 800), 20, "Close · F7")
	else:
		var background := Panel.new(); background.mouse_filter = Control.MOUSE_FILTER_IGNORE
		background.size = Vector2(900, 840); content.add_child(background)
		page.position = Vector2(25, 20)
		page.setup(Vector2(850, 800), 22, "Continue", true)
		page.redraw = panel.refresh
	content.add_child(page)
	page.back_requested.connect(close)
	credits = preload("res://world/ui/credits_page.gd").new()
	content.add_child(credits); credits.setup(Vector2(880, 800), 22)
	if panel != null: credits.redraw = panel.refresh
	credits.back_requested.connect(_show_page.bind("settings")); credits.hide()
	var credits_button := Button.new(); credits_button.text = "Credits"
	credits_button.custom_minimum_size.y = 42; credits_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	credits_button.pressed.connect(_show_page.bind("credits")); page.footer.add_child(credits_button)
	if not ui._desktop and pause != null:
		for entry in [["Saved games", _open_saves], ["Support", _show_page.bind("support")], ["Quit to title", func(): close(); pause.quit_to_title()], ["Quit game", func(): pause.quit_game()]]:
			var b := Button.new(); b.text = entry[0]; b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.add_theme_font_size_override("font_size", 20); b.custom_minimum_size.y = 42; b.clip_text = true; b.pressed.connect(entry[1])
			page.footer.add_child(b)
		_build_provider_page(); _build_support_page()


## AI & voice on the World Panel: the same provider page as the desktop pause menu, with the
## on-panel keyboard under it while a text field has focus.
func _build_provider_page() -> void:
	provider = page.provider
	keyboard = preload("res://world/ui/panel_keyboard.gd").new()
	keyboard.setup(panel, 880, 20); keyboard.position = Vector2(10, 500); content.add_child(keyboard); keyboard.hide()


func _build_support_page() -> void:
	support = VBoxContainer.new(); support.position = Vector2(25, 20); support.custom_minimum_size = Vector2(850, 800)
	support.add_theme_constant_override("separation", 10); content.add_child(support); support.hide()
	var title := Label.new(); title.text = "Support"; title.add_theme_font_size_override("font_size", 30); support.add_child(title)
	var note := Label.new(); note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; note.custom_minimum_size.x = 800
	note.add_theme_font_size_override("font_size", 21)
	note.text = "Something went wrong? Make a logs bundle and attach the zip to your report. It holds the game logs and your settings, never your API key. Bundles are saved in the game's support folder (on a headset: Android/data/.../files/support). On a headset, Open support folder opens that folder; on desktop, Open logs folder opens the original game logs."
	support.add_child(note)
	for entry in [["Copy logs bundle", func(): pause._make_bundle(); _mirror_support()], ["Open support folder" if OS.has_feature("android") else "Open logs folder", func(): pause._open_logs(); _mirror_support()], ["Back", _show_page.bind("settings")]]:
		var b := Button.new(); b.text = entry[0]; b.custom_minimum_size.y = 46; b.add_theme_font_size_override("font_size", 21)
		b.pressed.connect(entry[1]); support.add_child(b)
	_support_status = Label.new(); _support_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_support_status.custom_minimum_size.x = 800; _support_status.add_theme_font_size_override("font_size", 20); support.add_child(_support_status)


func _mirror_support() -> void:
	if pause != null and pause.get("_support_status") != null: _support_status.text = str(pause._support_status.text)
	_refresh()


func _show_page(name: String, with_sound: bool = true) -> void:
	var changed: bool = _page_name != name
	_page_name = name
	if page != null: page.visible = name == "settings"
	if name == "provider":
		page.show(); page.show_tab("AI Settings")
	if support != null: support.visible = name == "support"
	if credits != null: credits.visible = name == "credits"
	if keyboard != null and name != "provider": keyboard.hide()
	_refresh()
	if changed and with_sound: _menu_sound("prop_ui_confirm")


## Text field focused on the panel: keyboard in, the provider page shortened above it.
func _tend_keyboard() -> void:
	if keyboard == null or provider == null: return
	var prompts: Control = page.prompts if page != null else null
	if not provider.is_visible_in_tree() and not (prompts != null and prompts.is_visible_in_tree()):
		if keyboard.visible:
			keyboard.hide(); page.custom_minimum_size.y = 800.0; page.size.y = 800.0; _refresh()
		return
	var owner: Control = panel.viewport.gui_get_focus_owner()
	var wanted: bool = owner is LineEdit or owner is TextEdit
	if wanted == keyboard.visible: return
	keyboard.visible = wanted
	page.custom_minimum_size.y = 480.0 if wanted else 800.0
	page.size.y = page.custom_minimum_size.y
	_refresh()

func _open_saves() -> void:
	close()
	var saves: Node = pause.save_menu if pause != null else null
	if saves != null: saves.toggle()

func _refresh() -> void:
	if page != null: page.refresh()
	if panel != null: panel.refresh()

func toggle() -> void:
	if opened: close(); return
	if ui.customizer.opened: return
	if ui.hand_busy("right") or ui.hand_busy("left"): return
	if pause != null and pause.opened: return
	if ui._desktop: DESKTOP_OWNER.cancel_current(ui)
	if is_instance_valid(ui.inspector): ui.inspector.close()
	ui._close_map(); ui._release_case(); ui.case.close(); ui.wrist.hide()
	opened = true; _armed = false; _old_lock = ui.player_body.controls_locked; ui.player_body.controls_locked = true
	_old_physics = ui.is_physics_processing()
	for node in [ui, ui.inspector, ui.map_menu]:
		if not is_instance_valid(node): continue
		_input_states[node] = node.is_processing_input(); node.set_process_input(false)
		if node == ui.map_menu: node.set_meta("save_menu_open", true)
	ui._claim("right", true); ui._claim("left", true); ui.set_physics_process(false)
	Settings.message = ""
	_show_page("settings", false)
	if ui._desktop:
		_mouse_mode = Input.mouse_mode; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		content.position = (Vector2(get_viewport().get_visible_rect().size) - content.size) * .5; canvas.show()
	else:
		panel.global_position = ui.camera.global_position - ui.camera.global_basis.z * 1.4
		panel.look_at(ui.camera.global_position, Vector3.UP, true); panel.show(); panel.refresh()
		_show_page("settings", false)
	_refresh()
	_menu_sound("prop_ui_confirm")

func close() -> void:
	if not opened: return
	_menu_sound("prop_ui_back")
	opened = false
	page.capturing = ""
	ui._claim("right", false); ui._claim("left", false); ui.set_physics_process(_old_physics); ui.player_body.controls_locked = _old_lock
	for node in _input_states:
		if is_instance_valid(node): node.set_process_input(_input_states[node]); node.remove_meta("save_menu_open")
	_input_states.clear()
	if ui._desktop: canvas.hide(); Input.mouse_mode = _mouse_mode
	else: panel.press(false); panel.hide(); pointer.hide()

func _menu_sound(event: String) -> void:
	var camera: Camera3D = VIEW.camera(self)
	if camera != null: SOUNDS.play_at(camera, event, camera.global_position)

func _process(_delta: float) -> void:
	if not opened or ui._desktop: return
	var sample: Dictionary = ui.hand_sample("right")
	if not sample.get("active", false): _armed = false; panel.press(false); pointer.hide(); return
	var pose: Transform3D = sample.aim
	if not pose.is_finite(): _armed = false; panel.press(false); pointer.hide(); return
	var pressed: bool = sample.trigger > .6
	if not pressed: _armed = true
	var pixel: Vector2 = panel.ray_to_pixel(pose.origin, -pose.basis.z)
	panel.point_at(pixel); panel.press(pressed and _armed and pixel.x >= 0)
	pointer.aim(pose.origin, panel.pixel_to_world(pixel) if pixel.x >= 0 else pose.origin - pose.basis.z * 2.)
	_tend_keyboard()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit: return
		if opened and page != null and not page.capturing.is_empty(): return
		match event.physical_keycode:
			KEY_F7: toggle(); get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				if opened: close(); get_viewport().set_input_as_handled()

## Left controller menu button (OpenXR "menu_button").
func bind_controller(controller: XRController3D) -> void:
	if controller == null: return
	controller.button_pressed.connect(func(action: StringName): if action == &"menu_button": toggle())

func _exit_tree() -> void:
	if opened and is_instance_valid(ui): close()
