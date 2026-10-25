extends "res://world/characters/locomotion/pony_tail.gd"
## Six articulated hair joints: standing mount is pinned; damped swing plus
## contact projection changes rotations only. Never translates/stretches the tail.
const ITERATIONS := 12
const SKIN_MARGIN := .009
# ponytail: one radius for the whole hair volume; per-joint radii from the skin samples if a tail still clips the floor.
const TAIL_RADIUS := .09
const MAX_CONTACT_ROTATION := .14
const CONTACT_VERSION := 2
static var _contact_cache:Dictionary={}
var skin_contacts:Array=[]
var _ground_wait:=0.
var _last_anchor:=Vector3.INF
var _contact_enabled:=true
## Projection passes per apply; the crowd lowers it for NEAR-tier ponies.
var contact_iterations:int=ITERATIONS
## Chain-vs-floor only; the crowd turns it on for NEAR ponies. HERO keeps the weighted
## skin scan, so close-up tails and the headless rig tests are unchanged.
var cheap_floor:=false
## floor_probe answers one plane wherever it is asked (the clip tiers' clip_floor_hit): probe once
## at the anchor for the whole chain. Only the plane's normal and height enter the contacts, so a
## different X/Z on the same plane gives the same depths.
var floor_is_plane:=false
var solve_usec:=0
var projected_contacts:=0
var sleeping:=false
var _quiet_frames:=0
var _previous_mount:=Transform3D.IDENTITY
var _after_angles:Array=[]
var _contact_mount:=Transform3D.IDENTITY
var _contact_kernel := preload("res://world/characters/hybrid_mare/tail_contact_kernel.gd").new()
const NATIVE := preload("res://world/characters/locomotion/native_solver.gd")
## PonySolverNative (docs/NATIVE_SOLVER_2026_09_25.md) for update() and the floor-only contact
## pass of apply_pose(); null keeps the GDScript below. Results are identical either way.
var native: RefCounted
## background_tail_physics.gd spends one more projection per pass; the native pass mirrors it.
var _native_retry := false

func bind(owner_pony:Node3D,supplied_skeleton:Skeleton3D=null)->void:
	super.bind(owner_pony,supplied_skeleton)
	gravity_amount=.22;inertia_amount=1.4
	_build_contacts()
	_contact_kernel.build(skin_contacts)
	native=NATIVE.create() if NATIVE.enabled("tail") else null
	if native!=null and (bones.is_empty() or angle_limits.size()<bones.size()):native=null
	if native!=null:
		var limits:=PackedFloat64Array()
		for limit in angle_limits:limits.append(float(limit))
		native.bind_tail(PackedVector3Array(_tips),_rest_bases,limits)

