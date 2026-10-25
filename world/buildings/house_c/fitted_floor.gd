extends MeshInstance3D
## Planks for the fitted floor of House C and D (tools/houses_fix/house_c_d/fix_house.gd bakes
## the geometry: the measured room, a baseboard along its walls, D's sunken door landing).
## Same look as HouseInterior._dress_floor gives the rect slabs of other houses: world-space
## wood planks in this house's own shade between dark and light brown (same hash, so a house
## keeps its shade), and baseboards in the matching darker trim. The node is not named
## FloorSlab* so HouseInterior does not also lay its sampled underlay and skirting boards,
## which came out staggered on angled walls and loose beside posts and the door.
const WOOD := preload("res://world/buildings/textures/wood_floor.res")
const INTERIOR := preload("res://world/buildings/interior_surface.gdshader")
## Other meshes (house-relative paths) that take the plank material, e.g. C's threshold ramp.
@export var planks_too: Array[NodePath] = []
@export var trim: NodePath

func _ready() -> void:
	var house := get_parent() as Node3D
	var anchor: Node3D = house.get_node_or_null("HouseInterior")
	if anchor == null: anchor = house
	var p := anchor.global_position
	var t := float(absi(hash(str(house.name) + str(roundi(p.x)) + str(roundi(p.z)))) % 1000) / 1000.0
	var tint := Color(0.58, 0.44, 0.34).lerp(Color(1.12, 1.04, 0.94), t)
	var mat := ShaderMaterial.new(); mat.shader = INTERIOR
	mat.set_shader_parameter("albedo_map", WOOD); mat.set_shader_parameter("has_texture", true)
	mat.set_shader_parameter("planar", true); mat.set_shader_parameter("base_color", tint)
	# The side apron reads as the house's own plinth stone (baked by the fix script).
	if has_meta("side_color"): mat.set_shader_parameter("side_color", get_meta("side_color"))
	material_override = null
	for i in mesh.get_surface_count(): set_surface_override_material(i, mat)
	for path in planks_too:
		var other := house.get_node_or_null(path) as MeshInstance3D
		if other == null: continue
		other.material_override = null
		for i in other.mesh.get_surface_count(): other.set_surface_override_material(i, mat)
	var board := house.get_node_or_null(trim) as GeometryInstance3D
	if board != null and board.material_override is StandardMaterial3D:
		var m := (board.material_override as StandardMaterial3D).duplicate() as StandardMaterial3D
		m.albedo_color = tint * Color(.72, .66, .6)
		board.material_override = m
