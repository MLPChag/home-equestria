extends RefCounted
## Offline-measured mesh replacements. Exact source signatures protect later shell edits.
const ROOT: String = "res://world/interiors/shell_repairs/"
static func signature(mesh: Mesh) -> int:
	var a: Array=mesh.surface_get_arrays(0)
	return hash([a[Mesh.ARRAY_VERTEX],a[Mesh.ARRAY_INDEX]])
static func triangle_key(a: Vector3,b: Vector3,c: Vector3) -> String:
	var points: Array[String]=[]
	for v: Vector3 in [a,b,c]:points.append("%d,%d,%d" % [roundi(v.x*10000),roundi(v.y*10000),roundi(v.z*10000)])
	points.sort()
	return "|".join(points)
static func apply(house: Node3D) -> void:
	var design: String = house.scene_file_path.get_file().get_basename().trim_prefix("house_")
	if design == "a":
		preload("res://world/interiors/shell_repairs/a_inner_wall.gd").apply(house)
		return
	if design not in ["c","g","h"]:return
	var exterior: MeshInstance3D=house.find_child("Exterior",true,false)
	if exterior==null:return
	if not ResourceLoader.exists(ROOT+design+"_exterior.res") or not ResourceLoader.exists(ROOT+design+"_collision.res"):return
	var replacement: Mesh=load(ROOT+design+"_exterior.res")
	if signature(exterior.mesh)!=replacement.get_meta("source_signature"):return
	var source: Mesh=exterior.mesh
	for m: MeshInstance3D in house.find_children("*","MeshInstance3D",true,false):
		if m.mesh==source:m.mesh=replacement
	var fixed_shape: ConcavePolygonShape3D=load(ROOT+design+"_collision.res")
	for holder: CollisionShape3D in exterior.find_children("*","CollisionShape3D",true,false):
		var shape: ConcavePolygonShape3D=holder.shape as ConcavePolygonShape3D
		if shape!=null and hash(shape.get_faces())==fixed_shape.get_meta("source_signature"):
			holder.shape=fixed_shape.duplicate()
	var marker: String = "extension_roof_repaired" if design=="h" else ("roof_caps_repaired" if design=="g" else "corner_flap_repaired")
	house.set_meta(marker,true)