func _build_contacts()->void:
	var mesh_node:MeshInstance3D=pony.hair.find_child(pony.identity.hair_prefix+"DevkitTail",true,false)
	if mesh_node==null:return
	var key:=mesh_node.mesh.get_instance_id()
	if _contact_cache.has(key):skin_contacts=_contact_cache[key];return
	var saved_path:="res://world/characters/hybrid_mare/tail_contacts/"+String(pony.identity.id)+".res"
	if ResourceLoader.exists(saved_path):
		var saved:Resource=load(saved_path)
		if saved.get_meta("format",-1)==CONTACT_VERSION and saved.get_meta("anchor_version",-1)==mesh_node.mesh.get_meta("anchor_version",0) and saved.get_meta("source","")==pony.identity.hair_scene and int(saved.get_meta("source_mtime",-1))==FileAccess.get_modified_time(pony.identity.hair_scene):
			skin_contacts=saved.get_meta("contacts")
			_contact_cache[key]=skin_contacts
			return
	var candidates:Array=[];var low:=INF;var high:=-INF
	for surface in mesh_node.mesh.get_surface_count():
		var arrays:Array=mesh_node.mesh.surface_get_arrays(surface)
		var verts:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var joint_ids:PackedInt32Array=arrays[Mesh.ARRAY_BONES]
		var weights:PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
		var count:int=joint_ids.size()/verts.size()
		for v in verts.size():
			var influences:Array=[];var position:=Vector3.ZERO
			for i in count:
				var weight:=weights[v*count+i]
				if weight<=0.:continue
				var bind_id:=joint_ids[v*count+i]
				var bone:=skeleton.find_bone(mesh_node.skin.get_bind_name(bind_id))
				if bone<0:bone=mesh_node.skin.get_bind_bone(bind_id)
				var index:=bones.find(bone)
				assert(index>=0 or bone==_mount,"Tail contact is outside the anchored hair rig")
				var local:Vector3=mesh_node.skin.get_bind_pose(bind_id)*verts[v]
				influences.append([index,local,weight])
				position+=(skeleton.get_bone_global_rest(bone)*local)*weight
			candidates.append({"point":position,"influences":influences})
			low=minf(low,position.y);high=maxf(high,position.y)
	# Surface silhouettes plus per-joint hulls, cached once per shared mesh.
	var slots:Dictionary={}
	for index in candidates.size():
		var point:Vector3=candidates[index].point
		var band:=clampi(int((point.y-low)/maxf(high-low,.001)*16),0,15)
		for direction in 8:
			var angle:=direction*TAU/8.;var score:=point.x*cos(angle)+point.z*sin(angle)
			var slot:=band*8+direction
			if not slots.has(slot) or score>slots[slot][0]:slots[slot]=[score,index]
		# Different bone weights can expose an interior rest-pose vertex during
		# bending. Keep each dominant joint's local 3D hull, including distal tips.
		var strongest:Array=candidates[index].influences[0]
		for inf in candidates[index].influences:
			if inf[2]>strongest[2]:strongest=inf
		var local:Vector3=strongest[1]
		for x in [-1,0,1]:
			for y in [-1,0,1]:
				for z in [-1,0,1]:
					if x==0 and y==0 and z==0:continue
					var slot:int=128+(int(strongest[0])+1)*27+(x+1)*9+(y+1)*3+z+1
					var score:=local.dot(Vector3(x,y,z))
					if not slots.has(slot) or score>slots[slot][0]:slots[slot]=[score,index]
	var used:Dictionary={}
	for slot in slots:
		var index:int=slots[slot][1]
		if not used.has(index):skin_contacts.append(candidates[index].influences);used[index]=true
	_contact_cache[key]=skin_contacts

func reset()->void:
	super.reset()
	sleeping=false;_quiet_frames=0;_after_angles.clear();_ground_wait=0.

func kick(world_impulse:Vector3)->void:
	if not world_impulse.is_finite():return
	sleeping=false;_quiet_frames=0
	var frames:=_frames(_previous_mount)
	for i in bones.size():
		var local:Vector3=frames[i].basis.orthonormalized().inverse()*world_impulse
		angular_velocity[i]=(angular_velocity[i]+_tips[i].normalized().cross(local)*lerpf(.3,1.,i/float(bones.size()-1))).limit_length(MAX_ANGULAR_SPEED)

func update(delta:float,world_acceleration:Vector3)->void:
	_ground_wait-=minf(delta,.25)
	if sleeping:
		var mount:=skeleton.global_transform*skeleton.get_bone_global_pose(_mount)
		if not mount.is_equal_approx(_previous_mount) or world_acceleration.length_squared()>.0025:
			sleeping=false;_quiet_frames=0
		else:return
	if native!=null:_update_native(delta,world_acceleration)
	else:super.update(delta,world_acceleration)

## pony_tail.gd update() in PonySolverNative (this class's contact forces are zero).
func _update_native(delta:float,world_acceleration:Vector3)->void:
	if bones.is_empty() or delta<=0. or not is_finite(delta):return
	var mount_frame:=skeleton.global_transform*skeleton.get_bone_global_pose(_mount)
	var result:Array=native.tail_update(PackedVector3Array(angles),PackedVector3Array(angular_velocity),_base_pose,
		mount_frame,delta,world_acceleration,[_previous_mount_basis,_previous_mount_velocity,_mount_history],
		PackedFloat64Array([gravity_amount,inertia_amount]))
	_store_native(result[0],result[1])
	_previous_mount_basis=result[2];_previous_mount_velocity=result[3];_mount_history=true

func _store_native(native_angles:PackedVector3Array,native_velocity:PackedVector3Array)->void:
	for i in angles.size():
		angles[i]=native_angles[i];angular_velocity[i]=native_velocity[i]

func _contact_forces(_frames_input:Array[Transform3D])->Array[Vector3]:
	# Positional contact constraints below replace the old capped penalty force.
	var result:Array[Vector3]=[];result.resize(bones.size());result.fill(Vector3.ZERO)
	return result

