extends RefCounted
## Shared Blender-authored shelves; stock mounts are part of the inspected model.
const MODEL := preload("res://world/buildings/boutique/shelves.scn")
static func install(room: Node3D) -> void:
	if room.has_node("BoutiqueShelves"): return
	var root := Node3D.new(); root.name = "BoutiqueShelves"; room.add_child(root)
	for spec: Array in [["OutfitShelves", -1.0], ["AccessoryShelves", 1.0]]:
		var shelf: Node3D = MODEL.instantiate()
		shelf.name = spec[0]; shelf.position = Vector3(float(spec[1]) * 2.55, 0, 2.35)
		shelf.rotation.y = -float(spec[1]) * deg_to_rad(100)
		root.add_child(shelf)
		var visual := shelf.get_node("ShelfVisual") as MeshInstance3D
		visual.visibility_range_end = 45.0
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
