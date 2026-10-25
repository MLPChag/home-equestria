extends RefCounted
## Compliant chest lift with finite hind-leg reach and damped head/limb motion.

const SOLVER := preload("res://world/characters/locomotion/limb_solver.gd")
const REST_FLEX := {"lowerArm": 15.0, "wrist": -15.0, "hand": -8.0, "finger": -4.0,
	"tibia": -5.0, "legLower": 15.0, "tarsal": -10.0, "hoof": -5.0}
var pony: CharacterBody3D
var active := false
var blend := 0.0
var pitch := 0.0
var pitch_velocity := 0.0
var swing := Vector2.ZERO
var swing_velocity := Vector2.ZERO
var head_angles := Vector3.ZERO
var head_velocity := Vector3.ZERO
## Eye rotation left after the neck has aimed, in model-forward coordinates.
var eye_angles := Vector3.ZERO
var initial_grip := Vector3.ZERO
var grip_name := "chest"
var look_target := Vector3.ZERO
var grips: Dictionary = {}
var supports: Array[bool] = [false, false, false, false]
var anchors: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var anchor_bases: Array[Basis] = [Basis.IDENTITY, Basis.IDENTITY, Basis.IDENTITY, Basis.IDENTITY]
var release_blends := [1.0, 1.0, 1.0, 1.0]
var release_poses: Array = [[], [], [], []]
var start_pose: Array[Transform3D] = []
var rejected_contacts := 0
var pivot_center := Vector3.ZERO
var start_pivot := Transform3D.IDENTITY
var grip_angles := Vector2.ZERO
var grip_angular_velocity := Vector2.ZERO
## Forelegs dangle loosely while she is carried (dev 2026-09-28: "they've been broken for a
## while"). The joint-limited standing pose hung them as stiff, pressed-together columns. After
## the joint limits, each upper arm turns its leg toward a point below and a little in front of
## her chest, slightly apart; carpus and fetlock fold softly; a damped spring swings them when
## she moves and settles them again.
const DANGLE_FORWARD := .35 # How far in front of her chest the hooves hang, per unit of drop.
const DANGLE_LAG := .015 # Leg swing per m/s² of her acceleration (the legs trail behind).
var _dangle_offset: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _dangle_velocity: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _dangle_origin := Vector3.INF
var _dangle_speed := Vector3.ZERO


func bind(owner_pony: CharacterBody3D) -> void:
	pony = owner_pony
	var bone: int = pony.skeleton.find_bone("pony_spine3")
	var rest: Transform3D = pony.skeleton.get_bone_global_rest(bone)
	pivot_center = (pony.skeleton.get_bone_global_rest(pony.skeleton.find_bone("pony_flank_L")).origin
		+ pony.skeleton.get_bone_global_rest(pony.skeleton.find_bone("pony_flank_R")).origin) * 0.5
	for name in ["chest", "left_chest", "right_chest"]:
		var x := -0.14 if name == "left_chest" else (0.14 if name == "right_chest" else 0.0)
		grips[name] = {"bone": bone, "offset": rest.affine_inverse() * Vector3(x, 0.56, -0.02)}


func grip_transform(name: String = "chest") -> Transform3D:
	var grip: Dictionary = grips.get(name, grips.chest)
	var frame: Transform3D = pony.skeleton.global_transform * pony.skeleton.get_bone_global_pose(grip.bone)
	return Transform3D(frame.basis.orthonormalized(), frame * Vector3(grip.offset))


