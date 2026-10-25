extends SkeletonModifier3D
## Turns Spike's neck and head toward what he is looking at, after the body clip has posed them.
## The turn is shared 35 % neck / 65 % head, limited to 70 degrees either side and 35 up or down,
## and eases so a new target is a glance, not a snap. `target` is a world point (INF = no look).

var target := Vector3.INF
var weight := 0.0
## Blend toward the target this many times per second (exponential).
var ease_rate := 6.0
var _neck := -1
var _head := -1
var _yaw := 0.0
var _pitch := 0.0
const YAW_LIMIT := deg_to_rad(70.0)
const PITCH_LIMIT := deg_to_rad(35.0)
## The actor whose -Z is "ahead" (set by spike.gd).
var body: Node3D

func _ready() -> void:
	var sk := get_skeleton()
	if sk == null: return
	_neck = sk.find_bone("Neck")
	if _neck < 0: _neck = sk.find_bone("Spine2")   # the VN-VJ rig has no neck bone
	_head = sk.find_bone("Head")

func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or _head < 0 or _neck < 0: return
	var wanted_yaw := 0.0
	var wanted_pitch := 0.0
	var head_global: Transform3D = sk.global_transform * sk.get_bone_global_pose(_head)
	if body == null: return
	var body_forward := body.global_basis.orthonormalized() * Vector3(0, 0, -1)
	var body_up := Vector3.UP
	if target.is_finite() and weight > 0.0:
		var to := target - head_global.origin
		if to.length() > 0.05:
			var flat := Vector3(to.x, 0, to.z)
			var fwd := Vector3(body_forward.x, 0, body_forward.z).normalized()
			if flat.length() > 0.01 and fwd.length() > 0.01:
				wanted_yaw = clampf(fwd.signed_angle_to(flat.normalized(), body_up), -YAW_LIMIT, YAW_LIMIT)
			wanted_pitch = clampf(atan2(to.y, flat.length()), -PITCH_LIMIT, PITCH_LIMIT)
	var k := 1.0 - exp(-ease_rate * delta)
	_yaw = lerpf(_yaw, wanted_yaw * weight, k)
	_pitch = lerpf(_pitch, wanted_pitch * weight, k)
	if absf(_yaw) < 0.0005 and absf(_pitch) < 0.0005: return
	_turn(sk, _neck, 0.35)
	_turn(sk, _head, 0.65)

## Rotates one bone by its share of the look, about world up (yaw) then the body's side (pitch).
func _turn(sk: Skeleton3D, bone: int, share: float) -> void:
	var parent := sk.get_bone_parent(bone)
	var parent_global: Transform3D = sk.get_bone_global_pose(parent) if parent >= 0 else Transform3D.IDENTITY
	var pose: Transform3D = sk.get_bone_global_pose(bone)
	var skel_basis := sk.global_basis.orthonormalized()
	var side_world := body.global_basis.orthonormalized() * Vector3.RIGHT
	var up_local := (skel_basis.inverse() * Vector3.UP).normalized()
	var side_local := (skel_basis.inverse() * side_world).normalized()
	# Positive pitch looks up: rotate about the body's side axis so the face rises.
	var turn := Basis(up_local, _yaw * share) * Basis(side_local, _pitch * share)
	var rotated := Transform3D(turn * pose.basis, pose.origin)
	var local: Transform3D = parent_global.affine_inverse() * rotated
	sk.set_bone_pose_rotation(bone, local.basis.get_rotation_quaternion())
