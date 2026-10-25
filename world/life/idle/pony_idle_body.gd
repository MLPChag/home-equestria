extends SkeletonModifier3D
## Standing body life on the NEAR clip tier (dev 2026-10-14: "her head moves i guess but not her
## body"). The NEAR tier plays the baked stand, one frozen pose, and ClipHead only brings the neck
## and head to life; this layers the rest of what HERO's solver shows on top of that pose:
## - breath: the loins lift the back a hair and the withers level it again
##   (pony_secondary_motion.gd apply_pose(), same bones, same amount);
## - weight: her barrel rolls onto the side she settles on and tips a little back or forward,
##   following the secondary's standing weight shifts (pony_secondary_motion.gd shift_weight()).
##   The four leg roots (flanks, shoulders) turn back by the same amount, so the legs keep hanging
##   as the clip posed them and the hooves stay where they stood (a few millimetres at most).
## Rotations only, every bone through pony_joint_limits. The secondary's values come on the 20 Hz
## logic beat and are eased here every step. hybrid_mare.gd switches it on only while the stand
## clip plays in NEAR within 15 m of the player, with no posture, hold, carry or kiss on her, and
## fades it out before switching it off. Placed right after ClipHead.
const PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under --profile-cpu / the benches
const SECONDARY := preload("res://world/characters/locomotion/pony_secondary_motion.gd")
const LEG_ROOTS := ["pony_flank_L", "pony_flank_R", "pony_shoulder_L", "pony_shoulder_R"]
## Pitch (radians) per metre of the secondary's back/forward weight offset.
const PITCH_PER_METRE := 0.8
const FADE_SECONDS := 0.6

var pony: Node
## Set by hybrid_mare.gd on the face beat; the layer eases in and out by `fade`.
var wanted := false
var fade := 0.0
var _hips := -1
var _hips_parent := -1
var _legs: Array[int] = []
var _leg_parents: Array[int] = []
var _model_to_skeleton := Basis.IDENTITY
var _frame_ready := false
var _roll := 0.0
var _pitch := 0.0
var _breath := 0.0
## Largest roll applied (radians) since the last read; tests and traces.
var applied_roll := 0.0


func bind(skeleton: Skeleton3D) -> void:
	_legs.clear()
	_leg_parents.clear()
	_hips = skeleton.find_bone("pony_hips")
	_hips_parent = skeleton.get_bone_parent(_hips) if _hips >= 0 else -1
	for name: String in LEG_ROOTS:
		var bone := skeleton.find_bone(name)
		if bone < 0 or skeleton.get_bone_parent(bone) < 0:
			_hips = -1
			return
		_legs.append(bone)
		_leg_parents.append(skeleton.get_bone_parent(bone))


func _process_modification_with_delta(delta: float) -> void:
	fade = move_toward(fade, 1.0 if wanted else 0.0, delta / FADE_SECONDS)
	if fade <= 0.0 or _hips < 0 or not is_instance_valid(pony): return
	var started := Time.get_ticks_usec() if PROFILE.enabled else 0
	_apply(delta)
	if PROFILE.enabled: PROFILE.record("idle_body", started)


func _apply(delta: float) -> void:
	var skeleton := get_skeleton()
	var secondary: RefCounted = pony.secondary
	var limits: RefCounted = pony.joint_limits
	if skeleton == null or secondary == null or limits == null: return
	if not _frame_ready:
		var pivot: Node3D = pony.pivot
		if pivot == null or not pivot.is_inside_tree(): return
		# Model frame (the pivot: forward -Z, up +Y) to skeleton space, rotation only.
		_model_to_skeleton = (pivot.global_basis.orthonormalized().inverse() * skeleton.global_basis.orthonormalized()).inverse()
		_frame_ready = true
	var ease := 1.0 - exp(-delta / 0.08)
	var offset: Vector3 = secondary.offset
	_roll = lerpf(_roll, float(secondary.roll), ease)
	_pitch = lerpf(_pitch, offset.z * PITCH_PER_METRE, ease)
	_breath = lerpf(_breath, float(secondary.breath), ease)
	applied_roll = maxf(applied_roll, absf(_roll * fade))
	# The legs' orientation as the clip (and any earlier modifier) left it.
	var leg_globals: Array[Basis] = []
	for bone: int in _legs:
		leg_globals.append(skeleton.get_bone_global_pose(bone).basis)
	# Weight: roll and tip the whole body about the hips.
	var turn := _model_to_skeleton * Basis.from_euler(Vector3(_pitch, 0.0, _roll) * fade) * _model_to_skeleton.inverse()
	var parent := skeleton.get_bone_global_pose(_hips_parent).basis.orthonormalized() if _hips_parent >= 0 else Basis.IDENTITY
	var hips := skeleton.get_bone_pose(_hips)
	hips.basis = parent.inverse() * turn * parent * hips.basis
	skeleton.set_bone_pose(_hips, hips)
	# Breath along the back, as the solver tier's secondary applies it.
	var spine: Array[int] = secondary._spine
	var frames: Array[Basis] = secondary._spine_frames
	if spine.size() == 2 and absf(_breath) > 0.0005:
		for i in 2:
			var bone := spine[i]
			var frame := frames[i]
			var pitch: float = SECONDARY.BREATH_ARCH * _breath * fade * (1.0 if i == 0 else -1.0)
			var pose := skeleton.get_bone_pose(bone)
			pose.basis = limits.constrain(bone, frame.inverse() * Basis(Vector3.RIGHT, pitch) * frame * pose.basis)
			skeleton.set_bone_pose(bone, pose)
	# The legs hang as before: each root turns back under its moved parent.
	for i in _legs.size():
		var bone := _legs[i]
		var moved := skeleton.get_bone_global_pose(_leg_parents[i]).basis
		var pose := skeleton.get_bone_pose(bone)
		pose.basis = limits.constrain(bone, moved.inverse() * leg_globals[i])
		skeleton.set_bone_pose(bone, pose)
