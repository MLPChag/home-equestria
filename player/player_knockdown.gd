extends RefCounted
## Collision-driven knockback and recoverable recline; never rotates a tracked camera.
var active := false
var amount := 0.0
var elapsed := 0.0
var grounded_time := 0.0
var recovering := false
var camera: Camera3D
var origin: Node3D
var origin_start := Vector3.ZERO
var camera_y := 0.0
var collider: CollisionShape3D
var standing_height := 1.8
var collider_start := Vector3.ZERO
var avatar: Node3D
var frame: Node3D
var left: Node3D
var right: Node3D
var temporary_avatar := false

func start(body: CharacterBody3D, impulse: Vector3) -> bool:
	if active or not impulse.is_finite() or body.get("controls_locked")==true:return false
	if is_instance_valid(body.get("seat")):body.stand_up()
	# AnonPony falls with her own body (player/pony_form.gd); no human recline, and never a
	# temporary human AnonBody.
	var form:Variant=body.get("form_driver")
	if is_instance_valid(form):
		(form as Node).knockdown(impulse)
		return false
	camera=body.find_child("XRCamera",true,false) as Camera3D
	if camera==null:camera=body.get_node_or_null("Camera3D") as Camera3D
	if camera==null:return false
	origin=body.find_child("XROrigin",true,false) as Node3D if camera is XRCamera3D else null
	collider=body.get_node_or_null("BodyCollider") as CollisionShape3D if origin!=null else body.get_node_or_null("Collision") as CollisionShape3D
	# Seated VR (player/seated_player.tscn): the headset view on the desktop's Collision capsule.
	if collider==null and origin!=null:collider=body.get_node_or_null("Collision") as CollisionShape3D
	if collider==null or not collider.shape is CapsuleShape3D:return false
	standing_height=collider.shape.height;collider_start=collider.position;camera_y=camera.position.y
	# Seated, the tracked head sits at its origin, so the eye drop is measured from the body.
	if body.get("headset_view")==true:camera_y=camera.global_position.y-body.global_position.y
	if origin!=null:origin_start=origin.position
	frame=Node3D.new();frame.name="FallenPose";body.add_child(frame)
	frame.global_basis=Basis(Vector3.UP,body.global_rotation.y)
	avatar=body.get_node_or_null("AnonBody")
	if origin==null:
		left=Node3D.new();right=Node3D.new();frame.add_child(left);frame.add_child(right)
		if avatar==null:
			avatar=load("res://player/anon_body.tscn").instantiate();avatar.calibration_path=""
			body.add_child(avatar);avatar.setup(camera,left,right);temporary_avatar=true
	if avatar!=null:avatar.couch_rest_frame=frame
	body.flying=false;body.velocity=impulse.limit_length(7.0)
	active=true;elapsed=0.0;grounded_time=0.0;amount=0.0;recovering=false
	body.set_meta("knocked_down",true)
	return true

func step(body: CharacterBody3D, delta: float, get_up: bool) -> bool:
	if not active:return false
	elapsed+=delta
	if body.is_on_floor():grounded_time+=delta
	else:body.velocity.y-=9.8*delta
	body.velocity.x=move_toward(body.velocity.x,0.0,delta*(5.0 if body.is_on_floor() else 1.0))
	body.velocity.z=move_toward(body.velocity.z,0.0,delta*(5.0 if body.is_on_floor() else 1.0))
	body.move_and_slide()
	# A pony or table over him must not pin him down for good (dev 2026-09-28: "stuck after a
	# buck"): past five seconds on the ground he gets up anyway and the body slides free.
	if grounded_time>.65 and (get_up or grounded_time>3.0) and (_stand_clear(body) or grounded_time>5.0):recovering=true
	amount=move_toward(amount,0.0 if recovering else 1.0,delta/(.65 if recovering else .35))
	var crouched_height:float=maxf(collider.shape.radius*2.0,.5)
	collider.shape.height=lerpf(standing_height,crouched_height,amount)
	collider.position.y=collider.shape.height*.5
	if origin!=null:
		origin.position=origin_start-Vector3.UP*maxf(0.0,camera_y-.42)*amount
	else:camera.position.y=lerpf(camera_y,.42,amount)
	frame.global_position=body.global_position+Vector3.UP*.12
	if avatar!=null:avatar.couch_rest_amount=amount
	if left!=null:
		left.global_position=camera.global_position-camera.global_basis.z*.3-camera.global_basis.x*.22-Vector3.UP*.15
		right.global_position=camera.global_position-camera.global_basis.z*.3+camera.global_basis.x*.22-Vector3.UP*.15
	if recovering and amount<=0.0:finish(body)
	# A river landing yields to swimming instead of trapping the player underwater.
	if elapsed>8.0 and not body.is_on_floor():finish(body)
	return true

func _stand_clear(body: CharacterBody3D) -> bool:
	var shape:=CapsuleShape3D.new();shape.radius=collider.shape.radius;shape.height=standing_height
	var query:=PhysicsShapeQueryParameters3D.new();query.shape=shape;query.collision_mask=body.collision_mask
	query.exclude=[body.get_rid()];query.margin=.001
	query.transform=body.global_transform*Transform3D(Basis.IDENTITY,collider_start+Vector3.UP*.02)
	return body.get_world_3d().direct_space_state.intersect_shape(query,1).is_empty()

func finish(body: CharacterBody3D) -> void:
	if not active:return
	active=false;body.remove_meta("knocked_down")
	collider.shape.height=standing_height;collider.position=collider_start
	if origin!=null:origin.position=origin_start
	else:camera.position.y=camera_y
	if is_instance_valid(avatar):
		avatar.couch_rest_frame=null;avatar.couch_rest_amount=0.0
		if temporary_avatar:avatar.queue_free()
	if is_instance_valid(frame):frame.queue_free()
	frame=null;avatar=null;left=null;right=null;temporary_avatar=false
