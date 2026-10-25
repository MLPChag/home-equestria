extends Node3D
const SHELL := preload("res://world/buildings/boutique/shell.gd")
const INTERIOR := preload("res://world/buildings/boutique/interior.gd")
const HOME := preload("res://world/buildings/boutique/home.gd")
var home: Node3D
var interior: Node3D
static func attach(existing: Node3D) -> Node3D:
	var installed:=existing.get_node_or_null("BoutiqueRoomFrame/UsableBoutique") as Node3D
	if installed!=null:return installed
	var prepared:=SHELL.prepare(existing)
	var runtime:=load("res://world/buildings/boutique/boutique.gd").new() as Node3D
	runtime.name="UsableBoutique";prepared.frame.add_child(runtime)
	runtime.interior=INTERIOR.new();runtime.interior.name="BoutiqueInterior";runtime.add_child(runtime.interior)
	runtime.interior.build(prepared.layout)
	runtime.home=HOME.new();runtime.home.name="HouseInterior";runtime.add_child(runtime.home)
	runtime.home.configure(prepared.layout,runtime.interior,prepared.door)
	existing.set_meta("boutique_interior",true)
	return runtime
