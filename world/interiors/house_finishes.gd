extends RefCounted
## Approved linings own the room; the complete repaired/opened shell owns the exterior.
## The old split finish removed roof fronts that its retired room half used to draw,
## leaving jagged missing triangles. Keep those existing faces and draw both sides in
## one pass instead of relying on a second room mesh with an interior distance cap.
## Unlined houses retain the exact-source-guarded legacy finish below.
# Load with the house script's dependencies, before entering the town. Synchronous
# first-use loads cost about 9 ms per family in the scene-ready path.
const MESHES := {
	"house_a":[preload("res://world/interiors/finishes/house_a_outside.res")],
	"house_b":[preload("res://world/interiors/finishes/house_b_outside.res")],
	"house_c":[preload("res://world/interiors/finishes/house_c_outside.res")],
	"house_d":[preload("res://world/interiors/finishes/house_d_outside.res")],
	"house_e":[preload("res://world/interiors/finishes/house_e_outside.res")],
	"house_f":[preload("res://world/interiors/finishes/house_f_outside.res")],
	"house_g":[preload("res://world/interiors/finishes/house_g_outside.res")],
	"house_h":[preload("res://world/interiors/finishes/house_h_outside.res")],
}
const SIGNATURE := preload("res://world/interiors/shell_repairs.gd")
## Blender-reviewed visual-only repair: two buried H ledge triangles intersect its lining.
const H_COMPLETE := preload("res://world/interiors/shell_repairs/h_complete.res")
# Review fixtures disable replacement before instantiating the original shell.
static var enabled: bool = true
static var _signatures: Dictionary[int,int] = {}
static var _two_sided: Dictionary[int, BaseMaterial3D] = {}
static func apply(house: Node3D) -> void:
	if not enabled: return
	var design: String = house.scene_file_path.get_file().get_basename()
	if not MESHES.has(design): return
	var exterior: MeshInstance3D = house.find_child("Exterior",true,false)
	if exterior == null: return
	if house.has_node("HouseInterior/AuthoredLining") and _complete_exterior(house, exterior): return
	var source: Mesh = exterior.mesh
	if source.get_meta("authored_finishes",false): return
	var outside_mesh: ArrayMesh = MESHES[design][0]
	if not bool(outside_mesh.get_meta("authored_finishes",false)): return
	var id: int = source.get_instance_id()
	if not _signatures.has(id):_signatures[id] = SIGNATURE.signature(source)
	if _signatures[id] != outside_mesh.get_meta("source_signature",0) or source.get_surface_count() != outside_mesh.get_surface_count(): return
	exterior.mesh = outside_mesh

static func _complete_exterior(house: Node3D, exterior: MeshInstance3D) -> bool:
	if bool(exterior.get_meta("complete_exterior", false)): return true
	if exterior.mesh == null: return false
	var source: Mesh = exterior.mesh
	# Validate every active surface before changing anything. Do not mutate packed,
	# shared source materials: other users of those resources keep their own culling.
	var materials: Array[BaseMaterial3D] = []
	for surface: int in exterior.mesh.get_surface_count():
		var material := exterior.get_active_material(surface) as BaseMaterial3D
		if material == null: return false
		materials.append(material)
	if house.scene_file_path.get_file().get_basename() == "house_h":
		var id: int = source.get_instance_id()
		if not _signatures.has(id): _signatures[id] = SIGNATURE.signature(source)
		# Never apply an authored triangle edit to a newer or differently opened shell.
		if _signatures[id] == int(H_COMPLETE.get_meta("source_signature", 0)):
			exterior.mesh = H_COMPLETE
	if exterior.material_override != null:
		exterior.material_override = _exterior_material(materials[0])
	else:
		for surface: int in materials.size():
			exterior.set_surface_override_material(surface, _exterior_material(materials[surface]))
	# This duplicate is still used by surface queries; retain its node/mesh but stop
	# its redundant draw. Other room pieces and their colliders are not changed.
	for mesh: MeshInstance3D in house.find_children("*", "MeshInstance3D", true, false):
		if mesh != exterior and mesh.mesh == source and bool(mesh.get_meta("outside_backfaces", false)):
			mesh.visible = false
	exterior.set_meta("complete_exterior", true)
	return true

static func _exterior_material(source: BaseMaterial3D) -> BaseMaterial3D:
	var id: int = source.get_instance_id()
	if not _two_sided.has(id):
		var material := source.duplicate() as BaseMaterial3D
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_two_sided[id] = material
	return _two_sided[id]