func begin(name: String, target: Vector3) -> void:
	active = true
	grip_name = name if grips.has(name) else "chest"
	initial_grip = grip_transform(grip_name).origin
	look_target = target
	start_pose = pony.corrected_pose.duplicate() if not pony.corrected_pose.is_empty() else pony.profile.rest.duplicate()
	start_pivot = pony.pivot.transform
	blend = 0.0
	pitch = 0.0
	pitch_velocity = 0.0
	swing = Vector2.ZERO
	swing_velocity = Vector2.ZERO
	grip_angles = Vector2.ZERO
	grip_angular_velocity = Vector2.ZERO
	rejected_contacts = 0
	# No hoof stays planted on the ground (dev 2026-09-28): anchored hind hooves held until the
	# lift outreached them, then the whole body snapped up at once. All four legs leave the
	# ground together and ease into the carry pose over the blend.
	for i in 4:
		supports[i] = false
		release_blends[i] = 1.0
		release_poses[i] = []


func end() -> void:
	active = false
	supports.fill(false)


func reset() -> void:
	end()
	blend = 0.0
	pitch = 0.0
	pitch_velocity = 0.0
	_dangle_offset = [Vector3.ZERO, Vector3.ZERO]; _dangle_velocity = [Vector3.ZERO, Vector3.ZERO]; _dangle_origin = Vector3.INF
	head_angles = Vector3.ZERO
	head_velocity = Vector3.ZERO
	eye_angles = Vector3.ZERO
	swing = Vector2.ZERO
	swing_velocity = Vector2.ZERO
	grip_angles = Vector2.ZERO
	grip_angular_velocity = Vector2.ZERO


func update(delta: float, world_acceleration: Vector3, grip_target: Vector3) -> void:
	blend = move_toward(blend, 1.0 if active else 0.0, delta / 0.35)
	var lift := maxf(0.0, grip_target.y - initial_grip.y)
	var want_pitch := asin(clampf(lift / 0.22, 0.0, sin(deg_to_rad(48.0)))) if active else 0.0
	var acceleration := pony.global_basis.orthonormalized().inverse() * world_acceleration.limit_length(12.0)
	var want_angles := Vector2.ZERO
	if active and pony._hand_targets.size() == 2:
		var span: Vector3 = pony.global_basis.orthonormalized().inverse() * (Vector3(pony._hand_targets.right_chest) - Vector3(pony._hand_targets.left_chest))
		want_angles.x = clampf(atan2(-span.z, span.x), deg_to_rad(-25.0), deg_to_rad(25.0))
		want_angles.y = clampf(atan2(span.y, Vector2(span.x, span.z).length()), deg_to_rad(-12.0), deg_to_rad(12.0))
	elif active:
		want_angles.y = deg_to_rad(-8.0 if grip_name == "left_chest" else (8.0 if grip_name == "right_chest" else 0.0))
	var steps := maxi(1, ceili(delta * 120.0))
	var dt := delta / steps
	for step in steps:
		grip_angular_velocity += ((want_angles - grip_angles) * 45.0 - grip_angular_velocity * 12.0) * dt
		grip_angles += grip_angular_velocity * dt
		pitch_velocity += ((want_pitch - pitch) * 45.0 - pitch_velocity * 12.0) * dt
		pitch = clampf(pitch + pitch_velocity * dt, 0.0, deg_to_rad(48.0))
		var force := Vector2(acceleration.z, -acceleration.x) * 0.12
		swing_velocity += (force - swing * 24.0 - swing_velocity * 7.5) * dt
		swing += swing_velocity * dt
		if swing.length() > deg_to_rad(12.0):
			swing = swing.limit_length(deg_to_rad(12.0))
			swing_velocity *= 0.5
	for i in 4:
		release_blends[i] = move_toward(release_blends[i], 1.0, delta / 0.2)


