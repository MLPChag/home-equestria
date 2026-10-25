extends RefCounted
## Native OpenPony dock, with its hidden base seated in the native rump.
## The existing fixed tail collar and this dock share the pelvis; free hair keeps its jiggle.
const MESH := preload("res://world/characters/hybrid_mare/openpony_dock.res")
const FIT_PATH := "user://character_fits/openpony_dock.json"
const APPROVED_FIT_PATH := "res://world/characters/hybrid_mare/dock_fit.json"
const TAIL_MOUNT:=preload("res://world/characters/hybrid_mare/dock_tail_mount.gd")
const VISIBILITY_FITS := "res://world/characters/hybrid_mare/dock_visibility_fits.json"
static var _visibility_fits:Dictionary={}
static var _meshes:Dictionary={}
static func defaults()->Dictionary:
	return {"version":1,"position":[0.0,0.0,0.0],"rotation_degrees":[0.0,0.0,0.0],"scale":1.0,"scale_xyz":[1.0,1.0,1.0]}
static func valid(data:Variant)->bool:
	if not data is Dictionary or data.get("version")!=1:return false
	for key in ["position","rotation_degrees"]:
		if not data.get(key) is Array or data[key].size()!=3:return false
		for value in data[key]:
			if not (value is float or value is int) or not is_finite(float(value)):return false
	if not (data.get("scale") is float or data.get("scale") is int):return false
	var axes:Variant=data.get("scale_xyz",[1.0,1.0,1.0])
	if not axes is Array or axes.size()!=3:return false
	for value in axes:
		if not (value is float or value is int) or not is_finite(float(value)) or float(value)<.05 or float(value)>10:return false
	return float(data.scale)>=.1 and float(data.scale)<=5 and vector(data.position).length()<=2
static func vector(values:Array)->Vector3:return Vector3(values[0],values[1],values[2])
static func read_fit(path:String=FIT_PATH)->Dictionary:
	if path==FIT_PATH and not FileAccess.file_exists(path):path=APPROVED_FIT_PATH
	if not FileAccess.file_exists(path):return defaults()
	var data:Variant=JSON.parse_string(FileAccess.get_file_as_string(path))
	if not valid(data):return defaults()
	if not data.has("scale_xyz"):data.scale_xyz=[1.0,1.0,1.0]
	return data
static func save_fit(data:Dictionary,path:String=FIT_PATH)->Error:
	if not valid(data):return ERR_INVALID_DATA
	var error:=DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if error!=OK:return error
	var file:=FileAccess.open(path+".tmp",FileAccess.WRITE)
	if file==null:return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data,"\t",true,true));file.flush();file.close()
	# Atomic replacement, retaining the previous accepted placement for recovery.
	if FileAccess.file_exists(path):
		error=DirAccess.copy_absolute(path,path+".previous")
		if error!=OK:return error
	return DirAccess.rename_absolute(path+".tmp",path)
static func pivot()->Vector3:
	var vertices:PackedVector3Array=MESH.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var result:=Vector3.ZERO;var indices:PackedInt32Array=MESH.get_meta("base_indices")
	for i in indices:result+=vertices[i]
	return result/maxi(1,indices.size())
static func fit_transform(data:Dictionary)->Transform3D:
	var rotation:=Basis.from_euler(vector(data.rotation_degrees)*PI/180.0).scaled_local(vector(data.get("scale_xyz",[1.0,1.0,1.0]))*float(data.scale))
	var center:=pivot()
	return Transform3D(rotation,center+vector(data.position)-rotation*center)
static func fitted_mesh(data:Dictionary,cache:bool=true)->ArrayMesh:
	if data==defaults():return MESH
	var key:=JSON.stringify(data)
	if cache and _meshes.has(key):return _meshes[key]
	var arrays:=MESH.surface_get_arrays(0)
	var transform:=fit_transform(data)
	var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var normals:PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
	var normal_basis:=transform.basis.inverse().transposed()
	for i in vertices.size():
		vertices[i]=transform*vertices[i];normals[i]=(normal_basis*normals[i]).normalized()
	arrays[Mesh.ARRAY_VERTEX]=vertices;arrays[Mesh.ARRAY_NORMAL]=normals
	var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	for meta in MESH.get_meta_list():mesh.set_meta(meta,MESH.get_meta(meta))
	mesh.set_meta("user_fit",data.duplicate(true))
	if cache:_meshes[key]=mesh
	return mesh
static func preview(pony:Node,data:Dictionary)->void:
	var dock:MeshInstance3D=pony.find_child("OpenPonyDock",true,false)
	if dock!=null:dock.mesh=fitted_mesh(effective_fit(pony,data),false)
static func same_fit(a:Dictionary,b:Dictionary)->bool:
	if not valid(a) or not valid(b):return false
	# JSON writers round the accepted doubles differently. Compare physical values,
	# so a serialization round-trip cannot silently disable the roster fitting.
	if absf(float(a.scale)-float(b.scale))>1e-9:return false
	for key in ["position","rotation_degrees","scale_xyz"]:
		var av:Array=a.get(key,[1.0,1.0,1.0])
		var bv:Array=b.get(key,[1.0,1.0,1.0])
		for i in 3:
			if absf(float(av[i])-float(bv[i]))>1e-9:return false
	return true
static func effective_fit(pony:Node,data:Dictionary)->Dictionary:
	var offset:=TAIL_MOUNT.offset(pony)
	if _visibility_fits.is_empty() and FileAccess.file_exists(VISIBILITY_FITS):
		_visibility_fits=JSON.parse_string(FileAccess.get_file_as_string(VISIBILITY_FITS))
	# Only adapt the accepted reference shape. A new user gizmo edit retains
	# direct control and is not silently altered by offsets fitted to older art.
	if same_fit(data,_visibility_fits.get("reference_fit",{})) and pony.identity.id!="rainbow_dash":
		var correction:Array=_visibility_fits.get("offsets",{}).get(pony.identity.id,[0,0,0])
		offset+=vector(correction)
	if offset.length_squared()<1e-12:return data
	var adapted:=data.duplicate(true)
	var position:=vector(data.position)+offset
	adapted.position=[position.x,position.y,position.z]
	return adapted
static func posed_frame(pony:Node)->Transform3D:
	# Mesh offsets are baked before skinning, so they remain pelvis-local in every pose.
	var body:MeshInstance3D=pony._model.find_child("MareBody",true,false)
	var hips:int=pony.skeleton.find_bone("pony_hips")
	for i in body.skin.get_bind_count():
		if body.skin.get_bind_name(i)==&"pony_hips" or (body.skin.get_bind_name(i)==&"" and body.skin.get_bind_bone(i)==hips):
			return pony.skeleton.global_transform*pony.skeleton.get_bone_global_pose(hips)*body.skin.get_bind_pose(i)
	return pony.skeleton.global_transform
static func apply(pony: Node,path:String=FIT_PATH) -> void:
	var body: MeshInstance3D=pony._model.find_child("MareBody",true,false)
	var dock:MeshInstance3D=pony.find_child("OpenPonyDock",true,false)
	if dock==null:
		dock=MeshInstance3D.new();dock.name="OpenPonyDock";pony.skeleton.add_child(dock);dock.skeleton=dock.get_path_to(pony.skeleton)
	dock.mesh=fitted_mesh(effective_fit(pony,read_fit(path)));dock.skin=body.skin
	dock.set_surface_override_material(0,body.get_active_material(0))
	if body.has_meta("source_material_0"):dock.set_meta("source_material_0",body.get_meta("source_material_0"))
