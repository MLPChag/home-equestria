extends Node3D
class_name GrassyFieldsClouds
## Native painted cloud silhouettes at sky distance; no draw nodes or frame loop.
const MANIFEST_PATH := "res://world/foliage/grassy_fields/catalogue_grassy.json"
var initialized := false
func initialize_clouds(sky_material: ShaderMaterial) -> bool:
	if sky_material == null or not FileAccess.file_exists(MANIFEST_PATH): return false
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not doc is Dictionary: return false
	var textures := {}
	for entry: Dictionary in doc.get("assets", []):
		if entry.get("id", "") not in ["sm_cloud1", "sm_cloud2"]: continue
		var packed := load(str(entry.scene)) as PackedScene
		if packed == null: continue
		var node := packed.instantiate()
		for mesh in node.find_children("*", "MeshInstance3D", true, false):
			var mat := mesh.get_active_material(0) as ShaderMaterial
			if mat != null: textures[entry.id] = mat.get_shader_parameter("cloud_texture")
		node.free()
	if textures.size() != 2: return false
	sky_material.set_shader_parameter("grassy_cloud1", textures.sm_cloud1)
	sky_material.set_shader_parameter("grassy_cloud2", textures.sm_cloud2)
	sky_material.set_shader_parameter("grassy_clouds_enabled", true)
	initialized = true
	return true
