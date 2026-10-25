extends RefCounted
const NATIVE:=preload("res://world/characters/locomotion/native_solver.gd")
var native_enabled:=NATIVE.enabled("surface_contact")
var _native:RefCounted=NATIVE.create()
const CPU_PROFILE:=preload("res://tools/crowd_cpu_profile.gd")
## Actual shirt vertices near the shoulder, sampled only while shared contact is active.
## Bind data is immutable; only the few participating bone poses are cached each update.
var avatar:Node3D
var skeleton:Skeleton3D
var _bones:PackedInt32Array=PackedInt32Array()
var _poses:Array[Transform3D]=[]
var _cloth_radius:PackedFloat32Array=PackedFloat32Array()
var _contact_poses:Array[Transform3D]=[]
var _contact_frame:=Transform3D.IDENTITY
var _contact:Dictionary={}
var _contact_rebuilds:=-1
var cache_hits:=0
var pruning_enabled:=true
var _starts:PackedInt32Array=PackedInt32Array()
var _slots:PackedInt32Array=PackedInt32Array()
var _points:PackedVector3Array=PackedVector3Array()
var _weights:PackedFloat32Array=PackedFloat32Array()
var _triangles:PackedInt32Array=PackedInt32Array()
var _adjacent:Dictionary={}
var _posed:PackedVector3Array=PackedVector3Array()
var _ready:=false
var _head_rig:Skeleton3D
var _head_bone:=-1
var _head_bones:PackedInt32Array=PackedInt32Array()
var _head_poses:Array[Transform3D]=[]
var _built_poses:Array[Transform3D]=[]
var _bone_radius:PackedFloat32Array=PackedFloat32Array()
var _head_starts:PackedInt32Array=PackedInt32Array()
var _head_slots:PackedInt32Array=PackedInt32Array()
var _head_points:PackedVector3Array=PackedVector3Array()
var _head_weights:PackedFloat32Array=PackedFloat32Array()
var _head_indices:PackedInt32Array=PackedInt32Array()
var _head_frame:=Transform3D.IDENTITY
var _head_ready:=false
var _head_dirty:=true
var _mesh:=TriangleMesh.new()
var _head_bounds:=AABB()
var _envelope_normals:=PackedVector3Array()
var _envelope_limits:=PackedFloat32Array()
var _envelope_poses:Array[Transform3D]=[]
var _envelope_motion:=INF
var _envelope_witnesses:Array[PackedInt32Array]=[]
var envelope_rebuilds:=0
var _head_center:=Vector3.ZERO
var _overlaps:PackedInt32Array=PackedInt32Array()
var bind_usec:=0
var query_count:=0
var rebuild_count:=0
var rebuild_usec:=0

