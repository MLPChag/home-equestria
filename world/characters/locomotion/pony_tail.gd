extends RefCounted
## Rest-relative tail springs. Authored curvature supplies the drape; forces add
## bounded follow-through. Only the five tail bones' rotations are changed.

const NAMES := ["pony_tail_01", "pony_tail_02", "pony_tail_03", "pony_tail_04", "pony_tail_05"]
const MAX_STEP := 1.0 / 120.0
const MAX_DELTA := 0.25
const ANGLE_LIMITS := [0.13962634, 0.17453293, 0.20943951, 0.24434610, 0.24434610]
const MAX_ANGULAR_SPEED := 2.8
const MAX_ANGULAR_ACCELERATION := 70.0
const MAX_ROOT_ACCELERATION := 18.0
const GRAVITY := Vector3(0.0, -9.8, 0.0)

var pony: Node3D
var skeleton: Skeleton3D
## Optional native chain configuration; historical five-bone defaults remain.
var bone_names: Array = NAMES.duplicate()
var mount_name := "MOUNT_TAIL"
var angle_limits: Array = ANGLE_LIMITS.duplicate()
var bones: Array[int] = []
var angles: Array[Vector3] = []
var angular_velocity: Array[Vector3] = []
## Optional world-space capsule proxies: {a: Vector3, b: Vector3, radius: float}.
## The caller owns their placement; the tail never guesses the body's volume.
var body_capsules: Array[Dictionary] = []
## A floor query returns {position: Vector3, normal: Vector3}, or {} for no floor.
## bind uses the pony's normal terrain probe when available.
var floor_probe := Callable()
var collision_enabled := true
var gravity_amount := 0.12
var inertia_amount := 0.75
var radius_root := 0.065
var radius_tip := 0.025
var segment_radii := PackedFloat32Array([0.04, 0.055, 0.065, 0.05, 0.025])
## Skeleton3D does not store a bone's terminal endpoint. Zero estimates the
## last segment from its predecessor; an exporter measurement can override it.
var terminal_length := 0.10404
## Contact response is bounded like every other force. Residual overlap can
## remain when the root is too low or the joint limits cannot reach clearance.
var max_penetration := 0.0
var contacts := 0

var _mount := -1
var _base_pose: Array[Transform3D] = []
var _rest_bases: Array[Basis] = []
var _tips: Array[Vector3] = []
var _floor_planes: Array[Dictionary] = []
var _previous_mount_basis := Basis.IDENTITY
var _previous_mount_velocity := Vector3.ZERO
var _mount_history := false


func bind(owner_pony: Node3D, supplied_skeleton: Skeleton3D = null) -> void:
	pony = owner_pony
	skeleton = supplied_skeleton if supplied_skeleton != null else pony.get("skeleton") as Skeleton3D
	bones.clear()
	_base_pose.clear()
	_rest_bases.clear()
	_tips.clear()
	_floor_planes.clear()
	_mount = -1
	if skeleton == null:
		reset()
		return
	_mount = skeleton.find_bone(mount_name)
	var parent := _mount
	for name in bone_names:
		var bone := skeleton.find_bone(name)
		# An older asset without this complete chain remains unchanged.
		if parent < 0 or bone < 0 or skeleton.get_bone_parent(bone) != parent:
			bones.clear()
			_base_pose.clear()
			_rest_bases.clear()
			reset()
			return
		bones.append(bone)
		var rest := skeleton.get_bone_rest(bone)
		_base_pose.append(rest)
		_rest_bases.append(rest.basis.orthonormalized())
		parent = bone
	for i in bones.size():
		# Child origins, rather than an assumed authoring axis, define length.
		var end_length := terminal_length if terminal_length > 0.0 else (_tips[i - 1].length() * 0.7 if i > 0 else 0.1)
		var tip := _base_pose[i + 1].origin if i + 1 < bones.size() else Vector3.UP * end_length
		_tips.append(tip)
		_floor_planes.append({})
	if pony.has_method("_probe"):
		floor_probe = Callable(pony, "_probe")
	reset()


