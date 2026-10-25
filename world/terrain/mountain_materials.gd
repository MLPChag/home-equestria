extends RefCounted
## World-space rock on imported mountain cliffs; native city paving/details stay authored.
const ROCK_TEXTURE := "res://world/zones/cloudsdale/tex_mountain_02b.png"
const ROCK_TINT := Color(0.90, 0.94, 0.90)
# This source contains many individual rock shapes per repeat. At 8 m they vanish
# into grey shimmer on a kilometre-wide cliff; 64 m retains the authored shapes.
const REPEAT_METRES := 64.0
static var _material: StandardMaterial3D

static func rock() -> StandardMaterial3D:
	if _material != null: return _material
	_material = StandardMaterial3D.new()
	_material.resource_name = "EquestriaMountainRock"
	var image := preload("res://world/resource_image.gd").read(ROCK_TEXTURE)
	if image != null:
		# The extracted PNG's import is 2D, with mipmaps disabled. An anisotropic
		# sampler alone cannot prevent distant shimmer without an actual mip chain.
		image.generate_mipmaps()
		_material.albedo_texture = ImageTexture.create_from_image(image)
	_material.albedo_color = ROCK_TINT
	_material.uv1_triplanar = true
	_material.uv1_world_triplanar = true
	_material.uv1_triplanar_sharpness = 4.0
	_material.uv1_scale = Vector3.ONE / REPEAT_METRES
	_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_material.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_material.roughness = 1.0
	return _material

static func apply(root: Node, config: Dictionary) -> int:
	if "--mountain-source-materials" in preload("res://world/dev_tools.gd").user_args(): return 0
	var paths: Array = config.get("mountain_rock", [])
	if paths.is_empty(): return 0
	var count := 0
	var stack: Array = [[root, ""]]
	while not stack.is_empty():
		var entry: Array = stack.pop_back(); var node: Node = entry[0]
		var path: String = entry[1] + "/" + str(node.name)
		var selected := false
		for pattern in paths:
			if ("/" + str(pattern) + "/") in path + "/": selected = true; break
		if selected and node is MeshInstance3D and node.mesh != null:
			for surface in node.mesh.get_surface_count():
				var material: Material = node.get_active_material(surface)
				if material == null: continue
				var label := material.resource_name.to_lower()
				# Only named rock surfaces: no snow, buildings, water, soil, or paths.
				if label.begins_with("cliff") or label == "equestriamountainrock":
					node.set_surface_override_material(surface, rock()); count += 1
		for child in node.get_children(): stack.append([child, path])
	return count
