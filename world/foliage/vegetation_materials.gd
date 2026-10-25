extends RefCounted
## Only the measured native tree atlases. Mixed bark/leaf textures retain a soft
## green-pixel mask; houses, ponies, trunks and colored blossoms keep their palette.
const ATLAS := {
	"Evershade_6.png":"Tree01", "Evershade_5.png":"Tree02",
	"Evershade_3.png":"Tree03", "Evershade_2.png":"Tree04",
	"Evershade_1.png":"Tree05_Diff", "White_Tail_Park_2.png":"PineTreeTex2"
}
static var _cache: Dictionary = {}
static var _shaders: Dictionary = {}

static func material_for(source: Material) -> Material:
	if not source is ShaderMaterial or source.shader==null or source.has_meta(&"vegetation_ground_hue"):return source
	if not source.shader.resource_path.begins_with("res://addons/cel-shader/"):return source
	var texture: Texture2D=source.get_shader_parameter("base_texture")
	if texture==null or ATLAS.get(texture.resource_path.get_file(),"")!=source.resource_name:return source
	var key:=source.get_instance_id()
	if _cache.has(key):
		var cached: Material=_cache[key].get_ref()
		if cached!=null:return cached
	var path: String=source.shader.resource_path
	if not _shaders.has(path):
		var derived:="res://world/foliage/shaders/"+path.get_file()
		if not ResourceLoader.exists(derived):return source
		_shaders[path]=load(derived)
	var result:=source.duplicate() as ShaderMaterial
	result.shader=_shaders[path];result.set_meta(&"vegetation_ground_hue",true)
	_cache[key]=weakref(result)
	return result

static func apply(root: Node) -> void:
	var pending: Array[Node]=[root]
	while not pending.is_empty():
		var node:=pending.pop_back() as Node
		var mesh: Mesh
		if node is MeshInstance3D:mesh=node.mesh
		elif node is MultiMeshInstance3D and node.multimesh!=null:mesh=node.multimesh.mesh
		if mesh!=null:
			if node.material_override!=null:node.material_override=material_for(node.material_override)
			else:
				var replacement: Mesh
				for surface in mesh.get_surface_count():
					var source: Material=node.get_active_material(surface) if node is MeshInstance3D else mesh.surface_get_material(surface)
					var fitted:=material_for(source)
					if source==fitted:continue
					if node is MeshInstance3D:node.set_surface_override_material(surface,fitted)
					else:
						if replacement==null:replacement=mesh.duplicate()
						replacement.surface_set_material(surface,fitted)
				if replacement!=null:
					var multimesh: MultiMesh=node.multimesh.duplicate();multimesh.mesh=replacement;node.multimesh=multimesh
		pending.append_array(node.get_children())
