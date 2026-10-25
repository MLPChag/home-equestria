extends Window
## A real desktop window, including when the root viewport is presenting to OpenXR.
var page: Control

func _init() -> void:
	visible = false
	force_native = true
	title = "Home: Equestria — AI Settings"
	size = Vector2i(900, 840)
	min_size = Vector2i(760, 500)
	transient = true
	exclusive = true
	initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN

func open(settings_page: Control) -> void:
	page = settings_page
	var background := ColorRect.new(); background.color = Color("30203b")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background); background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.reparent(self); page.panel = self
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.setup_mode = true
	# Fit laptop displays while retaining scrolling and readable text.
	if DisplayServer.get_name() != "headless":
		var available := DisplayServer.screen_get_usable_rect(get_tree().root.current_screen).size
		size = Vector2i(mini(900, available.x - 40), mini(840, available.y - 80))
	popup_centered(size)
	page.open()

func refresh() -> void:
	pass # Native windows redraw their controls directly.
