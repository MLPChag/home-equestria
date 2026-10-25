extends RefCounted
## Small CPU-skinned contact patch from the existing coat; no model/collider changes.
## Source arrays are shared, posed query geometry belongs to one pony.
static var _source_cache:Dictionary={}
const PALM_RADIUS := .025 # Within the existing 3–3.5 cm palm/edge collision probes.
var mesh:=TriangleMesh.new()
var source:Dictionary
var faces:=PackedVector3Array()
var vertex_normals:=PackedVector3Array()
var bounds:=AABB()
var centre:=Vector3.ZERO
var revision:=0
var build_us:=0
var _transforms:Array[Transform3D]=[]
var _last_update:=-1
var _positions:=PackedVector3Array()
var _normals:=PackedVector3Array()
var _rest_positions:=PackedVector3Array()
var _rest_normals:=PackedVector3Array()
var _offsets:=PackedInt32Array()
var _bones:=PackedInt32Array()
var _weights:=PackedFloat32Array()
var _indices:=PackedInt32Array()

func _init(body:MeshInstance3D,marks:Array[Vector3])->void:
	var key:=[body.mesh,body.skin,marks[0],marks[1]]
	if not _source_cache.has(key):_source_cache[key]=_gather(body,marks)
	source=_source_cache[key]
	# Flatten once; no dictionaries or Variant conversions in the skinning loop.
	for vertex:Dictionary in source.vertices:
		_rest_positions.append(vertex.position);_rest_normals.append(vertex.normal)
		_offsets.append(_bones.size())
		for influence:Vector2 in vertex.influence:
			_bones.append(int(influence.x));_weights.append(influence.y)
	_offsets.append(_bones.size());_indices=source.indices
	_positions.resize(_rest_positions.size());_normals.resize(_rest_positions.size())
	faces.resize(_indices.size());vertex_normals.resize(_indices.size())

static func _gather(body:MeshInstance3D,marks:Array[Vector3])->Dictionary:
	var mid:Vector3=(marks[0]+marks[1])*.5
	var vertices:Array[Dictionary]=[];var indices:=PackedInt32Array();var bindings:Dictionary={}
	var skeleton:Skeleton3D=body.get_node(body.skeleton)
	for surface in body.mesh.get_surface_count():
		var a:Array=body.mesh.surface_get_arrays(surface)
		var vs:PackedVector3Array=a[Mesh.ARRAY_VERTEX];var ns:PackedVector3Array=a[Mesh.ARRAY_NORMAL]
		var ids:PackedInt32Array=a[Mesh.ARRAY_INDEX]
		var bones:PackedInt32Array=a[Mesh.ARRAY_BONES];var weights:PackedFloat32Array=a[Mesh.ARRAY_WEIGHTS]
		var stride:int=bones.size()/vs.size();var mapped:Dictionary={}
		for t in range(0,ids.size(),3):
			var p:Vector3=(vs[ids[t]]+vs[ids[t+1]]+vs[ids[t+2]])/3.
			var n:Vector3=(ns[ids[t]]+ns[ids[t+1]]+ns[ids[t+2]]).normalized()
			if p.z<mid.z-.11 or absf(p.y-mid.y)>.20 or n.z<-.35 or absf(n.y)>.8:continue
			for j in 3:
				var id:int=ids[t+j]
				if not mapped.has(id):
					var influence:Array[Vector2]=[]
					for k in stride:
						var at:int=id*stride+k
						if weights[at]<=0:continue
						var bind:int=bones[at]
						if not bindings.has(bind):
							var bone:int=body.skin.get_bind_bone(bind);var name:String=body.skin.get_bind_name(bind)
							if not name.is_empty():bone=skeleton.find_bone(name)
							bindings[bind]={"bone":bone,"bind":body.skin.get_bind_pose(bind),"index":bindings.size()}
						influence.append(Vector2(bindings[bind].index,weights[at]))
					mapped[id]=vertices.size();vertices.append({"position":vs[id],"normal":ns[id],"influence":influence})
				indices.append(mapped[id])
	return {"vertices":vertices,"indices":indices,"bindings":bindings.values(),"centre":mid}

func update_pose(skeleton:Skeleton3D,hip_frame:Transform3D)->void:
	var transforms:Array[Transform3D]=[]
	var base:Transform3D=hip_frame.affine_inverse()*skeleton.global_transform
	for binding:Dictionary in source.bindings:
		transforms.append(base*skeleton.get_bone_global_pose(binding.bone)*Transform3D(binding.bind))
	var changed:bool=transforms.size()!=_transforms.size()
	if not changed:
		for i in transforms.size():
			if not transforms[i].is_equal_approx(_transforms[i]):changed=true;break
	# At most 30 rebuilds/s, only while queried near a hand and bones actually move.
	var now:int=Time.get_ticks_msec()
	if changed and (_last_update<0 or now-_last_update>=33):
		var started:=Time.get_ticks_usec()
		_transforms=transforms;_last_update=now
		for i in _rest_positions.size():
			var p:=Vector3.ZERO;var n:=Vector3.ZERO
			var rest:Vector3=_rest_positions[i];var normal:Vector3=_rest_normals[i]
			for k in range(_offsets[i],_offsets[i+1]):
				var pose:Transform3D=transforms[_bones[k]]
				var weight:float=_weights[k]
				p+=(pose*rest)*weight;n+=(pose.basis*normal)*weight
			_positions[i]=p;_normals[i]=n.normalized()
		if not _positions.is_empty():
			bounds=AABB(_positions[0],Vector3.ZERO)
			for p in _positions:bounds=bounds.expand(p)
			for i in _indices.size():
				var index:int=_indices[i]
				faces[i]=_positions[index];vertex_normals[i]=_normals[index]
			centre=bounds.get_center();mesh.create_from_faces(faces)
			revision+=1
		build_us=Time.get_ticks_usec()-started

