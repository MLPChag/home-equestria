extends SkeletonModifier3D
## Cuddle-only damped targets and bounded CCD. Bone translations/scales are never solved.
## Modifier-local offsets layer over the live native pose, so gaze/breathing remain alive.
var session: Node
var tail := false
var regions: Dictionary = {}
var targets: Dictionary = {}
var offsets: Dictionary = {}
var visible_points: Dictionary = {}
var root_shift := Vector3.ZERO
var _base: Dictionary = {}
var solve_usec := 0
var max_residual := 0.0

func _ready() -> void:
	active=false
	if tail:
		var names:Array=[]
		for i:int in range(1,7):
			names.append("mTail%d"%i)
			var next:int=get_skeleton().find_bone("mTail%d"%mini(i+1,6))
			var anchor:Vector3=get_skeleton().get_bone_rest(next).origin*.5 if next>=0 else Vector3(0,0,.04)
			_add("tail_%d"%i,names.duplicate(),anchor,.07,"tail")
		return
	_add("hips",["pony_hips"],Vector3(0,.05,.08),.17,"torso")
	_add("belly",["pony_hips","pony_spine1","pony_spine2"],Vector3(0,-.05,0),.15,"torso")
	_add("chest",["pony_hips","pony_spine1","pony_spine2","pony_spine3"],Vector3(0,-.025,-.04),.15,"torso")
	_add("neck",["pony_spine3","pony_neck1","pony_neck2"],Vector3(0,.03,0),.10,"head")
	_add("head",["pony_neck1","pony_neck2","pony_head"],Vector3(0,.09,-.05),.16,"head")
	for side:String in ["L","R"]:
		for leg:String in ["fore","hind"]:
			var names:Array=["shoulder","upperArm","lowerArm","wrist","hand","finger"] if leg=="fore" else ["flank","femur","tibia","legLower","tarsal","hoof"]
			var chain:Array=[]
			for i:int in names.size():
				chain.append("pony_"+names[i]+"_"+side)
				if i>0:_add(leg+"_"+side+"_"+str(i),chain.duplicate(),Vector3.ZERO,.075,"limb")
		if session.mare.identity.has_wings():
			_add("wing_"+side,["pony_foldedWing_"+side],Vector3(-.06 if side=="L" else .06,0,.07),.09,"wing")

func _add(id:String,names:Array,anchor:Vector3,radius:float,kind:String)->void:
	var chain:Array[int]=[]
	for name:String in names:
		var bone:=get_skeleton().find_bone(name)
		if bone>=0:chain.append(bone)
	if chain.is_empty():return
	regions[id]={"chain":chain,"bone":chain.back(),"anchor":anchor,"radius":radius,"kind":kind}

func point(id:String)->Vector3:
	if visible_points.has(id):return visible_points[id]
	var r:Dictionary=regions[id]
	return get_skeleton().global_transform*(get_skeleton().get_bone_global_pose(r.bone)*r.anchor)

func choose(world:Vector3,reach:float)->Dictionary:
	var best:Dictionary={};var gap:=reach
	for id:String in regions:
		var distance:float=world.distance_to(point(id))-float(regions[id].radius)*session.mare.body_scale
		if distance<gap:gap=distance;best={"solver":self,"id":id,"point":point(id),"distance":maxf(0,distance)}
	return best

func take(id:String,hand:Transform3D)->bool:
	if not session.enabled or not regions.has(id):return false
	# One retained target per limb prevents competing wrist/elbow/hoof constraints.
	for other:String in targets.keys():
		if _group(other)!=_group(id):continue
		if targets[other].held:return false
		targets.erase(other)
	var p:=point(id)
	targets[id]={"id":id,"held":true,"position":p,"velocity":Vector3.ZERO,"goal":p,
		"hand_offset":hand.affine_inverse()*p,"hand_start":hand.basis.get_rotation_quaternion(),"rotation":Quaternion.IDENTITY,
		"bone_start":(get_skeleton().global_basis*get_skeleton().get_bone_global_pose(regions[id].bone).basis).orthonormalized(),
		"preferred":session.mare.to_local(p),"age":0.0,"contact":Vector3.INF,"contact_local":Vector3.ZERO}
	return true

func _group(id:String)->String:
	if id.begins_with("fore_") or id.begins_with("hind_"):return id.substr(0,id.rfind("_"))
	if tail:return "tail"
	if id in ["neck","head"]:return "head"
	return id

