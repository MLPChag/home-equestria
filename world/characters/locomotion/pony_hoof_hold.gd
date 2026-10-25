extends RefCounted
## One articulated limb per mare. Unreachable hands meet joint limits, never bone stretch.
const FK:=preload("res://world/characters/locomotion/limb_solver.gd")
var pony:CharacterBody3D
var leg_index:=-1
var bone:=-1
var anchor:=Vector3.ZERO
var target:=Vector3.ZERO
var softened:=Vector3.ZERO
var spring_velocity:=Vector3.ZERO
var neutral:=Vector3.ZERO
var pose:Dictionary={}
var release_weight:=0.0
var grab_count:=0
var residual:=0.0
var _delta:=1.0/60.0
## Scripted gesture (no hand): the knee is led forward and up, the cannon folds back at the
## carpus, and it all lets go after `gesture_left` seconds. See raise().
var gesture_left:=0.0
var curl:=0.0
var curl_bone:=-1
const RAISE_FORWARD:=.13   # knee led this far forward (m at canon size)
const RAISE_UP:=.1         # and this far up: forearm slants forward-down, as in the show
const CURL_DEG:=-75.0       # carpus fold; sign chosen from renders (cannon hangs back under)
const DOOR_FOLD_DEG:=-90.0  # door push: level forearm, cannon straight down (joint limits may stop it short)
func bind(actor:CharacterBody3D):pony=actor
func active()->bool:return leg_index>=0 and release_weight==0.0
func owns(i:int)->bool:return i==leg_index
func frame()->Transform3D:return pony.global_transform*pony.pivot.transform*pony._model_frame
func globals()->Array[Transform3D]:
	return FK.forward_kinematics(pony.profile.parents,pony.corrected_pose if not pony.corrected_pose.is_empty() else pony.profile.rest,frame())
func candidate(point:Vector3,reach:float=.09)->Dictionary:
	if leg_index>=0 or not point.is_finite() or pony._held:return {}
	var fk:=globals();var best:={};var distance:=reach
	for i in 4:
		var leg:Dictionary=pony.profile.legs[i]
		# Entire limb below its body attachment, plus the hoof's terminal segment.
		var chain:Array[int]=[leg.root,leg.proximal,leg.middle,leg.leaf,leg.end]
		for k in range(1,chain.size()):
			var a:=fk[chain[k-1]].origin;var b:=fk[chain[k]].origin
			var ab:=b-a;var q:=a+ab*clampf((point-a).dot(ab)/maxf(ab.length_squared(),.000001),0,1)
			var d:=point.distance_to(q)
			if d<distance:
				distance=d;best={"leg":i,"bone":chain[k-1],"anchor":fk[chain[k-1]].affine_inverse()*point,"distance":d}
	return best
func begin(hit:Dictionary,point:Vector3)->bool:
	if hit.is_empty() or leg_index>=0 or not pony.grounded() or pony._held:return false
	if pony.posture!=null and pony.posture.active():pony.request_posture("stand");return false
	leg_index=hit.leg;bone=hit.bone;anchor=hit.anchor;target=point;softened=point;spring_velocity=Vector3.ZERO
	neutral=pony.global_transform.affine_inverse()*point;release_weight=0.0;pose.clear()
	for index:int in pony.profile.legs[leg_index].chain:pose[index]=pony.corrected_pose[index]
	pony.feet[leg_index].planted=false;pony.feet[leg_index].valid=false
	pony.set_sim_tier(pony.SimTier.HERO);pony.stop();grab_count+=1
	return true
## [hoofraise]: lift a forehoof like the show's raised, curled foreleg. side 0 = left, 1 = right.
func raise(side:int,seconds:=1.8)->bool:
	return _lift(side,seconds,Vector3.INF)

## Opening a door (earth ponies, pegasi): the forearm comes up level toward `point` and the
## cannon hangs straight down from the knee, a 90 degree bend at the carpus, hoof to the door.
func push_door(side:int,point:Vector3,seconds:=1.3)->bool:
	return _lift(side,seconds,point)

