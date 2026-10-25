extends RefCounted
## Surface-bound paint: generated wall albedo and authored tree-ring/sun vector art.
## Reading source bytes also works before the editor's first import pass.
const SHADER := preload("res://world/buildings/golden_oak/reference_surface.gdshader")
const ROOT := "res://world/buildings/golden_oak/art/"
const IMAGE := preload("res://world/resource_image.gd")
static var _textures: Dictionary = {}

static func wall(frame: Transform3D) -> ShaderMaterial:
	return _surface("wall_imagegen_v1.png", frame, 0)

static func floor_material(frame: Transform3D) -> ShaderMaterial:
	return _surface("tree_ring_floor.svg", frame, 1)

static func ceiling(frame: Transform3D) -> ShaderMaterial:
	return _surface("sun_ceiling.svg", frame, 1)

static func _surface(filename: String, frame: Transform3D, kind: int) -> ShaderMaterial:
	if not _textures.has(filename):
		var image: Image = IMAGE.read(ROOT + filename)
		assert(image != null, "Golden Oak surface artwork could not load: " + filename)
		_textures[filename] = IMAGE.upload(image)
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("artwork", _textures[filename])
	material.set_shader_parameter("world_to_room", frame.affine_inverse())
	material.set_shader_parameter("surface_kind", kind)
	return material