func apply_pose(pose:Array[Transform3D])->void:
	if bones.is_empty():return
	var started:=Time.get_ticks_usec()
	for i in bones.size():
		# Always start from the standing tail's authored local offsets and shape.
		_base_pose[i]=skeleton.get_bone_rest(bones[i])
	var mount:=skeleton.global_transform*_pose_global(_mount,pose)
	_contact_mount=mount
	var anchor:Vector3=mount*_base_pose[0].origin
	if _last_anchor.is_finite() and anchor.distance_to(_last_anchor)>1.:
		reset();_ground_wait=0.
	_last_anchor=anchor
	if native!=null and cheap_floor:_contacts_native(pose,mount,anchor)
	else:_contacts(pose,mount,anchor)
	if not _after_angles.is_empty() and _contact_enabled and mount.is_equal_approx(_previous_mount):
		var movement:=0.
		for i in angles.size():movement=maxf(movement,angles[i].distance_to(_after_angles[i]))
		# Contact settling below 0.06° per tick can sleep instead of perpetually
		# recomputing a visually stationary hair mesh against the same floor.
		_quiet_frames=_quiet_frames+1 if movement<.001 else 0
		if _quiet_frames>=30:
			sleeping=true;angular_velocity.fill(Vector3.ZERO)
	else:_quiet_frames=0
	_previous_mount=mount;_after_angles=angles.duplicate()
	solve_usec=Time.get_ticks_usec()-started

func _contacts(pose:Array[Transform3D],mount:Transform3D,anchor:Vector3)->void:
	var frames:=_frames(mount)
	# Probe from at least root height, so a point pushed below ground can recover.
	if _ground_wait<=0. and floor_probe.is_valid():
		_ground_wait=.1 if sleeping else .05
		if floor_is_plane:_share_floor_plane(anchor)
		else:
			for i in bones.size():
				var point:Vector3=frames[i]*_tips[i]
				point.y=maxf(anchor.y,point.y)
				var plane:Dictionary=floor_probe.call(point)
				# A different ray hit X/Z on the same plane is not moving ground.
				if sleeping and (plane.is_empty()!=_floor_planes[i].is_empty() or (not plane.is_empty() and (absf((Vector3(plane.position)-Vector3(_floor_planes[i].position)).dot(plane.normal))>.001 or Vector3(plane.normal).distance_to(_floor_planes[i].normal)>.001))):
					sleeping=false;_quiet_frames=0
				_floor_planes[i]=plane
	projected_contacts=0
	if collision_enabled and _contact_enabled and not sleeping:
		for iteration in contact_iterations:
			var contact:=_deepest(frames,anchor)
			if contact.is_empty() or contact.depth<.0005:break
			_project(contact,frames,mount)
			frames=_frames(mount)
			projected_contacts+=1
		var remaining:=_deepest(frames,anchor)
		max_penetration=0. if remaining.is_empty() else maxf(0.,remaining.depth-SKIN_MARGIN)
	else:max_penetration=0.
	for i in bones.size():
		var local:=_base_pose[i]
		local.basis=_rest_bases[i]*_angle_basis(angles[i])*_rest_bases[i].inverse()*local.basis
		pose[bones[i]]=local

## _contacts() with cheap_floor in PonySolverNative; the floor probes stay here.
func _contacts_native(pose:Array[Transform3D],mount:Transform3D,anchor:Vector3)->void:
	if _ground_wait<=0. and floor_probe.is_valid():
		_ground_wait=.1 if sleeping else .05
		if floor_is_plane:_share_floor_plane(anchor)
		else:
			var tips:PackedVector3Array=native.tail_tip_points(PackedVector3Array(angles),_base_pose,mount)
			for i in bones.size():
				var point:Vector3=tips[i]
				point.y=maxf(anchor.y,point.y)
				var plane:Dictionary=floor_probe.call(point)
				# A different ray hit X/Z on the same plane is not moving ground.
				if sleeping and (plane.is_empty()!=_floor_planes[i].is_empty() or (not plane.is_empty() and (absf((Vector3(plane.position)-Vector3(_floor_planes[i].position)).dot(plane.normal))>.001 or Vector3(plane.normal).distance_to(_floor_planes[i].normal)>.001))):
					sleeping=false;_quiet_frames=0
				_floor_planes[i]=plane
	var project:=collision_enabled and _contact_enabled and not sleeping
	var result:Array=native.tail_project(PackedVector3Array(angles),PackedVector3Array(angular_velocity),_base_pose,
		mount,_floor_planes,contact_iterations,PackedInt32Array([int(project),int(_native_retry)]))
	_store_native(result[0],result[1])
	projected_contacts=result[2]
	max_penetration=(0. if result[3]<0. else maxf(0.,result[3]-SKIN_MARGIN)) if project else 0.
	var locals:Array=result[4]
	for i in bones.size():pose[bones[i]]=locals[i]