## Excited earth pony (excitement.gd): one hind hoof flicked back and up behind her, then down.
## side 0 = left, 1 = right. The leg's own joint limits decide how far it really goes.
const KICK_BACK:=.22
const KICK_UP:=.36
func kick(side:int,seconds:=.6)->bool:
	if leg_index>=0 or pony._held or not pony.grounded():return false
	if pony.posture!=null and pony.posture.active():return false
	var i:=-1
	for k in pony.profile.legs.size():
		if String(pony.profile.legs[k].name)==("RL" if side==0 else "RR"):i=k
	if i<0:return false
	var leg:Dictionary=pony.profile.legs[i]
	var fk:=globals()
	var hoof:Vector3=fk[leg.end].origin
	var s:float=pony.get("body_scale") if pony.get("body_scale")!=null else 1.0
	var goal:=hoof+(frame().basis.z).normalized()*KICK_BACK*s+Vector3.UP*KICK_UP*s
	if not begin({"leg":i,"bone":leg.leaf,"anchor":fk[leg.leaf].affine_inverse()*hoof},goal):return false
	gesture_left=seconds
	_gesture_local=pony.global_transform.affine_inverse()*goal
	return true

func _lift(side:int,seconds:float,toward:Vector3)->bool:
	if leg_index>=0 or pony._held or not pony.grounded():return false
	if pony.posture!=null and pony.posture.active():return false
	var i:=-1
	for k in pony.profile.legs.size():
		if String(pony.profile.legs[k].name)==("FL" if side==0 else "FR"):i=k
	if i<0:return false
	var leg:Dictionary=pony.profile.legs[i]
	var fk:=globals()
	var knee_bone:int=pony.skeleton.find_bone("pony_wrist_"+("L" if side==0 else "R"))
	if knee_bone<0:return false
	var knee:Vector3=fk[knee_bone].origin
	var forward:Vector3=-(frame().basis.z).normalized();var up:=Vector3.UP
	var s:float=pony.get("body_scale") if pony.get("body_scale")!=null else 1.0
	var goal:=knee+forward*RAISE_FORWARD*s+up*RAISE_UP*s
	var fold:=CURL_DEG
	if toward.is_finite():
		# Face the door if it is roughly ahead; otherwise straight ahead.
		var to_door:=toward-knee;to_door.y=0
		if to_door.length()>.05 and to_door.normalized().dot(forward)>.2:forward=to_door.normalized()
		var elbow:Vector3=fk[leg.middle].origin
		goal=elbow+forward*elbow.distance_to(knee)
		fold=DOOR_FOLD_DEG
	var hit:={"leg":i,"bone":leg.middle,"anchor":fk[leg.middle].affine_inverse()*knee}
	if not begin(hit,goal):return false
	curl=deg_to_rad(fold);curl_bone=knee_bone;gesture_left=seconds
	# A talking raise is held in her own frame, so turning to face him carries the hoof along.
	_gesture_local=pony.global_transform.affine_inverse()*goal if not toward.is_finite() else Vector3.INF
	return true

func update(point:Vector3)->void:
	if active() and point.is_finite():target=point
func release()->void:
	if leg_index<0:return
	release_weight=1.0;pony.stop()
## Body-frame goal of a talking raise (INF otherwise).
var _gesture_local:=Vector3.INF
func reset()->void:
	leg_index=-1;pose.clear();release_weight=0.0;residual=0.0;gesture_left=0.0;curl=0.0;curl_bone=-1;_gesture_local=Vector3.INF
func grip()->Transform3D:
	if leg_index<0:return Transform3D.IDENTITY
	var fk:=globals();var result:=fk[bone];result.origin=result*anchor;return result
func prepare(delta:float)->void:
	_delta=minf(delta,.05)
	if not active():return
	var scripted:=gesture_left>0.0
	if scripted:
		gesture_left-=delta
		if gesture_left<=0.0:release();return
		if _gesture_local.is_finite():target=pony.global_transform*_gesture_local
	if pony._held or not pony.grounded() or target.distance_to(grip().origin)>1.5:
		release();return
	var steps:=maxi(1,ceili(minf(delta,.05)*120.0))
	var dt:=minf(delta,.05)/steps
	for step in steps:
		spring_velocity+=((target-softened)*80.0-spring_velocity*18.0).limit_length(6.0)*dt
		spring_velocity=spring_velocity.limit_length(1.1)
		softened+=spring_velocity*dt
	# Only a hand holding her hoof leads her body; a gesture's fixed goal tugged her toward it
	# while she turned to face him, and hoof and body fought (dev 2026-10-14: jitter).
	if scripted:return
	var pull:=target-pony.global_transform*neutral;pull.y=0
	var speed:=clampf((pull.length()-.16)*1.6,0,.32)
	pony._desired=pull.normalized()*speed
	pony._face_direction=Vector3.ZERO
