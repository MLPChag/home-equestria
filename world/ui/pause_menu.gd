extends Node
## Desktop Escape menu. Escape opens it when nothing else took the key (menus, chat, the
## map and the inspector close themselves on Escape in _input and mark it handled; this
## listens in _unhandled_input). While open the world clock stops, the player cannot move
## and the mouse is free; the SceneTree keeps running so saves, menus and streaming work.
## VR keeps its left-menu-button settings panel, which offers the same quit actions.

const TITLE_SCENE := "res://world/ui/title_screen.tscn"
const LOG_BUNDLE := "res://world/debug/log_bundle.gd"
const VERSION := "res://world/debug/version.gd"
const GOLD := Color("edd6a2")
const DESKTOP_OWNER := preload("res://player/desktop_action_owner.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const VIEW := preload("res://world/player_view.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")

var game: Node
var ui: Node                # briefcase inventory (hands, map, inspector)
var save_menu: Node
var settings_menu: Node
var player_body: Node
var opened := false
var canvas: CanvasLayer
var _pages: Dictionary = {}  # name -> Control
var _page := ""
var _settings: Control
var _support_status: Label
var _pony_notice: Label
var _clock_paused := false
var _old_lock := false
var _mouse_mode: int = Input.MOUSE_MODE_VISIBLE
var _input_states: Dictionary = {}
var _in_save_menu := false


func setup(host: Node, inventory_ui: Node, saves_panel: Node, settings_panel: Node, body: Node) -> void:
	game = host; ui = inventory_ui; save_menu = saves_panel; settings_menu = settings_panel; player_body = body
	add_to_group("pause_menu")
	if ui == null or not ui._desktop: return
	canvas = CanvasLayer.new(); canvas.layer = 140; add_child(canvas); canvas.hide()
	var shade := ColorRect.new(); shade.color = Color(0.02, 0.03, 0.06, 0.55)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); canvas.add_child(shade)
	_build_main()
	var version := Label.new(); version.text = "Home: Equestria " + str((load(VERSION) as Script).call("text")) if ResourceLoader.exists(VERSION) else ""
	version.add_theme_font_size_override("font_size", 14); version.add_theme_color_override("font_color", Color("acb4c0"))
	version.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	version.grow_horizontal = Control.GROW_DIRECTION_BEGIN; version.grow_vertical = Control.GROW_DIRECTION_BEGIN
	canvas.add_child(version)
	_build_settings()
	_build_support()
	var credits := preload("res://world/ui/credits_page.gd").new()
	_card("credits", Vector2(900, 840)).add_child(credits)
	credits.setup(Vector2(880, 820), 22)
	credits.back_requested.connect(_show.bind("main"))


## A centred card of the given size on the pause layer.
func _card(page_name: String, card_size: Vector2) -> PanelContainer:
	var centre := CenterContainer.new(); centre.name = page_name
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); canvas.add_child(centre); centre.hide()
	var card := PanelContainer.new(); card.custom_minimum_size = card_size; centre.add_child(card)
	_pages[page_name] = centre
	return card


func _build_main() -> void:
	var card := _card("main", Vector2(460, 0))
	var box := VBoxContainer.new(); box.add_theme_constant_override("separation", 10); card.add_child(box)
	var title := Label.new(); title.text = "Paused"; title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34); title.add_theme_color_override("font_color", GOLD); box.add_child(title)
	_pony_notice = Label.new(); _pony_notice.name = "PonyNotice"
	_pony_notice.text = PLAYER_FORM.PONY_NOTICE
	_pony_notice.custom_minimum_size.x = 420
	_pony_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pony_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pony_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pony_notice.add_theme_font_size_override("font_size", 18)
	_pony_notice.add_theme_color_override("font_color", GOLD)
	_pony_notice.hide(); box.add_child(_pony_notice)
	for entry in [["Continue", close], ["Save game", _open_saves], ["Load game", _open_saves], ["Settings", _show.bind("settings")],
			["AI Settings", _open_provider], ["Credits", _show.bind("credits")], ["Support", _show.bind("support")], ["Quit to title", quit_to_title], ["Quit game", quit_game]]:
		var b := Button.new(); b.name = str(entry[0]).replace(" ", "").replace("&", ""); b.text = entry[0]
		b.custom_minimum_size = Vector2(420, 50); b.add_theme_font_size_override("font_size", 22)
		b.pressed.connect(entry[1]); box.add_child(b)


