extends RefCounted
## AssetRipper omitted Unity Toon/Transparent/Cutout from opaque GLB materials.
## Texture paths are matched to a source-derived manifest, never guessed from RGB/alpha.
const CUTOUT := preload("res://addons/cel-shader/cel-shader-cutout.gdshader")
static var _rules: Dictionary = {}
static var _cache: Dictionary = {}

static func apply(root: Node) -> void:
	var meshes: Array = root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D: meshes.append(root)
	for mesh: MeshInstance3D in meshes:
		if mesh.mesh == null: continue
		if mesh.material_override != null:
			mesh.material_override = material_for(mesh.material_override)
			continue
		for i in mesh.mesh.get_surface_count():
			var source := mesh.get_active_material(i)
			var result := material_for(source)
			if result != source: mesh.set_surface_override_material(i, result)
	preload("res://world/foliage/vegetation_materials.gd").apply(root)

static func material_for(source: Material) -> Material:
	if source == null: return source
	var key := source.get_instance_id()
	if _cache.has(key):
		var found: Material = _cache[key].get_ref()
		if found != null: return found
	if _rules.is_empty():
		var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://world/native_material_modes.json"))
		if doc is Dictionary: _rules = doc.get("textures", {})
	var texture: Texture2D
	if source is BaseMaterial3D: texture = source.albedo_texture
	elif source is ShaderMaterial: texture = source.get_shader_parameter("base_texture")
	if texture == null or not _rules.has(texture.resource_path): return source
	var result := source.duplicate() as Material
	var cutoff := float(_rules[texture.resource_path].cutoff)
	if result is BaseMaterial3D:
		result.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		result.alpha_scissor_threshold = cutoff
	elif result is ShaderMaterial:
		# Only the existing cel shaders are compatible with this material contract.
		if result.shader == null or not result.shader.resource_path.begins_with("res://addons/cel-shader/"): return source
		result.shader = CUTOUT
		result.set_shader_parameter("alpha_cutoff", cutoff)
	_cache[key] = weakref(result)
	if _cache.size() > 4096:
		for old in _cache.keys():
			if _cache[old].get_ref() == null: _cache.erase(old)
	return result