func apply_source(source:Array[Transform3D],delta:float)->void:
	if leg_index<0:return
	for index:int in pose:
		source[index]=source[index].interpolate_with(pose[index],release_weight if release_weight>0 else 1.0)
	if release_weight>0:
		release_weight=maxf(0,release_weight-delta/.35)
		if release_weight==0:
			pony.feet[leg_index].planted=false;pony.feet[leg_index].offset=Vector3.ZERO;reset()
func solve(local:Array[Transform3D])->void:
	if not active():return
	var leg:Dictionary=pony.profile.legs[leg_index]
	var mutable:Array[int]=[];var current:=bone
	while current>=0:
		if current in [leg.root,leg.proximal,leg.middle,leg.leaf]:mutable.append(current)
		if current==leg.root:break
		current=pony.profile.parents[current]
	var before:={}
	for index in mutable:before[index]=local[index]
	var desired:=softened
	for iteration in 6:
		var fk:=FK.forward_kinematics(pony.profile.parents,local,frame())
		# The sole remains above physics terrain even when the hand reaches through it.
		var sole:Vector3=fk[leg.leaf]*Vector3(pony.feet[leg_index].dynamic_sole)
		var floor_hit:Dictionary=pony._probe(sole)
		if not floor_hit.is_empty():desired.y=maxf(desired.y,desired.y+float(floor_hit.position.y)+.003-sole.y)
		var closest:Vector3=pony.self_collision._closest_on_segment(sole,frame()*pony.self_collision.BELLY_FROM,frame()*pony.self_collision.BELLY_TO)
		var away:Vector3=sole-closest;var radius:float=pony.self_collision.BELLY_RADIUS+pony.self_collision.HOOF_RADIUS
		if away.length()<radius:desired+=away.normalized()*(radius-away.length())
		for index in mutable:
			fk=FK.forward_kinematics(pony.profile.parents,local,frame())
			var pos:=fk[bone]*anchor;var origin:=fk[index].origin
			FK.rotate_world(local,fk,pony.profile.parents,frame(),index,Quaternion.IDENTITY.slerp(FK.alignment(pos-origin,desired-origin),.6))
			local[index].basis=pony.joint_limits.constrain(index,local[index].basis)
			var old:Quaternion=before[index].basis.orthonormalized().get_rotation_quaternion()
			var new:=local[index].basis.orthonormalized().get_rotation_quaternion()
			var angle:=old.angle_to(new)
			if angle>2.8*_delta:local[index]=before[index].interpolate_with(local[index],2.8*_delta/angle)
	if curl!=0.0 and curl_bone>=0:
		# Fold the cannon back at the carpus, eased in, inside the joint's own range.
		var fold:=FK.forward_kinematics(pony.profile.parents,local,frame())
		var wanted:=local[curl_bone]
		FK.rotate_world(local,fold,pony.profile.parents,frame(),curl_bone,Quaternion(frame().basis.x.normalized(),curl))
		local[curl_bone].basis=pony.joint_limits.constrain(curl_bone,local[curl_bone].basis)
		var old_q:Quaternion=(pose[curl_bone] if pose.has(curl_bone) else wanted).basis.orthonormalized().get_rotation_quaternion()
		var angle:=old_q.angle_to(local[curl_bone].basis.orthonormalized().get_rotation_quaternion())
		if angle>4.0*_delta:local[curl_bone]=(pose[curl_bone] if pose.has(curl_bone) else wanted).interpolate_with(local[curl_bone],4.0*_delta/angle)
	for index:int in leg.chain:pose[index]=local[index]
	var fk:=FK.forward_kinematics(pony.profile.parents,local,frame())
	residual=(fk[bone]*anchor).distance_to(target)