func _build_settings() -> void:
	var card := _card("settings", Vector2(900, 820))
	_settings = preload("res://world/ui/settings_page.gd").new()
	card.add_child(_settings)
	_settings.setup(Vector2(880, 800), 20, "Back")
	_settings.back_requested.connect(_show.bind("main"))


func _build_support() -> void:
	var card := _card("support", Vector2(640, 0))
	var box := VBoxContainer.new(); box.add_theme_constant_override("separation", 10); card.add_child(box)
	var title := Label.new(); title.text = "Support"; title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", GOLD); box.add_child(title)
	var note := Label.new(); note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; note.custom_minimum_size.x = 600
	note.text = "Something went wrong? Make a logs bundle and attach the zip to your report. It holds the game logs and your settings, never your API key."
	box.add_child(note)
	for entry in [["Copy logs bundle", _make_bundle], ["Open support folder" if OS.has_feature("android") else "Open logs folder", _open_logs],
			["Debug: Trixie show tomorrow", _book_trixie_show], ["Back", _show.bind("main")]]:
		var b := Button.new(); b.text = entry[0]; b.custom_minimum_size.y = 46; b.add_theme_font_size_override("font_size", 21)
		b.pressed.connect(entry[1]); box.add_child(b)
	_support_status = Label.new(); _support_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_support_status.custom_minimum_size.x = 600; box.add_child(_support_status)


## Debug: book a Trixie stage show for the next game day at 17:00 (world/events/trixie_show/).
func _book_trixie_show() -> void:
	var runtime: Node = game.get_node_or_null("TrixieShow") if is_instance_valid(game) else null
	_support_status.text = runtime.force_next_day() if runtime != null else "Trixie's shows are not loaded in this world."


## provider_settings.gd calls this on its surface after every change (a SubViewport
## panel needs a redraw; a CanvasLayer does not).
func refresh() -> void:
	pass


# ------------------------------------------------------------------ open / close
func _unhandled_input(event: InputEvent) -> void:
	if canvas == null or not (event is InputEventKey) or not event.pressed or event.echo: return
	if (event as InputEventKey).physical_keycode != KEY_ESCAPE: return
	if _in_save_menu: return
	if not opened:
		if _other_menu_open(): return
		open()
	elif _page == "main": close()
	elif _page == "settings" and not _settings.capturing.is_empty(): return
	else: _show("main")
	get_viewport().set_input_as_handled()


func _other_menu_open() -> bool:
	for menu in [save_menu, settings_menu]:
		if menu != null and menu.opened: return true
	if ui != null and (ui.customizer.opened or ui.case.visible): return true
	return false


func open() -> void:
	if opened or canvas == null: return
	if ui != null and ui._desktop: DESKTOP_OWNER.cancel_current(ui)
	# Before the menu draws: saves made while paused (and the quit save) show this frame.
	var saves := _saves()
	if saves != null: saves.remember_view(self)
	opened = true
	_clock_paused = TimeOfDay.paused; TimeOfDay.paused = true
	_old_lock = player_body.controls_locked; player_body.controls_locked = true
	_mouse_mode = Input.mouse_mode; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Hotkeys of the other menus stay quiet while paused (F6/F7/I/J/M/T…).
	for node in [ui, ui.inspector if ui != null else null, ui.map_menu if ui != null else null, save_menu, settings_menu,
			game.get("world_map") if game != null else null]:
		if not is_instance_valid(node) or _input_states.has(node): continue
		_input_states[node] = node.is_processing_input(); node.set_process_input(false)
	Settings.message = ""
	canvas.show()
	_show("main")


