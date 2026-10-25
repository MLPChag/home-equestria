extends RefCounted
## Existing specialty-home plaster only. Shared textures/materials, no extra render nodes.
const IMAGES := preload("res://world/resource_image.gd")
static var _textures: Dictionary[String,Texture2D] = {}
static var _materials: Dictionary[String,Material] = {}
static func texture(id: String) -> Texture2D:
	if not _textures.has(id):
		var image: Image = IMAGES.read("res://world/interiors/wallpapers/"+id+".png")
		assert(image != null and not image.is_empty(), "Missing specialty wallpaper")
		_textures[id] = IMAGES.upload(image)
	return _textures[id]

static func boutique(circular: bool = false) -> ShaderMaterial:
	var key := "boutique_round" if circular else "boutique_flat"
	if not _materials.has(key):
		var material := ShaderMaterial.new()
		material.shader = preload("res://world/interiors/special_wallpaper.gdshader")
		material.set_shader_parameter("paper", texture("boutique_diamond"))
		material.set_shader_parameter("circular", circular)
		_materials[key] = material
	return _materials[key] as ShaderMaterial

static func cottage(source: StandardMaterial3D) -> StandardMaterial3D:
	if not _materials.has("cottage"):
		var material := source.duplicate() as StandardMaterial3D
		material.albedo_color = Color.WHITE
		material.albedo_texture = texture("cottage_leaf")
		# This authored plaster has no UVs. Local triplanar coordinates keep the
		# pattern attached to the building and avoid a different scale on each panel.
		material.uv1_triplanar = true
		material.uv1_triplanar_sharpness = 8.0
		material.uv1_scale = Vector3.ONE / 3.2
		material.texture_repeat = true
		_materials["cottage"] = material
	return _materials["cottage"] as StandardMaterial3D