func bind(body:Node3D,mare:Node3D)->bool:
	var began:=Time.get_ticks_usec()
	avatar=body
	if not is_instance_valid(avatar) or not is_instance_valid(avatar.get("_skeleton")):return false
	skeleton=avatar._skeleton
	var bone_slots:Dictionary={};var seen:Dictionary={}
	for mesh:MeshInstance3D in avatar.find_children("*","MeshInstance3D",true,false):
		if not mesh.is_visible_in_tree() or mesh.mesh==null or mesh.skin==null or mesh.get_node_or_null(mesh.skeleton)!=skeleton:continue
		var bind_bones:PackedInt32Array=PackedInt32Array();var relevant:Array[bool]=[]
		for bind_index in mesh.skin.get_bind_count():
			var bone:=mesh.skin.get_bind_bone(bind_index);var name:=String(mesh.skin.get_bind_name(bind_index))
			if not name.is_empty():bone=skeleton.find_bone(name)
			if bone>=0:name=skeleton.get_bone_name(bone)
			bind_bones.append(bone)
			relevant.append(name in ["LeftShoulder","RightShoulder","LeftUpperArm","RightUpperArm"])
		for surface in mesh.mesh.get_surface_count():
			var arrays:Array=mesh.mesh.surface_get_arrays(surface)
			if arrays[Mesh.ARRAY_BONES]==null:continue
			var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var bones:PackedInt32Array=arrays[Mesh.ARRAY_BONES]
			var weights:PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
			var stride:int=bones.size()/vertices.size()
			var mapping:=PackedInt32Array();mapping.resize(vertices.size());mapping.fill(-1)
			for vertex in vertices.size():
				var useful:=false;var total:=0.0
				for slot in stride:
					var weight:=weights[vertex*stride+slot]
					if weight<=0:continue
					var index:=bones[vertex*stride+slot]
					if relevant[index]:useful=true
					total+=weight
				if not useful or total<=0:continue
				# Most avatar vertices cannot belong to the shoulder. Avoid their
				# string/key allocations before this inexpensive relevance filter.
				var key:=str(mesh.skin.get_instance_id())+str(vertices[vertex])
				for slot in stride:
					var weight:=weights[vertex*stride+slot]
					if weight>0:key+="/%d:%s"%[bind_bones[bones[vertex*stride+slot]],str(weight)]
				if seen.has(key):mapping[vertex]=int(seen[key]);continue
				mapping[vertex]=_starts.size();seen[key]=_starts.size();_starts.append(_slots.size())
				for slot in stride:
					var weight:=weights[vertex*stride+slot]/total
					if weight<=0:continue
					var index:=bones[vertex*stride+slot];var bone:=bind_bones[index]
					if bone<0:continue
					if not bone_slots.has(bone):
						bone_slots[bone]=_bones.size();_bones.append(bone);_poses.append(Transform3D.IDENTITY);_cloth_radius.append(0.0)
					_slots.append(int(bone_slots[bone]))
					var local:Vector3=mesh.skin.get_bind_pose(index)*vertices[vertex]
					_cloth_radius[int(bone_slots[bone])]=maxf(_cloth_radius[int(bone_slots[bone])],local.length())
					_points.append(local*weight)
					_weights.append(weight)
			var indices:PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
			for offset in range(0,indices.size(),3):
				var a:=mapping[indices[offset]];var b:=mapping[indices[offset+1]];var c:=mapping[indices[offset+2]]
				if mini(a,mini(b,c))<0:continue
				var face:=_triangles.size();_triangles.append_array(PackedInt32Array([a,b,c]))
				for vertex:int in [a,b,c]:
					if not _adjacent.has(vertex):_adjacent[vertex]=[]
					_adjacent[vertex].append(face)
	_starts.append(_slots.size())
	if _starts.size()<2:return false
	if not _bind_head(mare):return false
	skeleton.skeleton_updated.connect(capture)
	_head_rig.skeleton_updated.connect(capture_head)
	bind_usec=Time.get_ticks_usec()-began
	return true

func _bind_head(mare:Node3D)->bool:
	var boop:Node=mare.get("boop_node")
	if boop==null:return false
	_head_rig=boop.head_skeleton;_head_bone=boop._head_bone
	var model:Node=mare.get("_head_model")
	var mesh:MeshInstance3D=model.find_child("Head",true,false) if is_instance_valid(model) else null
	if mesh==null or mesh.mesh==null or mesh.skin==null or mesh.mesh.get_blend_shape_count()>0:return false
	# Near rendering concatenates these original vertices and bind data unchanged.
	# The parked source remains the exact coat surface, excluding eye/lash cards.
	if not mesh.is_visible_in_tree() and not mesh.get_meta("near_hidden",false):return false
	var slots:Dictionary={}
	var bind_bones:PackedInt32Array=PackedInt32Array()
	for bind_index in mesh.skin.get_bind_count():
		var bone:=mesh.skin.get_bind_bone(bind_index);var name:=String(mesh.skin.get_bind_name(bind_index))
		if not name.is_empty():bone=_head_rig.find_bone(name)
		bind_bones.append(bone)
	for surface in mesh.mesh.get_surface_count():
		var arrays:Array=mesh.mesh.surface_get_arrays(surface)
		if arrays[Mesh.ARRAY_BONES]==null:continue
		var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var bones:PackedInt32Array=arrays[Mesh.ARRAY_BONES]
		var weights:PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
		var indices:PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
		var stride:int=bones.size()/vertices.size();var offset:=_head_starts.size()
		for vertex in vertices.size():
			_head_starts.append(_head_slots.size())
			var total:=0.0
			for slot in stride:total+=weights[vertex*stride+slot]
			if total<=0:return false
			for slot in stride:
				var weight:=weights[vertex*stride+slot]/total
				if weight<=0:continue
				var index:=bones[vertex*stride+slot];var bone:=bind_bones[index]
				if bone<0:return false
				if not slots.has(bone):slots[bone]=_head_bones.size();_head_bones.append(bone);_head_poses.append(Transform3D.IDENTITY);_bone_radius.append(0.0)
				var local:Vector3=mesh.skin.get_bind_pose(index)*vertices[vertex]
				var bone_slot:int=slots[bone]
				_bone_radius[bone_slot]=maxf(_bone_radius[bone_slot],local.length())
				_head_slots.append(bone_slot);_head_points.append(local*weight);_head_weights.append(weight)
		for index:int in indices:_head_indices.append(index+offset)
	_head_starts.append(_head_slots.size())
	return _head_bone>=0 and _head_starts.size()>1 and not _head_indices.is_empty()