func reset() -> void:
	angles.resize(bones.size())
	angular_velocity.resize(bones.size())
	angles.fill(Vector3.ZERO)
	angular_velocity.fill(Vector3.ZERO)
	_floor_planes.fill({})
	_previous_mount_velocity = Vector3.ZERO
	_mount_history = false
	max_penetration = 0.0
	contacts = 0


func update(delta: float, world_acceleration: Vector3) -> void:
	if bones.is_empty() or delta <= 0.0 or not is_finite(delta):
		return
	# Long pauses do not produce hundreds of catch-up iterations or turn into
	# an impulse. Ordinary 100 ms hitches still integrate their full duration.
	var elapsed := minf(delta, MAX_DELTA)
	var mount_frame := skeleton.global_transform * skeleton.get_bone_global_pose(_mount)
	var mount_basis := mount_frame.basis.orthonormalized()
	var mount_acceleration := Vector3.ZERO
	if _mount_history and delta <= MAX_DELTA:
		var change := (mount_basis * _previous_mount_basis.inverse()).get_rotation_quaternion().normalized()
		if change.w < 0.0:
			change = -change
		var mount_velocity := _rotation_vector(change) / delta
		mount_velocity = mount_velocity.limit_length(6.0)
		mount_acceleration = ((mount_velocity - _previous_mount_velocity) / delta).limit_length(25.0)
		_previous_mount_velocity = mount_velocity
	else:
		_previous_mount_velocity = Vector3.ZERO
	_previous_mount_basis = mount_basis
	_mount_history = true
	var acceleration := world_acceleration.limit_length(MAX_ROOT_ACCELERATION) if world_acceleration.is_finite() else Vector3.ZERO
	var steps := maxi(1, ceili(elapsed / MAX_STEP))
	var dt := elapsed / steps
	for step in steps:
		var frames := _frames(mount_frame)
		var contact_forces := _contact_forces(frames)
		for i in bones.size():
			var progress := float(i) / float(bones.size() - 1)
			var frame := frames[i].basis.orthonormalized()
			var inverse_frame:=frame.inverse()
			var direction := _tips[i].normalized()
			var local_force := inverse_frame * (GRAVITY * gravity_amount - acceleration * inertia_amount)
			var force := direction.cross(local_force) * lerpf(0.35, 0.8, progress)
			# Turning the rump also leaves the tail behind, including while held.
			force -= inverse_frame * mount_acceleration * lerpf(0.18, 0.35, progress)
			force += contact_forces[i]
			# No twist about the longitudinal axis; all motion is joint swing.
			force -= direction * force.dot(direction)
			var stiffness := lerpf(42.0, 23.0, progress)
			var damping := lerpf(10.0, 7.0, progress)
			var angular_acceleration := (force - angles[i] * stiffness - angular_velocity[i] * damping).limit_length(MAX_ANGULAR_ACCELERATION)
			angular_velocity[i] = (angular_velocity[i] + angular_acceleration * dt).limit_length(MAX_ANGULAR_SPEED)
			angles[i] += angular_velocity[i] * dt
			var limit: float = angle_limits[mini(i, angle_limits.size()-1)]
			if angles[i].length() > limit:
				angles[i] = angles[i].limit_length(limit)
				var outward := angles[i].normalized()
				angular_velocity[i] -= outward * maxf(0.0, angular_velocity[i].dot(outward))


