extends Node3D
## Existing Golden Oak exterior, doubled once, with a walk-in library and sleeping loft.
const SHELL := preload("res://world/buildings/golden_oak/shell.gd")
const INTERIOR := preload("res://world/buildings/golden_oak/interior.gd")
const HOME := preload("res://world/buildings/golden_oak/home.gd")
var home: Node3D
var interior: Node3D

static func attach(existing: Node3D) -> Node3D:
	var installed := existing.get_node_or_null("UsableLibrary") as Node3D
	if installed != null: return installed
	var prepared: Dictionary = SHELL.prepare(existing)
	var runtime := load("res://world/buildings/golden_oak/golden_oak.gd").new() as Node3D
	runtime.name = "UsableLibrary"
	runtime.top_level = true
	existing.add_child(runtime)
	runtime.global_transform = prepared.frame
	runtime.interior = INTERIOR.new()
	runtime.interior.name = "LibraryInterior"
	runtime.add_child(runtime.interior)
	runtime.interior.build(prepared.layout)
	preload("res://world/props/candles/candles.gd").scatter(runtime.interior, "golden_oak")
	runtime.home = HOME.new()
	runtime.home.name = "HouseInterior"
	runtime.add_child(runtime.home)
	runtime.home.configure(prepared.layout, runtime.interior, prepared.door)
	existing.set_meta("golden_oak_interior", true)
	return runtime