func capture_head()->void:
	if not is_instance_valid(_head_rig) or not _head_rig.is_inside_tree():_head_ready=false;return
	_head_frame=_head_rig.global_transform*_head_rig.get_bone_global_pose(_head_bone)
	if not _head_frame.is_finite() or absf(_head_frame.basis.determinant())<1e-8:_head_ready=false;return
	var inverse:=_head_frame.affine_inverse()
	for index in _head_bones.size():
		var pose:Transform3D=inverse*_head_rig.global_transform*_head_rig.get_bone_global_pose(_head_bones[index])
		if not pose.is_finite():_head_ready=false;return
		# Compare with the last built mesh, never the previous frame: tiny
		# cumulative changes must eventually invalidate the cache.
		if _built_poses.size()!=_head_bones.size():_head_dirty=true
		else:
			var previous:=_built_poses[index]
			var basis_delta:=Basis(pose.basis.x-previous.basis.x,pose.basis.y-previous.basis.y,pose.basis.z-previous.basis.z)
			var rotation_bound:=sqrt(basis_delta.x.length_squared()+basis_delta.y.length_squared()+basis_delta.z.length_squared())*_bone_radius[index]
			var world_bound:float=(pose.origin.distance_to(previous.origin)+rotation_bound)*maxf(_head_frame.basis.get_scale().abs().x,maxf(_head_frame.basis.get_scale().abs().y,_head_frame.basis.get_scale().abs().z))
			if world_bound>.00005:_head_dirty=true
		_head_poses[index]=pose
	_head_ready=true

func _refresh_head()->bool:
	if not _head_dirty:return true
	var began:=Time.get_ticks_usec()
	var vertices:=_skin(_head_starts,_head_slots,_head_points,_head_weights,_head_poses)
	_head_bounds=AABB(vertices[0],Vector3.ZERO)
	for point:Vector3 in vertices:_head_bounds=_head_bounds.expand(point)
	_head_center=_head_bounds.get_center()
	# The envelope contains every actual triangle. Only exact contact rays
	# decide the target; this broad phase merely skips impossible candidates.
	_envelope_motion=0.0
	if _envelope_poses.size()!=_head_poses.size():_envelope_motion=INF
	else:
		for index in _head_poses.size():_envelope_motion=maxf(_envelope_motion,_motion_bound(_head_poses[index],_envelope_poses[index],_bone_radius[index]))
	if _envelope_motion>.004:
		if _envelope_normals.is_empty():
			for x in range(-1,2):
				for y in range(-1,2):
					for z in range(-1,2):
						if x!=0 or y!=0 or z!=0:_envelope_normals.append(Vector3(x,y,z).normalized())
		var envelope:=_envelope(vertices,true)
		_envelope_limits=envelope.limits;_envelope_witnesses.assign(envelope.witnesses)
		_envelope_poses=_head_poses.duplicate();envelope_rebuilds+=1
	else:
		# With every vertex moving at most4mm, a vertex initially more than
		#10mm behind the support cannot overtake the retained support witness:
		# the two can close by at most8mm. Thus these extrema remain exact.
		var envelope:=_envelope(vertices,false)
		_envelope_limits=envelope.limits
	_envelope_motion=0.0

	var faces:=PackedVector3Array()
	for index:int in _head_indices:faces.append(vertices[index])
	var success:=_mesh.create_from_faces(faces)
	rebuild_count+=1;rebuild_usec=Time.get_ticks_usec()-began
	if success:_built_poses=_head_poses.duplicate()
	_head_dirty=not success
	return success

