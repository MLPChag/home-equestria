extends SkeletonModifier3D
## The controller prepares immutable local poses once per physics tick.

const CROWD_PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under the crowd lab's --profile-cpu
const NATIVE := preload("res://world/characters/locomotion/native_solver.gd")
var prepared: Array[Transform3D] = []
## PonySolverNative (docs/NATIVE_SOLVER_2026_09_25.md) writes the same poses; null keeps the loop.
var native: RefCounted
## Write only the bones whose value differs from what the skeleton holds at modifier time
## (PonySolverNative.write_bone_poses_skip). `-- --native-solver-skip bone_skip` writes all.
var bone_skip: bool = NATIVE.enabled("bone_skip")
## Bones written by the last skip pass (diagnostics).
var bones_written := 0
var _skip_skeleton: Skeleton3D


func _enter_tree() -> void:
	# The skeleton can be written unnoticed while out of the tree: re-read what it holds.
	if native != null:
		native.invalidate_bone_skip()


func _unprofiled_process_modification_with_delta(_delta: float) -> void:
	var skeleton := get_skeleton()
	if native != null:
		if bone_skip and influence >= 1.0 and _first_active_modifier(skeleton):
			if _skip_skeleton != skeleton:
				# Any write outside the modifier pass changes what the skeleton holds, and shows up
				# as pose_updated at the start of the next update, before this pass runs.
				_skip_skeleton = skeleton
				var invalidate := Callable(native, "invalidate_bone_skip")
				if not skeleton.pose_updated.is_connected(invalidate):
					skeleton.pose_updated.connect(invalidate)
				native.invalidate_bone_skip()
			bones_written = native.write_bone_poses_skip(skeleton, prepared)
		else:
			native.write_bone_poses(skeleton, prepared)
		return
	if prepared.size() != skeleton.get_bone_count():
		return
	for i in prepared.size():
		skeleton.set_bone_pose(i, prepared[i])


func _process_modification_with_delta(_delta: float) -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_process_modification_with_delta(_delta)
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("terrain_modifier", started)


## True when no active modifier runs before this one on the skeleton, so what the skeleton holds
## at this pass is its unmodified pose.
func _first_active_modifier(skeleton: Skeleton3D) -> bool:
	for i in get_index():
		var node := skeleton.get_child(i)
		if node is SkeletonModifier3D and (node as SkeletonModifier3D).active:
			return false
	return true
