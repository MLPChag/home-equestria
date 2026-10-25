extends RefCounted
## Local native GLB loading, including source checkouts before an editor import.
## A memory-only packed cache prevents repeated conversion; never writes user state.
static var _cache: Dictionary = {}
static func scene(path: String) -> PackedScene:
	if _cache.has(path): return _cache[path]
	# Exports contain the imported PackedScene, not the original GLB bytes.
	if ResourceLoader.exists(path, "PackedScene"):
		var imported: PackedScene = load(path) as PackedScene
		if imported != null:
			_cache[path] = imported
			return imported
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(path, state)
	if error != OK:
		push_error("Cannot load Zecora asset: " + path)
		return null
	var root := document.generate_scene(state)
	if root == null: return null
	_own(root, root)
	var packed := PackedScene.new()
	var packed_error: Error = packed.pack(root)
	if packed_error != OK:
		root.free()
		push_error("Cannot pack Zecora asset: " + path)
		return null
	root.free()
	_cache[path] = packed
	return packed

static func _own(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_own(child, root)