func capture()->void:
	if not is_instance_valid(skeleton) or not skeleton.is_inside_tree() or not skeleton.global_transform.is_finite():_ready=false;return
	for index in _bones.size():
		_poses[index]=skeleton.global_transform*skeleton.get_bone_global_pose(_bones[index])
		if not _poses[index].is_finite():_ready=false;return
	_ready=true

func nearest(point:Vector3,bounds:AABB)->Vector3:
	if not _ready or not point.is_finite():return Vector3.INF
	var best:=Vector3.INF;var distance:=INF
	_overlaps.clear();_posed=_skin(_starts,_slots,_points,_weights,_poses)
	for vertex in _posed.size():
		var at:=_posed[vertex]
		if bounds.has_point(at):_overlaps.append(vertex)
		var candidate:=at.distance_squared_to(point)
		if candidate<distance:distance=candidate;best=at
	return best

func _depth_upper_bound(point:Vector3,inverse:Transform3D,center:Vector3)->float:
	if not pruning_enabled:return INF
	var local:Vector3=inverse*point
	var distance:=local.distance_to(_head_center)
	if distance<1e-8:return INF
	var direction:Vector3=(local-_head_center)/distance
	var radius:=INF
	for index in _envelope_normals.size():
		var normal:=_envelope_normals[index];var denominator:=normal.dot(direction)
		if denominator>1e-8:radius=minf(radius,(_envelope_limits[index]+_envelope_motion+.000001-normal.dot(_head_center))/denominator)
	# Head uses uniform native scale; measure the ray's actual world scale.
	return (radius-distance)*(_head_frame.basis*direction).length()

func _sample(point:Vector3,inverse:Transform3D,center:Vector3,reach:float)->Dictionary:
	var local:Vector3=inverse*point
	var direction:Vector3=(local-_head_center).normalized()
	if direction.length_squared()<.5:return {}
	query_count+=1
	var hit:=_mesh.intersect_segment(_head_center+direction*reach,_head_center)
	if hit.is_empty():return {}
	var skin:Vector3=_head_frame*Vector3(hit.position)
	return {"shoulder":point,"head":skin,"depth":(skin-point).dot((point-center).normalized()),"kind":"drawn_head_cloth"}

func _motion_bound(a:Transform3D,b:Transform3D,radius:float)->float:
	return a.origin.distance_to(b.origin)+sqrt((a.basis.x-b.basis.x).length_squared()+(a.basis.y-b.basis.y).length_squared()+(a.basis.z-b.basis.z).length_squared())*radius

func _contact_unchanged()->bool:
	if _contact.is_empty() or _contact_rebuilds!=rebuild_count or _contact_poses.size()!=_poses.size():return false
	if _motion_bound(_head_frame,_contact_frame,_head_bounds.position.length()+_head_bounds.size.length())>.00005:return false
	for index in _poses.size():
		if _motion_bound(_poses[index],_contact_poses[index],_cloth_radius[index])>.00005:return false
	return true

func contact()->Dictionary:
	var began:=Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	var result:=_resolve_contact()
	if began>0:CPU_PROFILE.record("shared_nap_surface",began)
	return result

