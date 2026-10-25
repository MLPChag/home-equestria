extends Node
## Keep the viewpoint outside skulls. Carried ponies yield before the player's rig does.
const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
const QUERY=preload("res://player/head_contact_query.gd")
const EYE_RADIUS:=.035
var camera:Camera3D
var body:Node3D
var heads:Array[Node3D]=[]
var _query:=QUERY.new()
var _previous:=Vector3.INF
## A mare kissing Anon presses her face right up to his (round 11, dev 2026-09-28: "the eye guard
## must not push him away during a kiss"): her head leaves the 3.5 cm eye pass while her face is
## in a kiss (pony_affection.kissing_face()). affection_pose.gd keeps her skull and nose clear of
## both of his eyes. As a last resort only, each eye keeps KISS_EYE_RADIUS from her head shapes.
var _kissing:Array[RID]=[]
const KISS_EYE_RADIUS:=.012
const EYE_HALF:=.032
## Heads (snoot bodies) farther than this from the eye are skipped in resolve().
const FAR_HEAD:=4.0

func setup(view:Camera3D,movement:Node3D)->void:
	camera=view;body=movement;process_physics_priority=90;process_priority=-30

func add_pony(pony:Node3D)->void:
	pony.set_meta("player_head_guard",self)
	if pony.boop_node!=null:heads.append(pony.boop_node.snoot)

func limit_carry(pony:Node3D,translation:Vector3)->Vector3:
	if not is_instance_valid(camera) or not camera.is_inside_tree() or not is_instance_valid(pony) or not pony.is_inside_tree():return translation
	if not camera.global_position.is_finite():return translation
	var excluded:Array[RID]=[]
	for head:Node3D in heads:
		if is_instance_valid(head) and head.is_inside_tree() and head.get_parent()!=pony:excluded.append(head.get_rid())
	var eye:=camera.global_position
	var affection := pony.get_node_or_null("Affection")
	if affection != null and affection.kissing_face():
		# Use the same per-eye clearance as resolve(). The ordinary 3.5 cm eye sphere
		# would otherwise fight the kiss pose on every hand update and eject her from the grip.
		var side := camera.global_basis.x.normalized()*EYE_HALF
		var allowed := translation
		for at: Vector3 in [eye-side, eye+side]:
			var out := _query.project(camera.get_world_3d().direct_space_state, at, at-allowed, KISS_EYE_RADIUS, excluded)
			allowed = at-out
		return allowed
	# Moving the pony toward the eye equals sweeping the eye in the opposite direction.
	var safe:=_query.project(camera.get_world_3d().direct_space_state,eye,eye-translation,EYE_RADIUS,excluded)
	return eye-safe

func _physics_process(_delta:float)->void:_resolve_timed()
## The frame pass only matters when the eye moved since the last pass: heads move on physics ticks,
## which run their own pass (2026-10-23 CPU pass: the guard ran twice every frame).
var _resolved_eye:=Vector3.INF
var _resolved_tick:=-1
func _process(_delta:float)->void:
	if is_instance_valid(camera) and camera.is_inside_tree() and camera.global_position==_resolved_eye and Engine.get_physics_frames()==_resolved_tick:return
	_resolve_timed()
func _resolve_timed()->void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	resolve()
	if is_instance_valid(camera) and camera.is_inside_tree():_resolved_eye=camera.global_position;_resolved_tick=Engine.get_physics_frames()
	if started > 0: CPU_PROFILE.record("head_guard", started)

func resolve()->void:
	if not is_instance_valid(camera) or not is_instance_valid(body) or not camera.is_inside_tree() or not body.is_inside_tree():
		_previous=Vector3.INF
		_kissing.clear()
		return
	var eye:=camera.global_position
	if not eye.is_finite():return
	var space:=camera.get_world_3d().direct_space_state
	var from:Vector3=_previous if _previous.is_finite() else eye
	if from.distance_to(eye)>1.0:from=eye
	_kissing.clear()
	var others:Array[RID]=[]
	for head:Node3D in heads:
		# Streamed or temporarily removed heads remain valid objects but have no world pose.
		# Keep their registration so reattachment resumes both eye passes immediately.
		if not is_instance_valid(head) or not head.is_inside_tree():continue
		# A snoot this far from the eye cannot reach either eye pass (sweeps stop at 1 m; the skull
		# shape sits well under 1 m from its snoot), so leaving it out of both exclude lists gives the
		# same answer and skips its Affection lookups (dev 2026-10-20 perf pass; 45 ponies cost
		# ~41 us per call, twice a frame). Rollback: FAR_HEAD := INF.
		if head.global_position.distance_squared_to(eye)>FAR_HEAD*FAR_HEAD:continue
		var affection:Node=head.get_parent().get_node_or_null("Affection")
		if affection!=null and affection.has_method("kissing_face") and affection.kissing_face():_kissing.append(head.get_rid())
		else:others.append(head.get_rid())
	var safe:=_query.project(space,from,eye,EYE_RADIUS,_kissing)
	var correction:=safe-eye
	if not _kissing.is_empty():
		# Her kissing head against each real eye, with a small ball: normally never touched.
		var side:=camera.global_basis.x.normalized()*EYE_HALF
		for at:Vector3 in [safe-side,safe+side]:
			var out:=_query.project(space,at,at,KISS_EYE_RADIUS,others)
			if out.distance_squared_to(at)>.0000001:correction+=out-at;safe+=out-at
	if correction.length_squared()>.0000001:
		var hit:=_query.touching(space,eye,EYE_RADIUS)
		var collider:Object=instance_from_id(int(hit.get("collider_id",0))) if not hit.is_empty() else null
		var pony:Node3D=collider.get_parent() if collider is Node3D else null
		if is_instance_valid(pony) and pony.has_method("is_held") and pony.is_held():
			pony.global_position-=correction
			pony.boop_node._sync_snoot()
		else:
			# Translate the movement rig, never the runtime's tracked local head pose.
			body.global_position+=correction
	_previous=camera.global_position
