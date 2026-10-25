extends RefCounted
## Reviewed Tripo visual replacements. Existing furniture roots own physics and interaction.
const ROOT := "res://world/buildings/cloudominium/models/"
static var _scenes: Dictionary = {}

static func add_visual(parent: Node3D, id: String, at: Vector3 = Vector3.ZERO, size: Vector3 = Vector3.ONE) -> bool:
	var path := ROOT + id + ".scn"
	if not ResourceLoader.exists(path): return false
	if not _scenes.has(id): _scenes[id] = load(path)
	var packed: PackedScene = _scenes[id] as PackedScene
	if packed == null: return false
	var visual := packed.instantiate() as Node3D
	visual.name = id.to_pascal_case() + "Tripo"
	visual.position = at
	visual.scale = size
	parent.add_child(visual)
	return true
