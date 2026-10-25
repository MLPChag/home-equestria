extends RefCounted
## VR or desktop at launch. OpenXR starts before any script runs, so the choice lives in
## `user://launch.cfg`, which project.godot loads as its project-settings override:
##
##   [launch]
##   vr="auto"            ; "ask" (the default), "off" (desktop), "auto" (headset if one answers), "on"
##   [xr]
##   openxr/enabled=true  ; must be true for "auto" and "on"; write() keeps it in step
##
## Godot's own `--xr-mode on|off` on the command line wins over the file (the developer's
## run.sh always passes it). "on" quits with a message when no headset starts; "auto"
## falls back to desktop silently. docs/ALPHA_AI_AND_PORTABILITY.md.
## "ask" (or no file) asks desktop or VR before the title on every launch without --xr-mode,
## until the player saves a choice there or in Settings (world/ui/play_mode_prompt.gd,
## dev 2026-10-20: "it should happen EVERY launch UNLESS save is deliberately chosen").

const PATH := "user://launch.cfg"
const MODES := ["ask", "off", "auto", "on"]
## Game argument (after "--") the prompt's restart passes, so a failed headset says so.
const REQUIRE_ARG := "--require-vr"


## The mode this process was asked for: the command line, else launch.cfg, else "ask".
static func vr_mode() -> String:
	var args := OS.get_cmdline_args()
	var at := args.find("--xr-mode")
	if at >= 0 and at + 1 < args.size():
		return "on" if args[at + 1] == "on" else "off"
	var mode := str(ProjectSettings.get_setting("launch/vr", "ask"))
	return mode if mode in MODES else "ask"


## Seated VR (dev 2026-10-01): the headset view, driven with keyboard and mouse like the desktop.
## Game arguments arrive after "--" (launcher, run.sh, launch.sh), so they are user arguments:
## --room-scale wins, then --seated, then Settings "vr/seated" (applies on the next launch).
static func seated() -> bool:
	var args := preload("res://world/dev_tools.gd").user_args()
	if "--room-scale" in args: return false
	if "--seated" in args: return true
	var tree := Engine.get_main_loop() as SceneTree
	var settings: Node = tree.root.get_node_or_null("Settings") if tree != null else null
	return settings != null and bool(settings.get_value("vr/seated"))


## True when VR must start or the game should quit (run.sh --vr, or launch.cfg vr="on").
static func require_vr() -> bool:
	if OS.get_environment("HOME_EQ_REQUIRE_VR") == "1" or REQUIRE_ARG in preload("res://world/dev_tools.gd").user_args(): return true
	return "--xr-mode" not in OS.get_cmdline_args() and vr_mode() == "on"


## Prints (and, for players who chose vr="on", shows) why the game is quitting. A player's
## saved choice goes back to "ask" so the next launch asks desktop or VR again.
static func fail_required_vr(tree: SceneTree) -> void:
	var message := "VR could not start. Connect your headset and activate its OpenXR runtime, then try again."
	printerr("equestria: " + message)
	if OS.get_environment("HOME_EQ_REQUIRE_VR") != "1":
		var file := ConfigFile.new()
		if file.load(PATH) == OK and str(file.get_value("launch", "vr", "ask")) != "ask": write("ask")
		OS.alert(message + "\n\nThe next launch will ask again whether to play on the desktop or in VR.", "Home: Equestria")
	tree.quit(1)


## True unless a choice was saved or given: no --xr-mode, launch.cfg says "ask", a real window.
static func should_ask() -> bool:
	if "--xr-mode" in OS.get_cmdline_args() or OS.get_environment("HOME_EQ_REQUIRE_VR") == "1": return false
	if OS.has_feature("android") or OS.has_feature("editor") or DisplayServer.get_name() == "headless": return false
	return vr_mode() == "ask"


## Starts a fresh copy of the game in VR (--xr-mode on, which also skips the prompt) and quits
## this one: OpenXR only starts before any script runs. An AppImage restarts through its image,
## not the mount that disappears when this process exits.
static func restart_in_vr(tree: SceneTree) -> void:
	var args := OS.get_cmdline_args()
	args.append_array(["--xr-mode", "on", "--"])
	args.append_array(preload("res://world/dev_tools.gd").user_args())
	args.append(REQUIRE_ARG)
	var image := OS.get_environment("APPIMAGE")
	OS.create_process(image if not image.is_empty() else OS.get_executable_path(), args)
	tree.quit()


## Writes launch.cfg for `mode` (applies on the next launch). Returns an Error.
static func write(mode: String) -> Error:
	if mode not in MODES: return ERR_INVALID_PARAMETER
	var file := ConfigFile.new()
	file.load(PATH)  # keep any other overrides the player added
	file.set_value("launch", "vr", mode)
	file.set_value("xr", "openxr/enabled", mode != "off")
	file.set_value("xr", "openxr/startup_alert", false)
	return file.save(PATH)


## dev 2026-10-20 multithreading: writes boot-only project settings ("section/key" -> value,
## e.g. "threading/worker_pool/max_threads") into launch.cfg for the next launch, keeping every
## other key. Saves only when a value changed. Returns an Error.
static func write_overrides(values: Dictionary, path: String = PATH) -> Error:
	var file := ConfigFile.new()
	file.load(path)
	var changed := false
	for setting: String in values:
		var at := setting.find("/")
		if at <= 0: return ERR_INVALID_PARAMETER
		var section := setting.substr(0, at)
		var key := setting.substr(at + 1)
		if file.has_section_key(section, key) and file.get_value(section, key) == values[setting]: continue
		file.set_value(section, key, values[setting])
		changed = true
	return file.save(path) if changed else OK
