extends Node3D
## Rainbow Dash's Cloudominium with a walk-in two-storey interior (dev 2026-09-28).
## shell.gd opens the real tower; architecture, furniture, materials and home adapter build
## inside the shared frame described in layout.gd.
const SHELL := preload("res://world/buildings/cloudominium/shell.gd")
const ARCHITECTURE := preload("res://world/buildings/cloudominium/architecture.gd")
const FURNITURE := preload("res://world/buildings/cloudominium/furniture.gd")
const HOME := preload("res://world/buildings/cloudominium/home.gd")
var home: Node3D
var architecture: Node3D
var furniture: Node3D

static func attach(existing: Node3D) -> Node3D:
	var installed := existing.get_node_or_null("UsableCloudominium") as Node3D
	if installed != null: return installed
	var prepared: Dictionary = SHELL.prepare(existing)
	var runtime := load("res://world/buildings/cloudominium/cloudominium.gd").new() as Node3D
	runtime.name = "UsableCloudominium"
	runtime.top_level = true
	existing.add_child(runtime)
	runtime.global_transform = prepared.frame
	runtime.architecture = ARCHITECTURE.new()
	runtime.architecture.name = "Architecture"
	runtime.add_child(runtime.architecture)
	runtime.architecture.build(prepared.layout)
	runtime.furniture = FURNITURE.new()
	runtime.furniture.name = "Furniture"
	runtime.add_child(runtime.furniture)
	runtime.furniture.build(prepared.layout)
	runtime.home = HOME.new()
	runtime.home.name = "HouseInterior"
	runtime.add_child(runtime.home)
	runtime.home.configure(prepared.layout, runtime.architecture, runtime.furniture, prepared.door)
	existing.set_meta("cloudominium_interior", true)
	return runtime
