extends RefCounted
## House A rear inner wall: collision and window parts only. The visual inner wall (timber band,
## repaired room face, wallpaper) was retired with the legacy room layers on 2026-10-13; the
## approved A lining draws that wall now. The bodies are the exact ones the old repair built
## (packed inner-wall bodies plus the measured base returns), baked by
## tools/interiors/bake_a_inner_collision.gd; the original shell collision stays intact.
const WINDOWS = preload("res://world/interiors/shell_repairs/a_window_parts.gd")
const RESOURCE: String = "res://world/interiors/shell_repairs/a_inner_collision.scn"

static func signature(mesh: Mesh) -> int:
	var arrays: Array = mesh.surface_get_arrays(0)
	return hash([arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_INDEX]])

static func apply(house: Node3D) -> bool:
	if house.scene_file_path.get_file().get_basename() != "house_a" or house.has_node("AInnerWall") or bool(house.get_meta("a_inner_wall_pending", false)):
		return false
	if not ResourceLoader.exists(RESOURCE):
		return false
	var exterior: MeshInstance3D = house.get_node_or_null("Exterior") as MeshInstance3D
	if exterior == null:
		return false
	var addition: Node3D = (load(RESOURCE) as PackedScene).instantiate()
	if signature(exterior.mesh) != int(addition.get_meta("source_signature", 0)) or not WINDOWS.matches(house):
		addition.free()
		return false
	WINDOWS.apply(house)
	if house.is_inside_tree():
		# HouseInterior._ready runs while its parent is adding children: attach deferred.
		house.set_meta("a_inner_wall_pending", true)
		Callable(_attach).call_deferred(house, addition)
	else:
		house.add_child(addition)
	return true

static func _attach(house: Node3D, addition: Node3D) -> void:
	if not is_instance_valid(house) or house.is_queued_for_deletion():
		addition.free()
		return
	house.add_child(addition)
	house.remove_meta("a_inner_wall_pending")
