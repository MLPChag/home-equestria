extends Node3D
## A reclined player's existing torso volume supports a partner's weight.
## Created only for a real bed guest; no idle-world polling or tracked-pose writes.
const RADIUS := .16
var player: Node3D
var mare: CharacterBody3D
var avatar: Node3D
var body: StaticBody3D
var collider: CollisionShape3D
var capsule: CapsuleShape3D
var _scan := 0.0

func bind(who: Node3D, guest: CharacterBody3D) -> bool:
	player=who;mare=guest
	avatar=player.find_child("CouchAnonBody",true,false)
	if avatar==null:avatar=player.find_child("AnonBody",true,false)
	if avatar==null or avatar.get("_hip_target")==null or avatar.get("_head_target")==null:return false
	body=StaticBody3D.new();body.name="Torso";body.collision_mask=0
	capsule=CapsuleShape3D.new();capsule.radius=RADIUS
	collider=CollisionShape3D.new();collider.shape=capsule;body.add_child(collider);add_child(body)
	if player is PhysicsBody3D:body.add_collision_exception_with(player)
	set_meta("soft_support",true);set_meta("shared_rest_support",true)
	return refresh()

func refresh() -> bool:
	if not is_instance_valid(player) or not is_instance_valid(avatar) or not is_instance_valid(mare):return false
	if not player.get_meta("couch_sleeping",false):return false
	var hip:Vector3=avatar._hip_target.global_position
	var head:Vector3=avatar._head_target.global_position
	if not hip.is_finite() or not head.is_finite():return false
	var shoulder:=hip.lerp(head,.8)
	var length:=hip.distance_to(shoulder)
	if length<.15 or length>1.2:return false
	var center:Vector3=(hip+shoulder)*.5
	var basis:=Basis(Quaternion(Vector3.UP,(shoulder-hip).normalized()))
	var height:=length+RADIUS*2
	if not global_position.is_equal_approx(center):global_position=center
	if not collider.global_basis.is_equal_approx(basis):collider.global_basis=basis
	if not is_equal_approx(capsule.height,height):capsule.height=height
	return true

func _physics_process(delta:float)->void:
	_scan-=delta
	if _scan>0:return
	_scan=.05
	if not refresh():
		# The mattress catches her when the player leaves; never retain a floating
		# collider or move a tracked body back under a departing partner.
		if is_instance_valid(body):body.collision_layer=0
		set_physics_process(false)

func landing_height() -> float:
	return global_position.y+capsule.height*.5+.02
