extends RefCounted
## Absolute, rest-relative joint limits in the native rig's measured bend frames.
## Authored motion calibrates hinges; these are rig limits, not veterinary data.

const SOLVER := preload("res://world/characters/locomotion/limb_solver.gd")
const LIMBS := ["flank", "femur", "tibia", "legLower", "tarsal", "hoof",
	"shoulder", "upperArm", "lowerArm", "wrist", "hand", "finger"]
var joints: Dictionary = {}
var names: Dictionary = {}
## PonySolverNative (native/pony_solver) holding these limits, or null: apply() then runs in C++.
var _native: RefCounted


## Hands the bound limits to the native solver, in this dictionary's order.
func bind_native(native: RefCounted) -> void:
	var indices := PackedInt32Array()
	var data := PackedFloat64Array()
	for index: int in joints:
		var joint: Dictionary = joints[index]
		indices.append(index)
		for b: Basis in [joint.parent, joint.rest]:
			data.append_array([b.x.x, b.y.x, b.z.x, b.x.y, b.y.y, b.z.y, b.x.z, b.y.z, b.z.z])
		var axis: Vector3 = joint.axis
		data.append_array([axis.x, axis.y, axis.z, joint.lower, joint.upper, joint.swing])
	native.bind_limits(indices, data)
	_native = native


func bind(profile: Resource, skeleton: Skeleton3D) -> void:
	joints.clear()
	names.clear()
	var fk := SOLVER.forward_kinematics(profile.parents, profile.rest)
	var poses: Array = profile.calibration_samples() if profile.has_method("calibration_samples") else profile.samples
	for index in profile.parents.size():
		var name := skeleton.get_bone_name(index)
		var part := name.trim_prefix("pony_").trim_suffix("_L").trim_suffix("_R")
		if part not in LIMBS and part not in ["spine1", "spine2", "spine3", "neck1", "neck2", "head"]:
			continue
		var parent := Basis.IDENTITY if profile.parents[index] < 0 else fk[profile.parents[index]].basis.orthonormalized()
		var rest: Basis = profile.rest[index].basis.orthonormalized()
		var axis := Vector3.RIGHT
		var largest := 0.0
		# The local bone axes are not the anatomical hinge axes. Recover the
		# dominant bend from the authored rotations in model rest space.
		for pose in poses:
			var q: Quaternion = (parent * pose[index].basis * rest.inverse() * parent.inverse()).orthonormalized().get_rotation_quaternion()
			if q.get_angle() > largest:
				largest = q.get_angle()
				axis = q.get_axis()
		if largest < deg_to_rad(2.0):
			axis = Vector3.RIGHT
		if axis.x < 0.0:
			axis = -axis
		var lower := 0.0
		var upper := 0.0
		var swing := 0.0
		for pose in poses:
			var q: Quaternion = (parent * pose[index].basis * rest.inverse() * parent.inverse()).orthonormalized().get_rotation_quaternion()
			var split := _split(q, axis)
			lower = minf(lower, split.angle)
			upper = maxf(upper, split.angle)
			swing = maxf(swing, Quaternion(split.swing).get_angle())
		lower -= deg_to_rad(5.0)
		upper += deg_to_rad(5.0)
		swing += deg_to_rad(3.0)
		if part in ["shoulder", "flank", "upperArm", "femur"]:
			lower = minf(lower, deg_to_rad(-45.0 if part in ["femur", "upperArm"] else -28.0))
			upper = maxf(upper, deg_to_rad(35.0))
			swing = maxf(swing, deg_to_rad(18.0))
		elif part.begins_with("spine"):
			# Fixed IK/secondary-motion bounds, opened only as far as the native clips
			# themselves bend the back (the gallop flexes the spine about 27 degrees).
			lower = minf(lower, deg_to_rad(-8.0))
			upper = maxf(upper, deg_to_rad(8.0))
			swing = maxf(swing, deg_to_rad(6.0))
		elif part.begins_with("neck") or part == "head":
			lower = minf(lower, deg_to_rad(-30.0))
			upper = maxf(upper, deg_to_rad(30.0))
			swing = maxf(swing, deg_to_rad(28.0))
		joints[index] = {"name": name, "parent": parent, "rest": rest,
			"axis": axis, "lower": lower, "upper": upper, "swing": swing}
		names[name] = index


func constrain(index: int, basis: Basis) -> Basis:
	if not joints.has(index):
		return basis
	var joint: Dictionary = joints[index]
	var parent: Basis = joint.parent
	var rotation := (parent * basis.orthonormalized() * Basis(joint.rest).inverse() * parent.inverse()).get_rotation_quaternion()
	var split := _split(rotation, joint.axis)
	if split.angle >= joint.lower and split.angle <= joint.upper and Quaternion(split.swing).get_angle() <= joint.swing:
		return basis
	var bend := clampf(split.angle, joint.lower, joint.upper)
	var swing: Quaternion = split.swing
	var angle := swing.get_angle()
	if angle > joint.swing:
		swing = Quaternion.IDENTITY.slerp(swing, joint.swing / angle)
	var clamped := Basis(swing * Quaternion(joint.axis, bend))
	return (parent.inverse() * clamped * parent * Basis(joint.rest)).scaled_local(basis.get_scale())


## Bone name -> radians clamped by the last apply(); diagnostics for the gait probes.
var last_clamped: Dictionary = {}


func apply(pose: Array[Transform3D]) -> float:
	var maximum := 0.0
	last_clamped.clear()
	if _native != null:
		return apply_angles(_native.apply_limits(pose))
	for index: int in joints:
		var before := pose[index].basis.orthonormalized().get_rotation_quaternion()
		pose[index].basis = constrain(index, pose[index].basis)
		var angle := before.angle_to(pose[index].basis.orthonormalized().get_rotation_quaternion())
		if angle > 0.001:
			last_clamped[joints[index].name] = angle
		maximum = maxf(maximum, angle)
	return maximum


## apply() from the angles PonySolverNative moved each bound joint (joint order): fills
## last_clamped and returns the largest.
func apply_angles(angles: PackedFloat64Array) -> float:
	var maximum := 0.0
	last_clamped.clear()
	var i := 0
	for index: int in joints:
		var moved := angles[i]
		i += 1
		if moved > 0.001:
			last_clamped[joints[index].name] = moved
		maximum = maxf(maximum, moved)
	return maximum


func pose_basis(name: String, model_rotation: Vector3) -> Basis:
	var joint: Dictionary = joints[names[name]]
	var parent: Basis = joint.parent
	return constrain(names[name], parent.inverse() * Basis.from_euler(model_rotation) * parent * Basis(joint.rest))


static func _split(rotation: Quaternion, axis: Vector3) -> Dictionary:
	if rotation.w < 0.0:
		rotation = -rotation
	var vector := Vector3(rotation.x, rotation.y, rotation.z)
	var projection := axis * vector.dot(axis)
	var twist := Quaternion(projection.x, projection.y, projection.z, rotation.w)
	if twist.length_squared() < 1e-10:
		twist = Quaternion.IDENTITY
	else:
		twist = twist.normalized()
	var angle := wrapf(2.0 * atan2(Vector3(twist.x, twist.y, twist.z).dot(axis), twist.w), -PI, PI)
	return {"angle": angle, "swing": (rotation * twist.inverse()).normalized()}