func guide(id:String,hand:Transform3D)->void:
	if not targets.has(id) or not hand.is_finite():return
	var row:Dictionary=targets[id]
	row.goal=hand*row.hand_offset
	row.rotation=(hand.basis.get_rotation_quaternion()*Quaternion(row.hand_start).inverse()).normalized()
	if point(id).distance_to(row.goal)>1.0:release(id)

func release(id:String)->void:
	if not targets.has(id):return
	var row:Dictionary=targets[id]
	row.held=false;row.age=0.0;row.preferred=session.mare.to_local(point(id));row.velocity=Vector3.ZERO
	row.position=point(id);row.goal=row.position
	# A close chest/arm contact can follow the partner, with a finite break distance.
	var support:Dictionary=session.partner_support(row.position,float(regions[id].radius))
	if not support.is_empty():row.contact_local=support.local;row.contact=row.position

func release_all()->void:
	for id:String in targets:release(id)

func clear()->void:
	targets.clear();offsets.clear();visible_points.clear();root_shift=Vector3.ZERO;active=false

func _process_modification_with_delta(delta:float)->void:
	if not is_instance_valid(session) or not is_instance_valid(session.mare):return
	var started:=Time.get_ticks_usec()
	var sk:=get_skeleton()
	var dt:=clampf(delta,.001,.033333)
	_base.clear()
	for region:Dictionary in regions.values():
		for bone:int in region.chain:
			if not _base.has(bone):_base[bone]=sk.get_bone_pose(bone)
	# Stored rotation offsets, never a frozen copy of the whole animated skeleton.
	for bone:int in offsets.keys():
		var q:Quaternion=offsets[bone]
		q=q.slerp(Quaternion.IDENTITY,1.0-exp(-dt*(.7 if _is_head(bone) else .035)))
		offsets[bone]=q
		var base:Transform3D=_base[bone]
		sk.set_bone_pose_rotation(bone,(base.basis.get_rotation_quaternion()*Quaternion.IDENTITY.slerp(q,session.blend)).normalized())
	if not tail:
		var hips:int=sk.find_bone("pony_hips")
		var base:Transform3D=_base[hips]
		sk.set_bone_pose_position(hips,base.origin+root_shift*session.blend)
	max_residual=0.0
	if session.enabled:
		for id:String in targets.keys():
			var row:Dictionary=targets[id];var r:Dictionary=regions[id]
			if not row.held:
				row.age+=dt
				if r.kind=="head" and row.age>.45:targets.erase(id);continue
				if row.age>45.0:targets.erase(id);continue
				row.goal=session.mare.to_global(row.preferred)
				if Vector3(row.contact).is_finite():
					var follow:Vector3=session.partner_point(row.contact_local)
					if not follow.is_finite() or follow.distance_to(point(id))>.22:row.contact=Vector3.INF
					else:row.goal=follow
				# Soft muscle memory sags under weight, not a mid-air pin.
				if not Vector3(row.contact).is_finite():row.goal+=Vector3.DOWN*minf(.085,row.age*.035)*session.mare.body_scale
			var previous:Vector3=row.position
			var steps:=maxi(1,ceili(dt*120.0));var h:=dt/steps
			for step:int in steps:
				var acceleration:Vector3=(row.goal-row.position)*100.0-row.velocity*20.0
				row.velocity=(row.velocity+acceleration.limit_length(12.0)*h).limit_length(.75)
				row.position+=row.velocity*h
			row.position=session.project_contact(previous,row.position,.045 if r.kind=="limb" else float(r.radius)*.8)
			if r.kind=="limb" and int(id.get_slice("_",2))>=3:
				row.position=_outside_body(id,row.position)
			if not Vector3(row.position).is_finite():row.position=previous;row.velocity=Vector3.ZERO
			_solve(r,row,dt)
			max_residual=maxf(max_residual,point_from_pose(r).distance_to(row.position))
		# Record only the solved delta. Native gaze and breath are sampled afresh next tick.
		for bone:int in _base:
			var q:Quaternion=Transform3D(_base[bone]).basis.get_rotation_quaternion().inverse()*sk.get_bone_pose_rotation(bone)
			offsets[bone]=q.normalized()
	for id:String in regions:visible_points[id]=point_from_pose(regions[id])
	solve_usec=Time.get_ticks_usec()-started

func point_from_pose(r:Dictionary)->Vector3:
	var sk:=get_skeleton()
	return sk.global_transform*(sk.get_bone_global_pose(r.bone)*r.anchor)

