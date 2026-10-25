extends RefCounted
## Approved RNL trunks and Grassy Fields crowns, shared by streamed MultiMeshes.
const ROOT := "res://world/foliage/everfree_trees/"
const SHADOW_SHADER := preload("res://world/foliage/everfree_trees/crown_shadow.gdshader")
const GRASSY := preload("res://world/foliage/grassy_catalogue.gd")
# Most slots carry broad crowns; small trees and bare snags remain occasional accents.
const CANOPY_WEIGHTS := {"everfree_twisted":4.0,"everfree_rootfoot":4.0,"everfree_tall":3.0,
	"everfree_twisted_medium":1.0,"everfree_rootfoot_small":1.0,"everfree_tall_medium":1.0,"everfree_snag":0.3}
static var _levels: Dictionary = {}
static var _entries: Array = []
static var _trails: Array = []

static func entries() -> Array:
	if not _entries.is_empty(): return _entries
	var doc: Dictionary = WorldBiomeField.read_json(ROOT + "build.json")
	for id: String in doc.get("trees", {}):
		var spec: Dictionary = doc.trees[id]
		var scene: PackedScene = load(ROOT + id + ".scn")
		var node := scene.instantiate()
		var shape := node.get_node("TrunkBody").get_child(0) as CollisionShape3D
		_entries.append({"id":id,"name":id,"family":"everfree","category":"tree",
			"scene":ROOT+id+".scn","base_y":0.0,"height":spec.crown_top_m,
			"radius":maxf(spec.crown_size_m[0],spec.crown_size_m[2])*.5,
			"trunk_radius":shape.shape.radius,"trunk_height":shape.shape.height,
			"trunk_offset":[shape.position.x,0.0,shape.position.z]})
		node.free()
	for source: Dictionary in GRASSY.entries():
		if source.id not in ["sm_bush","sm_plant1","sm_plant2"]: continue
		var row := source.duplicate(); row.family="everfree";row.category="plant"
		_entries.append(row)
	return _entries

## Full leaves to DETAIL_END, reduced leaves to NEAR_END, the far mesh beyond (metres).
## Were 40 and 110: inside the forest the detailed bands drew most of 18 million triangles a
## frame at the opening (dev 2026-10-01, "holy fuck its so unoptimized").
const DETAIL_END := 28.0
const NEAR_END := 60.0

static func levels(entry: Dictionary) -> Array:
	if _levels.has(entry.id): return _levels[entry.id]
	var node: Node = (load(str(entry.scene)) as PackedScene).instantiate()
	var trunk := node.get_node("Trunk") as MeshInstance3D
	var far := node.get_node("Far") as MeshInstance3D
	var result: Array = []
	var crown := _shadow_crown(far.mesh)
	for i in 2:
		var parts: Array = [[trunk.mesh,trunk.transform]]
		var leaf := node.get_node_or_null("LeavesLOD%d" % i) as MeshInstance3D
		if leaf != null: parts.append([leaf.mesh,leaf.transform,{"shadow_off":crown != null,"everfree_leaf":true}])
		result.append({"lod":i,"parts":parts,"begin":0.0 if i==0 else DETAIL_END,"end":DETAIL_END if i==0 else NEAR_END})
	result.append({"lod":2,"parts":[[far.mesh,far.transform]],"begin":NEAR_END,"end":0.0})
	if crown != null:
		result.append({"lod":0,"parts":[[crown,far.transform,{"shadow_only":true}]],"begin":0.0,"end":NEAR_END})
	node.free();_levels[entry.id]=result
	return result

## The existing far crown follows the authored canopy volume. Its opaque shadow
## avoids overlapping alpha cards; visible leaves and the original trunk keep their meshes.
static func _shadow_crown(source: Mesh) -> ArrayMesh:
	var result := ArrayMesh.new()
	var material := ShaderMaterial.new(); material.shader = SHADOW_SHADER
	for surface in source.get_surface_count():
		var original := source.surface_get_material(surface) as ShaderMaterial
		if original == null or original.shader == null or not original.shader.resource_path.ends_with("far_crown.gdshader"): continue
		result.add_surface_from_arrays(source.surface_get_primitive_type(surface), source.surface_get_arrays(surface))
		result.surface_set_material(result.get_surface_count()-1, material)
	return result if result.get_surface_count() > 0 else null

static func choose(choices: Array, unit: float) -> Dictionary:
	var total := 0.0
	for entry: Dictionary in choices: total += float(CANOPY_WEIGHTS.get(entry.id,1.0))
	var remaining := unit * total
	for entry: Dictionary in choices:
		remaining -= float(CANOPY_WEIGHTS.get(entry.id,1.0))
		if remaining <= 0.0: return entry
	return choices[-1]

static func clears_trail(at: Vector3, radius: float) -> bool:
	if _trails.is_empty():
		for line: Array in WorldBiomeField.read_json("res://world/biomes/everfree_layout.json").get("trails",[]):
			var points := PackedVector2Array()
			for p: Array in line: points.append(Vector2(p[0],p[1]))
			_trails.append(points)
	var point := Vector2(at.x,at.z)
	for line: PackedVector2Array in _trails:
		for i in range(1,line.size()):
			var closest := Geometry2D.get_closest_point_to_segment(point,line[i-1],line[i])
			if point.distance_squared_to(closest) < pow(radius+1.4,2): return false
	return true
