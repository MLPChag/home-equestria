extends RefCounted
## Game version. Single source: project.godot application/config/version, written by
## tools/build/release.py.
##   label.text = preload("res://world/debug/version.gd").text()   # "0.1.0-alpha"

static func text() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "dev"))