func apply_pose(pose: Array[Transform3D], delta: float) -> void:
	if blend <= 0.0:
		return
	var limits = pony.joint_limits
	var target: Array[Transform3D] = pony.profile.standing.duplicate()
	var body_angles: Vector3 = pony.pivot.transform.basis.get_euler()
	# Distributed proximal motion lets the limbs hang toward gravity without
	# asking one shoulder or hip joint to absorb the entire torso rotation.
	for side in ["L", "R"]:
		for part in ["shoulder", "flank", "upperArm", "femur"]:
			var name := "pony_%s_%s" % [part, side]
			var share := 0.42 if part in ["shoulder", "flank"] else 0.58
			if supports[2 if side == "L" else 3] and part in ["flank", "femur"]:
				share = 1.0 if part == "flank" else 0.0
			target[limits.names[name]].basis = limits.pose_basis(name, Vector3(-body_angles.x * share + swing.x * share, 0.0, -body_angles.z * share + swing.y * share))
		for part in REST_FLEX:
			if part in ["tibia", "legLower", "tarsal", "hoof"] and supports[2 if side == "L" else 3]:
				continue
			var name := "pony_%s_%s" % [part, side]
			target[limits.names[name]].basis = limits.pose_basis(name, Vector3(deg_to_rad(REST_FLEX[part]), 0.0, 0.0))
	for i in pose.size():
		pose[i] = (start_pose[i] if active and not start_pose.is_empty() else pose[i]).interpolate_with(target[i], blend)
	for leg_index in 4:
		if release_blends[leg_index] >= 1.0 or release_poses[leg_index].is_empty():
			continue
		var leg: Dictionary = pony.profile.legs[leg_index]
		for bone in leg.chain:
			pose[bone] = release_poses[leg_index][bone].interpolate_with(pose[bone], release_blends[leg_index])
	var frame: Transform3D = pony.global_transform * pony.pivot.transform * pony._model_frame
	var head: int = limits.names.pony_head
	var fk := SOLVER.forward_kinematics(pony.profile.parents, pose, frame)
	var direction := frame.basis.orthonormalized().inverse() * (look_target - fk[head].origin)
	var wanted := Vector3.ZERO
	if active and direction.length_squared() > 0.001:
		wanted = Vector3(clampf(atan2(direction.y, Vector2(direction.x, direction.z).length()), deg_to_rad(-65.0), deg_to_rad(65.0)),
			clampf(atan2(-direction.x, -direction.z), deg_to_rad(-70.0), deg_to_rad(70.0)), -body_angles.z * 0.6 + swing.y * 0.2)
	var steps := maxi(1, ceili(delta * 120.0))
	var dt := delta / steps
	for step in steps:
		var acceleration := ((wanted - head_angles) * 55.0 - head_velocity * 14.0).limit_length(deg_to_rad(360.0))
		head_velocity = (head_velocity + acceleration * dt).limit_length(deg_to_rad(80.0))
		head_angles += head_velocity * dt
	for name in ["pony_neck1", "pony_neck2", "pony_head"]:
		var share := 0.3 if name == "pony_head" else 0.35
		var current_basis:Basis=pose[limits.names[name]].basis
		pose[limits.names[name]].basis=current_basis.orthonormalized().slerp(limits.pose_basis(name,head_angles*share).orthonormalized(),blend).scaled_local(current_basis.get_scale())
	# Only the remaining aim belongs in the eyes; the ambient glance clock
	# previously made held eyes stare away from the player.
	fk = SOLVER.forward_kinematics(pony.profile.parents, pose, frame)
	var neutral: Basis = pony.skeleton.get_bone_global_rest(head).basis.orthonormalized()
	var facing: Basis = fk[head].basis.orthonormalized() * neutral.inverse()
	var residual: Vector3 = facing.inverse() * (look_target - fk[head].origin)
	eye_angles = Vector3(clampf(atan2(residual.y, Vector2(residual.x, residual.z).length()), -0.35, 0.35),
		clampf(atan2(-residual.x, -residual.z), -0.45, 0.45), 0.0) if active else Vector3.ZERO