func _resolve_contact()->Dictionary:
	if not _ready or not _head_ready or not _refresh_head():return {}
	query_count=0
	if _contact_unchanged():cache_hits+=1;return _contact
	var center:Vector3=_head_frame*_head_center
	var cloth:=nearest(center,(_head_frame*_head_bounds).grow(.001))
	if not cloth.is_finite():return {}
	if native_enabled and _native!=null and _native.has_method("surface_query"):
		var result:Dictionary=_native.surface_query(_mesh,_posed,_overlaps,cloth,_triangles,_adjacent,_head_frame,_head_bounds,_envelope_normals,_envelope_limits,_envelope_motion,pruning_enabled)
		query_count=int(result.queries)
		var found:Dictionary=result.contact
		if not bool(result.refined):return found
		_contact=found;_contact_frame=_head_frame;_contact_poses=_poses.duplicate();_contact_rebuilds=rebuild_count
		return found
	var inverse:=_head_frame.affine_inverse()
	var reach:=_head_bounds.size.length()*2.0
	var best:Dictionary={};var depth:=-INF;var best_vertex:=-1
	query_count=0
	var candidates:Array[Vector2]=[]
	for vertex:int in _overlaps:candidates.append(Vector2(float(vertex),_depth_upper_bound(_posed[vertex],inverse,center)))
	candidates.sort_custom(func(a:Vector2,b:Vector2)->bool:return a.y>b.y)
	for entry:Vector2 in candidates:
		if entry.y<=depth:break
		var vertex:=int(entry.x)
		var candidate:=_sample(_posed[vertex],inverse,center,reach)
		if not candidate.is_empty() and float(candidate.depth)>depth:
			depth=candidate.depth;best=candidate;best_vertex=vertex
	if best.is_empty():return _sample(cloth,inverse,center,reach)
	# Contact may lie inside a shirt triangle, away from every mesh vertex.
	# Refine the winning vertex's actual incident faces, keeping all samples
	# on the posed shirt. This changes the target, not the overlap tolerance.
	var faces:Array=_adjacent.get(best_vertex,[])
	for face:int in faces:
		var a:Vector3=_posed[_triangles[face]];var b:Vector3=_posed[_triangles[face+1]];var c:Vector3=_posed[_triangles[face+2]]
		var point:Vector3=_posed[best_vertex]
		var step:=.5
		for iteration in 6:
			var local_best:Vector3=point
			for corner:Vector3 in [a,b,c]:
				var sample:=point.lerp(corner,step)
				if _depth_upper_bound(sample,inverse,center)<=depth:continue
				var candidate:=_sample(sample,inverse,center,reach)
				if not candidate.is_empty() and float(candidate.depth)>depth:
					depth=candidate.depth;best=candidate;local_best=candidate.shoulder
			point=local_best;step*=.5
	_contact=best;_contact_frame=_head_frame;_contact_poses=_poses.duplicate();_contact_rebuilds=rebuild_count
	return best

func finish()->void:
	if is_instance_valid(_head_rig) and _head_rig.skeleton_updated.is_connected(capture_head):_head_rig.skeleton_updated.disconnect(capture_head)
	if is_instance_valid(skeleton) and skeleton.skeleton_updated.is_connected(capture):skeleton.skeleton_updated.disconnect(capture)

func _skin(starts:PackedInt32Array,slots:PackedInt32Array,points:PackedVector3Array,weights:PackedFloat32Array,poses:Array[Transform3D])->PackedVector3Array:
	if native_enabled and _native!=null and _native.has_method("surface_skin"):
		return _native.surface_skin(starts,slots,points,weights,poses)
	var vertices:=PackedVector3Array()
	for vertex in starts.size()-1:
		var point:=Vector3.ZERO
		for index in range(starts[vertex],starts[vertex+1]):
			var pose:Transform3D=poses[slots[index]]
			point+=pose.basis*points[index]+pose.origin*weights[index]
		vertices.append(point)
	return vertices

func _envelope(vertices:PackedVector3Array,rebuild:bool)->Dictionary:
	if native_enabled and _native!=null and _native.has_method("surface_envelope"):
		return _native.surface_envelope(vertices,_envelope_normals,_envelope_witnesses,rebuild)
	var limits:=PackedFloat32Array();limits.resize(_envelope_normals.size())
	var witnesses:Array[PackedInt32Array]=[]
	for index in _envelope_normals.size():
		var limit:=-INF;var normal:=_envelope_normals[index]
		if rebuild:
			for point:Vector3 in vertices:limit=maxf(limit,normal.dot(point))
			var support:=PackedInt32Array()
			for vertex in vertices.size():
				if normal.dot(vertices[vertex])>=limit-.01:support.append(vertex)
			witnesses.append(support)
		else:
			for vertex:int in _envelope_witnesses[index]:limit=maxf(limit,normal.dot(vertices[vertex]))
		limits[index]=limit
	return {"limits":limits,"witnesses":witnesses if rebuild else _envelope_witnesses}
