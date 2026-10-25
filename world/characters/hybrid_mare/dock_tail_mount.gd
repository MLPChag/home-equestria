extends RefCounted
## Locate the fixed tail collar in the shared body mesh frame, once per hair asset.
const PATH:="res://world/characters/hybrid_mare/dock_tail_mounts.json"
static var _baked:Dictionary={}
static var _cache:Dictionary={}
static func bind_for(mesh:MeshInstance3D,name:String)->Transform3D:
	# A hidden rig mesh lends its skeleton path out while parked (hybrid_mare.set_rig_parking).
	var sk:Skeleton3D=mesh.get_node(mesh.get_meta(&"parked_skeleton",mesh.skeleton))
	for i in mesh.skin.get_bind_count():
		var bone:=sk.find_bone(mesh.skin.get_bind_name(i))
		if bone<0:bone=mesh.skin.get_bind_bone(i)
		if sk.get_bone_name(bone)==name:return mesh.skin.get_bind_pose(i)
	return Transform3D.IDENTITY
static func measure(pony:Node)->Dictionary:
	if pony.hair==null or pony.hair_link==null:return {}
	var body:MeshInstance3D=pony._model.find_child("MareBody",true,false)
	var tail:MeshInstance3D=pony.hair.find_child(pony.identity.hair_prefix+"DevkitTail",true,false)
	if body==null or tail==null:return {}
	var transform:Transform3D=bind_for(body,"pony_hips").affine_inverse()*pony.hair_link.pelvis_offset*bind_for(tail,"mPelvis")
	var low:=Vector3.INF;var high:=-Vector3.INF;var count:=0
	for surface in tail.mesh.get_surface_count():
		var vertices:PackedVector3Array=tail.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		for i in tail.mesh.get_meta("pinned_"+str(surface),PackedInt32Array()):
			var p:Vector3=transform*vertices[i];low=low.min(p);high=high.max(p);count+=1
	if count==0:return {}
	var under:=Vector3((low.x+high.x)*.5,low.y,(low.z+high.z)*.5)
	return {"anchor":[under.x,under.y,under.z],"samples":count}
static func offset(pony:Node)->Vector3:
	if _baked.is_empty() and FileAccess.file_exists(PATH):
		var parsed:Variant=JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if parsed is Dictionary:_baked=parsed
	if _baked.is_empty():return Vector3.ZERO
	var id:String=pony.identity.id
	var tail:MeshInstance3D=pony.hair.find_child(pony.identity.hair_prefix+"DevkitTail",true,false) if pony.hair!=null else null
	if tail==null:return Vector3.ZERO
	var version:int=tail.mesh.get_meta("anchor_version",0)
	var mount:Vector3=pony.identity.tail_mount_offset
	var mtime:=FileAccess.get_modified_time(pony.identity.hair_scene)
	var key:String=id+str(mount)+str(mtime)+String(pony.identity.hair_scene)+str(version)
	if _cache.has(key):return _cache[key]
	var data:Dictionary=_baked.get("ponies",{}).get(id,{})
	if data.get("source","")!=pony.identity.hair_scene or data.get("mtime",-1)!=mtime or data.get("mount",[])!=[mount.x,mount.y,mount.z] or data.get("anchor_version",-1)!=version:
		data=measure(pony)
	if data.is_empty():return Vector3.ZERO
	var a:Array=data.anchor;var r:Array=_baked.reference
	var result:=Vector3(a[0]-r[0],a[1]-r[1],a[2]-r[2])
	_cache[key]=result
	return result
