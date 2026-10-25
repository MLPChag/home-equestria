extends RefCounted
## Derived original mane with only the measured hat-covered region removed.
const ORIGINALS:=&"trixie_uncovered_mane"
const VARIANT:="trixie-hat-v1"
const MESHES:={
	"TrixieDevkitMane":"res://world/characters/accessories/trixie/mane_hat.res",
	"TrixieDevkitManeLOD1":"res://world/characters/accessories/trixie/mane_hat_lod.res",
}
static var loaded:Dictionary={}
static func apply(pony:Node3D,covered:bool)->void:
	if not is_instance_valid(pony) or not pony.is_inside_tree() or pony.is_queued_for_deletion():return
	var identity:Resource=pony.get("identity")
	if identity==null or str(identity.id)!="trixie":return
	var hair:Node=pony.get("hair")
	if hair==null:return
	var originals:Dictionary=pony.get_meta(ORIGINALS) if pony.has_meta(ORIGINALS) else {}
	var changed:=false
	for mesh:MeshInstance3D in hair.find_children("TrixieDevkitMane*","MeshInstance3D",true,false):
		var key:=str(mesh.name)
		if not MESHES.has(key):continue
		if covered:
			if not loaded.has(key):loaded[key]=load(MESHES[key])
			if not originals.has(key):originals[key]=mesh.mesh
			if mesh.mesh!=loaded[key]:mesh.mesh=loaded[key];changed=true
		elif originals.has(key) and mesh.mesh!=originals[key]:mesh.mesh=originals[key];changed=true
	if covered:pony.set_meta(ORIGINALS,originals)
	elif pony.has_meta(ORIGINALS):pony.remove_meta(ORIGINALS)
	if changed:pony.refresh_geometry_variant(VARIANT if covered else "")
static func hat_removed(pony:Node3D)->void:
	if not is_instance_valid(pony) or not pony.is_inside_tree() or pony.is_queued_for_deletion():return
	for hat:Node in pony.find_children("Wear_wizard_hat*","",true,false):
		if not hat.is_queued_for_deletion():return
	apply(pony,false)
