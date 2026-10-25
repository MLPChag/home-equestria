extends SkeletonModifier3D
## Shared head width, filly neck and wings. Runs after the locomotion/posture modifiers;
## the neck link carries the posed motion onto the original OpenPony head, face and mane.
## Overall size is body_scale; thicker legs are baked into body_shapes/filly.scn.

@export var neck_scale := 0.9
## Cancel inherited neck shrink on the head bone. The intact head is enlarged as a node frame,
## and the body neck loft is fitted offline; do not scale this bone to enlarge the face.
@export var head_scale := 1.0
## Narrow the posed head along the model-rest X axis, leaving its pivot and source rig intact.
@export var head_width := 1.0
## Folded wings (identity.wing_scale; Scootaloo's are comically small).
@export var wing_scale := 1.0
var _neck := -1
var _head := -1
var _local_width_basis := Basis.IDENTITY
var _wings: PackedInt32Array = []

func _ready() -> void:
	var sk := get_skeleton()
	if sk == null: return
	_neck = sk.find_bone("pony_neck1")
	_head = sk.find_bone("pony_head")
	if _head >= 0:
		var rest_basis := sk.get_bone_global_rest(_head).basis.orthonormalized()
		_local_width_basis = rest_basis.inverse() * Basis.from_scale(Vector3(head_width, 1.0, 1.0)) * rest_basis
	for wing in ["pony_foldedWing_L", "pony_foldedWing_R"]:
		if sk.find_bone(wing) >= 0: _wings.append(sk.find_bone(wing))

func _process_modification() -> void:
	var sk := get_skeleton()
	if sk == null or _neck < 0 or _head < 0: return
	# Scale propagates down the chain: the head's own factor divides out the neck's.
	if not is_equal_approx(neck_scale, 1.0):
		sk.set_bone_pose_scale(_neck, sk.get_bone_pose_scale(_neck) * neck_scale)
	var head_factor := head_scale / neck_scale
	if not is_equal_approx(head_factor, 1.0):
		sk.set_bone_pose_scale(_head, sk.get_bone_pose_scale(_head) * head_factor)
	if not is_equal_approx(head_width, 1.0):
		# Conjugate model-rest X into the head frame; keep all existing posed scale.
		var posed_head := sk.get_bone_global_pose(_head)
		posed_head.basis = posed_head.basis * _local_width_basis
		sk.set_bone_global_pose(_head, posed_head)
	if not is_equal_approx(wing_scale, 1.0):
		for wing in _wings: sk.set_bone_pose_scale(wing, sk.get_bone_pose_scale(wing) * wing_scale)
