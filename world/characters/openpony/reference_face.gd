extends SkeletonModifier3D
## The Blender fit preserves the animation rig. Conjugate facial motion into the
## new eye/muzzle frames; matching inverse binds are baked with the shaped meshes.
## HEAD/neck/scalp keep the original frame, including the shared neck boundary.
var frames: Dictionary = {}
var _head := -1
var _rest_inverse := Transform3D.IDENTITY

func bind(model: Node, skeleton: Skeleton3D) -> void:
	frames = model.get_meta("reference_face_frames", {})
	_head = skeleton.find_bone("mHead")
	_rest_inverse = skeleton.get_bone_global_rest(_head).affine_inverse()

func remap_snapshot(poses: Array[Transform3D]) -> Array[Transform3D]:
	var result: Array[Transform3D] = poses.duplicate()
	var motion: Transform3D = poses[_head] * _rest_inverse
	var inverse := motion.affine_inverse()
	for b: int in frames:
		result[b] = motion * (frames[b] as Transform3D) * inverse * poses[b]
	return result

func _process_modification() -> void:
	if frames.is_empty(): return
	var sk := get_skeleton()
	var motion := sk.get_bone_global_pose(_head) * _rest_inverse
	var inverse := motion.affine_inverse()
	var transformed: Dictionary = {}
	# Snapshot first: writing a parent changes its children's globals.
	for b: int in frames:
		transformed[b] = motion * (frames[b] as Transform3D) * inverse * sk.get_bone_global_pose(b)
	for b: int in transformed: sk.set_bone_global_pose(b, transformed[b])