## A plane probe: one call for every joint (floor_is_plane). Same wake test as the per-tip probes.
func _share_floor_plane(anchor:Vector3)->void:
	var plane:Dictionary=floor_probe.call(anchor)
	for i in bones.size():
		if sleeping and (plane.is_empty()!=_floor_planes[i].is_empty() or (not plane.is_empty() and (absf((Vector3(plane.position)-Vector3(_floor_planes[i].position)).dot(plane.normal))>.001 or Vector3(plane.normal).distance_to(_floor_planes[i].normal)>.001))):
			sleeping=false;_quiet_frames=0
		_floor_planes[i]=plane

func _point(influences:Array,frames:Array[Transform3D])->Vector3:
	var point:=Vector3.ZERO
	for inf in influences:point+=((_contact_mount if inf[0]<0 else frames[inf[0]])*Vector3(inf[1]))*float(inf[2])
	return point

## cheap_floor: the chain's segment midpoints and tips against the floor, no body scan.
## dev 2026-09-17: "tail physics is NOT that important, jigglebones and floor collision".
## Measured one mare: 19 µs standing / 123 µs sitting against 232 / 510 for the skin scan.
func _deepest(frames:Array[Transform3D],anchor:Vector3)->Dictionary:
	if not cheap_floor:return _contact_kernel.deepest(frames, _contact_mount, anchor, _floor_planes, body_capsules, SKIN_MARGIN)
	var best:={}
	for i in bones.size():
		var plane:Dictionary=_floor_planes[i]
		if plane.is_empty():continue
		for t in [.5,1.]:
			var offset:Vector3=_tips[i]*t
			var depth:=Vector3(plane.normal).dot(Vector3(plane.position)-frames[i]*offset)+TAIL_RADIUS
			if depth>best.get("depth",0.):best={"inf":[[i,offset,1.]],"depth":depth,"normal":plane.normal}
	return best

func _project(contact:Dictionary,frames:Array[Transform3D],mount:Transform3D)->void:
	var gradients:Array[Vector3]=[];var denominator:=0.
	for joint in bones.size():
		var lever:=Vector3.ZERO
		for inf in contact.inf:
			if inf[0]>=joint:lever+=(frames[inf[0]]*Vector3(inf[1])-frames[joint].origin)*float(inf[2])
		var gradient:=lever.cross(Vector3(contact.normal))
		# The joint axis is its authored segment, not a guessed world axis.
		var axis:Vector3=(frames[joint].basis*_tips[joint]).normalized()
		gradient-=axis*gradient.dot(axis)
		gradients.append(gradient);denominator+=gradient.length_squared()
	if denominator<.0000001:return
	for joint in bones.size():
		var rotation:Vector3=(gradients[joint]*(contact.depth*.85/denominator)).limit_length(MAX_CONTACT_ROTATION)
		if rotation.length_squared()<.00000001:continue
		# Solve all gradients from one FK sample; next iteration refreshes it.
		var parent:Basis=mount.basis if joint==0 else frames[joint-1].basis
		var desired:=parent.inverse()*_angle_basis(rotation)*frames[joint].basis
		var relative:=(_rest_bases[joint].inverse()*desired).orthonormalized().get_rotation_quaternion()
		if relative.w<0.:relative=-relative
		var vector:=_rotation_vector(relative)
		var direction:=_tips[joint].normalized();vector-=direction*vector.dot(direction)
		var before:Vector3=angles[joint]
		angles[joint]=vector.limit_length(angle_limits[joint])
		var correction:Vector3=angles[joint]-before
		if correction.length_squared()>.0000001:
			var normal:=correction.normalized()
			angular_velocity[joint]-=normal*minf(0.,angular_velocity[joint].dot(normal))