func close() -> void:
	if not opened: return
	_menu_sound("prop_ui_back")
	opened = false
	canvas.hide(); _page = ""
	_settings.capturing = ""
	for node in _input_states:
		if is_instance_valid(node): node.set_process_input(_input_states[node])
	_input_states.clear()
	TimeOfDay.paused = _clock_paused
	player_body.controls_locked = _old_lock
	Input.mouse_mode = _mouse_mode
	var saves := _saves()
	if saves != null: saves.release_view(self)


func _show(page_name: String) -> void:
	var changed: bool = _page != page_name
	for key in _pages: (_pages[key] as Control).visible = key == page_name
	_page = page_name
	if page_name == "main" and is_instance_valid(_pony_notice):
		_pony_notice.visible = PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree()))
	if page_name == "settings": _settings.refresh()
	var first := _first_button(_pages[page_name])
	if first != null: first.grab_focus()
	if changed: _menu_sound("prop_ui_confirm")


func _menu_sound(event: String) -> void:
	var camera: Camera3D = VIEW.camera(self)
	if camera != null: SOUNDS.play_at(camera, event, camera.global_position)


func _first_button(node: Node) -> Button:
	for child in node.find_children("*", "Button", true, false):
		if (child as Button).is_visible_in_tree() and not (child as Button).disabled: return child
	return null


func _open_provider() -> void:
	_show("settings")
	_settings.show_tab("AI Settings")


## The saved games panel takes over (its own Escape/Close); the pause menu comes back
## once it closes.
func _open_saves() -> void:
	if save_menu == null: return
	canvas.hide()
	if is_instance_valid(save_menu): save_menu.set_process_input(true)
	save_menu.toggle()
	if not save_menu.opened:
		canvas.show(); return
	_in_save_menu = true


func _process(_delta: float) -> void:
	if not _in_save_menu: return
	if is_instance_valid(save_menu) and save_menu.opened: return
	_in_save_menu = false
	if not opened: return
	if is_instance_valid(save_menu): save_menu.set_process_input(false)
	# The saves panel restored its own mouse/lock state; the pause menu owns them again.
	player_body.controls_locked = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	canvas.show(); _show("main")


# ------------------------------------------------------------------ support
func _bundle_script() -> Script:
	return load(LOG_BUNDLE) as Script if ResourceLoader.exists(LOG_BUNDLE) else null


func _make_bundle() -> void:
	var script := _bundle_script()
	if script == null: _support_status.text = "The logs bundle is not available in this build."; return
	var path: String = str(script.call("make_bundle"))
	if path.is_empty(): _support_status.text = "Could not make the logs bundle."; return
	if path.begins_with("user://") or path.begins_with("res://"): path = ProjectSettings.globalize_path(path)
	DisplayServer.clipboard_set(path)
	_support_status.text = "Saved to %s (path copied to the clipboard)." % path


func _open_logs() -> void:
	var script := _bundle_script()
	if script != null: script.call("open_logs_folder")
	else: OS.shell_open(ProjectSettings.globalize_path("user://logs"))


# ------------------------------------------------------------------ quitting
## Back to the home screen, after the same autosave a window close makes (game_saves.gd
## save_before_quit) so Continue on the title resumes here. The world scene is freed by the
## scene change; ZoneManager forgets its zones in game.gd's _exit_tree. Clock/mouse/lock are
## restored first so the title's clock snapshot is the running world's.
## The quit save is written while the menu still holds the frame it covered (its screenshot).
func quit_to_title() -> void:
	_autosave()
	if opened: close()
	TimeOfDay.paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file.call_deferred(TITLE_SCENE)


func quit_game() -> void:
	_autosave()
	get_tree().quit()


func _autosave() -> void:
	var saves: Node = save_menu.saves if save_menu != null else null
	if is_instance_valid(saves) and saves.has_method("save_before_quit"): saves.save_before_quit()


## The world's GameSaves when it offers screenshots (menu fixtures may have none).
func _saves() -> Node:
	var saves: Variant = save_menu.get("saves") if is_instance_valid(save_menu) else null
	return saves if is_instance_valid(saves) and saves is Node and saves.has_method("remember_view") else null