func apply_pose(pose: Array[Transform3D]) -> void:
	if bones.is_empty():
		return
	for bone in bones:
		if bone >= pose.size():
			return
	for i in bones.size():
		var bone := bones[i]
		_base_pose[i] = pose[bone]
		# Left multiplication by a rotation preserves each basis column's length,
		# including existing nonuniform scale. Never overwrite origins or scale.
		var rest := _rest_bases[i]
		var rotation := _angle_basis(angles[i])
		pose[bone].basis = rest * rotation * rest.inverse() * pose[bone].basis
	var mount_frame := skeleton.global_transform * _pose_global(_mount, pose)
	var frames := _frames(mount_frame)
	for i in bones.size():
		_floor_planes[i] = {}
		if collision_enabled and floor_probe.is_valid():
			var hit: Dictionary = floor_probe.call(frames[i] * _tips[i])
			if hit.has("position") and hit.has("normal") and Vector3(hit.normal).is_finite() and Vector3(hit.normal).length_squared() > 0.5:
				_floor_planes[i] = hit
	_contact_forces(frames)


func _frames(mount_frame: Transform3D) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	var parent := mount_frame
	for i in bones.size():
		var local := _base_pose[i]
		var rest := _rest_bases[i]
		local.basis = rest * _angle_basis(angles[i]) * rest.inverse() * local.basis
		parent = parent * local
		result.append(parent)
	return result


func _contact_forces(frames: Array[Transform3D]) -> Array[Vector3]:
	var result: Array[Vector3] = []
	result.resize(bones.size())
	result.fill(Vector3.ZERO)
	max_penetration = 0.0
	contacts = 0
	if not collision_enabled:
		return result
	for i in bones.size():
		var radius := segment_radii[i] if i < segment_radii.size() else lerpf(radius_root, radius_tip, float(i) / float(bones.size() - 1))
		for fraction in [0.5, 1.0]:
			var point: Vector3 = frames[i] * (_tips[i] * fraction)
			var overlaps: Array[Dictionary] = []
			var plane := _floor_planes[i]
			if not plane.is_empty():
				var normal := Vector3(plane.normal).normalized()
				var depth := radius - (point - Vector3(plane.position)).dot(normal)
				if depth > 0.0:
					overlaps.append({"normal": normal, "depth": depth})
			for capsule in body_capsules:
				var a := Vector3(capsule.a)
				var ab := Vector3(capsule.b) - a
				var center := a + ab * clampf((point - a).dot(ab) / maxf(ab.length_squared(), 0.000001), 0.0, 1.0)
				var outward := point - center
				var depth := radius + float(capsule.radius) - outward.length()
				if depth > 0.0:
					# At the capsule axis use the authored tail direction as an exit.
					var normal := outward.normalized() if outward.length_squared() > 0.000001 else (frames[i].basis * _tips[i]).normalized()
					overlaps.append({"normal": normal, "depth": depth})
			for overlap in overlaps:
				contacts += 1
				max_penetration = maxf(max_penetration, float(overlap.depth))
				var normal := Vector3(overlap.normal)
				var point_velocity := Vector3.ZERO
				for j in i + 1:
					point_velocity += (frames[j].basis.orthonormalized() * angular_velocity[j]).cross(point - frames[j].origin)
				var push := maxf(0.0, float(overlap.depth) * 1200.0 - point_velocity.dot(normal) * 55.0)
				for j in i + 1:
					var lever := point - frames[j].origin
					var torque := lever.cross(normal * push) / maxf(lever.length_squared(), 0.015)
					result[j] += (frames[j].basis.orthonormalized().inverse() * torque).limit_length(40.0) / float(i + 1)
	return result


func _pose_global(bone: int, pose: Array[Transform3D]) -> Transform3D:
	var frame := pose[bone]
	var parent := skeleton.get_bone_parent(bone)
	while parent >= 0:
		frame = pose[parent] * frame
		parent = skeleton.get_bone_parent(parent)
	return frame


func _angle_basis(value: Vector3) -> Basis:
	var angle := value.length()
	return Basis(value / angle, angle) if angle > 0.000001 else Basis.IDENTITY


func _rotation_vector(value: Quaternion) -> Vector3:
	var sine := Vector3(value.x, value.y, value.z).length()
	return Vector3(value.x, value.y, value.z) * (2.0 * atan2(sine, value.w) / sine) if sine > 0.000001 else Vector3.ZERO
