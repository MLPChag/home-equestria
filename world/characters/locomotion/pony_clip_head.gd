extends SkeletonModifier3D
## Live head over the clip tiers' baked gaits (docs/CLIP_TIER_2026_09_25.md). The clips are baked
## with the secondary layer frozen, so here the pony's head, gaze and neck-gaze angles (updated at
## her 20 Hz logic tick) are interpolated between the last two logic ticks and layered onto the
## clip's neck and head bones every step, exactly as pony_secondary_motion.gd apply_pose() layers
## them over the solver's source pose, within the same joint limits. Active in NEAR only; placed
## right after the terrain modifier. Scaled in over the hand-off, whose clip already carries the
## solver's last head. In a posture it layers the gaze the way apply_rest_gaze() does over the
## posture's FK (no breath, 50° at most, no joint limits), faded out as a sleep pose takes over.
const PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under --profile-cpu / the benches

var pony: Node
## PonySolverNative (clip_head, face.cpp) when the extension is loaded; null keeps the loop below.
var native: RefCounted
var _bound := false


func _process_modification_with_delta(_delta: float) -> void:
	var started := Time.get_ticks_usec() if PROFILE.enabled else 0
	_apply()
	if PROFILE.enabled: PROFILE.record("clip_head", started)


func _apply() -> void:
	var secondary: RefCounted = pony.secondary
	var neck: Array[int] = secondary._neck
	if neck.is_empty():
		return
	var skeleton := get_skeleton()
	var t: float = pony.logic_alpha()
	var from: PackedVector3Array = pony.clip_head_from
	var to: PackedVector3Array = pony.clip_head_to
	var weight := smoothstep(0.0, 1.0, float(pony._clip_blend))
	var posture: RefCounted = pony.posture
	var rest: bool = posture != null and posture.active()
	if rest:
		weight *= 1.0 - smoothstep(0.0, 1.0, float(posture._sleep_blend))
		if weight <= 0.0:
			return
	var head := from[0].lerp(to[0], t) * weight
	var gaze := from[1].lerp(to[1], t) * weight
	var neck_gaze := from[2].lerp(to[2], t) * weight
	if native != null:
		if not _bound:
			native.bind_clip_head(PackedInt32Array(neck), secondary._parent_frames)
			_bound = true
		native.clip_head(skeleton, head, gaze, neck_gaze, rest)
		return
	var limits: RefCounted = pony.joint_limits
	for i in neck.size():
		var bone := neck[i]
		var parent: Basis = secondary._parent_frames[i]
		if rest:
			var look := (gaze - neck_gaze * .55 if i == 2 else neck_gaze * .275).limit_length(deg_to_rad(50))
			var posed := skeleton.get_bone_pose(bone)
			posed.basis = parent.inverse() * Basis.from_euler(look) * parent * posed.basis
			skeleton.set_bone_pose(bone, posed)
			continue
		var share := 0.3 if i == 2 else 0.35
		var angles := head * share + (gaze - neck_gaze * 0.55 if i == 2 else neck_gaze * 0.275)
		var pose := skeleton.get_bone_pose(bone)
		pose.basis = limits.constrain(bone, parent.inverse() * Basis.from_euler(angles) * parent * pose.basis)
		skeleton.set_bone_pose(bone, pose)