func _cast(start:Vector3,end:Vector3)->Dictionary:
	var hit:Dictionary=mesh.intersect_segment(start,end)
	if hit.is_empty():return hit
	var i:int=int(hit.face_index)*3
	var a:Vector3=faces[i];var u:Vector3=faces[i+1]-a;var v:Vector3=faces[i+2]-a
	var w:Vector3=Vector3(hit.position)-a
	var den:float=u.dot(u)*v.dot(v)-u.dot(v)*u.dot(v)
	if absf(den)>.0000000001:
		var b:float=(w.dot(u)*v.dot(v)-w.dot(v)*u.dot(v))/den
		var c:float=(w.dot(v)*u.dot(u)-w.dot(u)*u.dot(v))/den
		hit.normal=(vertex_normals[i]*(1.-b-c)+vertex_normals[i+1]*b+vertex_normals[i+2]*c).normalized()
		hit.barycentric=Vector3(1.-b-c,b,c)
	return hit

func contact(before:Vector3,point:Vector3,palm:Vector3,reach:float)->Dictionary:
	if faces.is_empty():return {}
	var region:AABB=bounds.grow(reach)
	if not region.has_point(point) and not region.has_point(before) and region.intersects_segment(before,point)==null:return {}
	var hit:Dictionary={}
	var travel:Vector3=point-before
	if travel.length_squared()>.00000001:
		hit=_cast(before,point+travel.normalized()*reach)
		if not hit.is_empty() and Vector3(hit.normal).dot(travel)>=0:hit={}
	if palm.length_squared()>.5:
		var facing:Dictionary=_cast(point-palm*.02,point+palm*reach)
		if not facing.is_empty() and Vector3(facing.normal).dot(palm)<0:
			if hit.is_empty() or point.distance_squared_to(facing.position)<point.distance_squared_to(hit.position):hit=facing
		if hit.is_empty():
			# A palm has area. A centre ray alone leaves triangle-edge numerical
			# cracks and misses real edge-of-palm contacts at the curved cheeks.
			var across:Vector3=Vector3.UP.cross(palm).normalized()
			if across.length_squared()<.5:across=Vector3.RIGHT
			var up:Vector3=palm.cross(across).normalized()
			for offset:Vector3 in [across*PALM_RADIUS,-across*PALM_RADIUS,up*PALM_RADIUS,-up*PALM_RADIUS]:
				var edge:Dictionary=_cast(point+offset-palm*.02,point+offset+palm*reach)
				if not edge.is_empty() and Vector3(edge.normal).dot(palm)<0:
					if hit.is_empty() or point.distance_squared_to(edge.position)<point.distance_squared_to(hit.position):hit=edge
	return hit

func near(point:Vector3,reach:float)->bool:
	return not contact(point,point,(centre-point).normalized(),reach).is_empty()

func attachment(hit:Dictionary)->Array[Dictionary]:
	var result:Array[Dictionary]=[]
	if not hit.has("barycentric"):return result
	var grouped:Dictionary={}
	for j in 3:
		var vertex:Dictionary=source.vertices[source.indices[int(hit.face_index)*3+j]]
		for influence:Vector2 in vertex.influence:
			var index:int=int(influence.x)
			var weight:float=influence.y*Vector3(hit.barycentric)[j]
			if not grouped.has(index):grouped[index]={"binding":source.bindings[index],"position":Vector3.ZERO,"normal":Vector3.ZERO,"weight":0.0}
			var part:Dictionary=grouped[index]
			part.position+=Vector3(vertex.position)*weight;part.normal+=Vector3(vertex.normal)*weight;part.weight+=weight
	for part:Dictionary in grouped.values():result.append(part)
	return result

func attached_pose(parts:Array[Dictionary],skeleton:Skeleton3D,hip_frame:Transform3D)->Transform3D:
	var point:=Vector3.ZERO;var normal:=Vector3.ZERO
	var base:Transform3D=hip_frame.affine_inverse()*skeleton.global_transform
	for part in parts:
		var pose:Transform3D=base*skeleton.get_bone_global_pose(part.binding.bone)*Transform3D(part.binding.bind)
		point+=pose.basis*Vector3(part.position)+pose.origin*float(part.weight)
		normal+=pose.basis*Vector3(part.normal)
	normal=normal.normalized()
	var across:Vector3=Vector3.UP.cross(normal).normalized()
	if across.length_squared()<.5:across=Vector3.RIGHT
	return Transform3D(Basis(across,normal,across.cross(normal)).orthonormalized(),point+normal*.015)