func _is_head(bone:int)->bool:
	var name:=get_skeleton().get_bone_name(bone)
	return name in ["pony_neck1","pony_neck2","pony_head"]

func _solve(r:Dictionary,row:Dictionary,dt:float)->void:
	var sk:=get_skeleton()
	var goal:Vector3=sk.global_transform.affine_inverse()*Vector3(row.position)
	if r.kind=="torso":
		var pull:Vector3=sk.global_basis.inverse()*(Vector3(row.position)-point_from_pose(r))
		root_shift=(root_shift+pull*.06).limit_length(.10)
		var hips:=sk.find_bone("pony_hips")
		sk.set_bone_pose_position(hips,Transform3D(_base[hips]).origin+root_shift)
	# Two bounded CCD passes per target; chains share parent motion naturally.
	for iteration:int in 2:
		for index:int in range(r.chain.size()-1,-1,-1):
			var bone:int=r.chain[index]
			var global_pose:=sk.get_bone_global_pose(bone)
			var from:Vector3=(sk.get_bone_global_pose(r.bone)*Vector3(r.anchor))-global_pose.origin
			var to:Vector3=goal-global_pose.origin
			var axis:=from.cross(to)
			if from.length()<.002 or to.length()<.002 or axis.length()<.000001:continue
			var turn:=Basis(axis.normalized(),minf(from.angle_to(to),dt*2.5))
			var parent:=sk.get_bone_parent(bone)
			var parent_basis:=sk.get_bone_global_pose(parent).basis if parent>=0 else Basis.IDENTITY
			var desired:Basis=parent_basis.inverse()*turn*global_pose.basis
			_write_limited(bone,desired)
	# Absolute held orientation: a stationary twisted controller must not keep winding up.
	if row.held:
		var desired_q:Quaternion=Quaternion(row.rotation)
		var angle:=desired_q.get_angle()
		if angle>.001:
			if angle>deg_to_rad(25):desired_q=Quaternion.IDENTITY.slerp(desired_q,deg_to_rad(25)/angle)
			var world:Basis=Basis(desired_q)*Basis(row.bone_start)
			var parent:=sk.get_bone_parent(r.bone)
			var parent_basis:Basis=sk.get_bone_global_pose(parent).basis if parent>=0 else Basis.IDENTITY
			var wanted:Basis=parent_basis.inverse()*sk.global_basis.inverse()*world
			_write_limited(r.bone,sk.get_bone_pose(r.bone).basis.slerp(wanted,1.0-exp(-dt*6)))

func _outside_body(id:String,point:Vector3)->Vector3:
	var sk:=get_skeleton()
	var hip:int=sk.find_bone("pony_hips");var chest:int=sk.find_bone("pony_spine3")
	var a:Vector3=sk.global_transform*sk.get_bone_global_pose(hip).origin
	var b:Vector3=sk.global_transform*sk.get_bone_global_pose(chest).origin
	var span:=b-a
	var near:=a+span*clampf((point-a).dot(span)/maxf(span.length_squared(),.0001),0.0,1.0)
	var radius:float=.105*session.mare.body_scale
	if point.distance_to(near)<radius:
		var direction:Vector3=point-near
		if direction.length()<.001:direction=session.mare.global_basis.x*(-1 if id.contains("_L_") else 1)
		point=near+direction.normalized()*radius
	# Opposite-side endpoints stay separated while the solver preserves limb lengths.
	for other:String in ["fore_L_5","fore_R_5","hind_L_5","hind_R_5"]:
		if _group(other)==_group(id):continue
		var p:Vector3=point_from_pose(regions[other])
		var delta:=point-p
		var separation:float=.075*session.mare.body_scale
		if delta.length()>.001 and delta.length()<separation:point=p+delta.normalized()*separation
	return point

func _write_limited(bone:int,desired:Basis)->void:
	var sk:=get_skeleton()
	var base:Basis=Transform3D(_base[bone]).basis
	var q:Quaternion=(base.orthonormalized().inverse()*desired.orthonormalized()).get_rotation_quaternion()
	var cap:float=deg_to_rad(30 if tail else (22 if _is_head(bone) else 55))
	var angle:=q.get_angle()
	if angle>cap:q=Quaternion.IDENTITY.slerp(q,cap/angle)
	desired=base*Basis(q)
	if not tail and session.mare.joint_limits.joints.has(bone):
		desired=session.mare.joint_limits.constrain(bone,desired)
	sk.set_bone_pose_rotation(bone,desired.orthonormalized().get_rotation_quaternion())