func dangle_forelegs(pose: Array[Transform3D], frame: Transform3D, delta: float) -> void:
	if blend <= 0.0 or delta <= 0.0:
		_dangle_origin = Vector3.INF
		return
	var speed := (frame.origin - _dangle_origin) / delta if _dangle_origin.is_finite() else Vector3.ZERO
	var acceleration := ((speed - _dangle_speed) / delta).limit_length(25.0) if _dangle_origin.is_finite() else Vector3.ZERO
	_dangle_origin = frame.origin; _dangle_speed = speed
	var facing: Vector3 = -pony.global_basis.z; facing.y = 0.0
	facing = facing.normalized() if facing.length_squared() > .0001 else Vector3.FORWARD
	# Joints bend about her side axis; a relaxed leg folds its hoof back toward her belly.
	var hinge := facing.cross(Vector3.DOWN).normalized()
	var parents: PackedInt32Array = pony.profile.parents
	var limits = pony.joint_limits
	var fk := SOLVER.forward_kinematics(parents, pose, frame)
	var front: Array[Dictionary] = []
	for leg: Dictionary in pony.profile.legs:
		if String(leg.name).begins_with("F"): front.append(leg)
	if front.size() != 2: return
	var middle: Vector3 = (fk[front[0].proximal].origin + fk[front[1].proximal].origin) * .5
	for k in 2:
		var leg: Dictionary = front[k]
		var steps := maxi(1, ceili(delta * 120.0))
		for step in steps:
			_dangle_velocity[k] += ((-acceleration * DANGLE_LAG - _dangle_offset[k]) * 70.0 - _dangle_velocity[k] * 7.0) * (delta / steps)
			_dangle_offset[k] = (_dangle_offset[k] + _dangle_velocity[k] * (delta / steps)).limit_length(.4)
		# Upper arm: toward a point below and a little in front of her chest, legs slightly apart.
		var top: Vector3 = fk[leg.proximal].origin
		var outward: Vector3 = top - middle; outward.y = 0.0
		outward = outward.normalized() * .12 if outward.length_squared() > .000001 else Vector3.ZERO
		var want: Vector3 = Vector3.DOWN + facing * DANGLE_FORWARD + outward + _dangle_offset[k]
		_turn_bone(pose, fk, leg.proximal, fk[leg.end].origin - top, want)
		fk = SOLVER.forward_kinematics(parents, pose, frame)
		# Relaxed carpus and fetlock: a soft fold, a little more while she swings.
		var sway := clampf(_dangle_offset[k].length() * 2.0, 0.0, .35)
		for part: Array in [["wrist", 32.0], ["finger", 18.0]]:
			var name := "pony_%s_%s" % [part[0], "L" if String(leg.name).ends_with("L") else "R"]
			if not limits.names.has(name): continue
			var bone: int = limits.names[name]
			var distal: Vector3 = fk[leg.end].origin - fk[bone].origin
			if distal.length_squared() < .000001: continue
			var angle := deg_to_rad(float(part[1])) * (1.0 + sway) * blend
			var forward := Basis(hinge, angle) * distal
			var back := Basis(hinge, -angle) * distal
			var turn := Basis(hinge, angle if forward.dot(-facing) > back.dot(-facing) else -angle)
			var parent: Basis = fk[parents[bone]].basis
			pose[bone].basis = parent.inverse() * turn * parent * pose[bone].basis
			fk = SOLVER.forward_kinematics(parents, pose, frame)


## Turn a bone in world space so `current` (a vector hanging from it) points along `want`.
func _turn_bone(pose: Array[Transform3D], fk: Array[Transform3D], bone: int, current: Vector3, want: Vector3) -> void:
	if current.length_squared() < .000001 or want.length_squared() < .000001: return
	var turn := Quaternion.IDENTITY.slerp(Quaternion(current.normalized(), want.normalized()), blend)
	var parent: Basis = fk[pony.profile.parents[bone]].basis
	pose[bone].basis = parent.inverse() * Basis(turn) * parent * pose[bone].basis


func release_support(index: int, pose: Array[Transform3D]) -> void:
	if supports[index]:
		supports[index] = false
		rejected_contacts += 1
		release_poses[index] = pose.duplicate()
		release_blends[index] = 0.0
