extends "res://world/characters/locomotion/pony_sit.gd"
## Small supported bow for ground gathering, fitted with the existing FK
## posture fitter. All four native soles keep their standing support points.
## No joint limits, lengths, solver contact budgets or physics root change.
const GATHER_KEYS := 9
const DATA := preload("res://world/minigames/apple_bucking/gather_crouch_data.gd")
const CACHE_PATH := "res://world/minigames/apple_bucking/gather_crouch_data.tres"
const GATHER_PITCH_DEGREES := -12.0
const GATHER_DROP_RATIO := .16
var fit_ready := false
var fit_error := INF
var allow_offline_fit := false
var signature := ""
var orientation_error := INF
var worst_fit_key := -1
var worst_fit_leg := -1
var worst_angle_key := -1
var worst_angle_leg := -1

func _pivot(amount: float) -> Transform3D:
	var pitch := Basis(Vector3.RIGHT, deg_to_rad(GATHER_PITCH_DEGREES) * amount)
	var origin := _seat_center - pitch * _seat_center
	origin.y -= pony.profile.hip_height * GATHER_DROP_RATIO * amount
	return Transform3D(pitch, origin)

func _build_keys() -> void:
	_keys.clear()
	var contacts: Array = []
	for leg: Dictionary in pony.profile.legs: contacts.append([leg.neutral_sole, leg.end_height])
	signature = var_to_str(["combined-residual-v1", GATHER_PITCH_DEGREES, GATHER_DROP_RATIO, pony.profile.parents, pony.profile.rest, pony.profile.standing, pony.joint_limits.joints, contacts]).sha256_text()
	if not allow_offline_fit and ResourceLoader.exists(CACHE_PATH):
		var data: Resource = load(CACHE_PATH)
		if data.rig_signature == signature and data.key_rotations.size() == GATHER_KEYS and data.bone_names.size() == _mutable.size() and data.max_fit_error <= .008 and data.max_orientation_error <= .01:
			var same := true
			for index: int in _mutable.size():
				if data.bone_names[index] != pony.skeleton.get_bone_name(_mutable[index]): same = false
			if same:
				for values: PackedFloat32Array in data.key_rotations:
					if values.size() != _mutable.size() * 4:
						_keys.clear()
						return
					var pose: Array[Transform3D] = pony.profile.standing.duplicate()
					for index: int in _mutable.size():
						var at := index * 4
						var rotation := Quaternion(values[at], values[at + 1], values[at + 2], values[at + 3]).normalized()
						pose[_mutable[index]].basis = Basis(rotation).scaled_local(pose[_mutable[index]].basis.get_scale())
					_keys.append(pose)
				fit_error = float(data.max_fit_error)
				orientation_error = float(data.max_orientation_error)
				fit_ready = true
				return
	# An unknown rig stays unbowed; never solve a 75ms pose on first gameplay contact.
	if not allow_offline_fit: return
	fit_error = 0.0
	orientation_error = 0.0
	for key: int in GATHER_KEYS:
		var amount := float(key) / float(GATHER_KEYS - 1)
		var pose: Array[Transform3D] = pony.profile.standing.duplicate()
		if key > 0:
			# The existing native fitter works from the preceding valid key,
			# avoiding a singular straight-leg guess at every amount.
			var preceding: Array[Transform3D] = _keys[-1]
			pose = preceding.duplicate()
			# The analytic knee plane supplies the outward bend branch.
			for leg: int in 4:
				var limb: Dictionary = pony.profile.legs[leg]
				var pivot_frame := _pivot(amount)
				# The fitted leaf keeps its standing world orientation;
				# its actual toe bottom therefore uses standing world up.
				_fit_leg(pose, leg, pivot_frame, limb.neutral_sole)
		pony.joint_limits.apply(pose)
		var fk := SOLVER.forward_kinematics(pony.profile.parents, pose)
		for leg: int in 4:
			var actual: Vector3 = (_pivot(amount) * fk[pony.profile.legs[leg].end]).origin - Vector3.UP * float(pony.profile.legs[leg].end_height)
			var position_error := actual.distance_to(pony.profile.legs[leg].neutral_sole)
			if position_error > fit_error:
				fit_error = position_error
				worst_fit_key = key
				worst_fit_leg = leg
			var world_leaf: Basis = _pivot(amount).basis * fk[pony.profile.legs[leg].leaf].basis
			var expected: Basis = pony.profile.legs[leg].sole_basis
			var angle_error := world_leaf.orthonormalized().get_rotation_quaternion().angle_to(expected.orthonormalized().get_rotation_quaternion())
			if angle_error > orientation_error:
				orientation_error = angle_error
				worst_angle_key = key
				worst_angle_leg = leg
		_keys.append(pose)
	fit_ready = fit_error <= .008 and orientation_error <= .01
	if not fit_ready: _keys.clear()

func save_validated_cache() -> bool:
	if not allow_offline_fit or not fit_ready: return false
	var data := DATA.new()
	data.rig_signature = signature
	data.max_fit_error = fit_error
	data.max_orientation_error = orientation_error
	for bone: int in _mutable: data.bone_names.append(pony.skeleton.get_bone_name(bone))
	for pose: Array[Transform3D] in _keys:
		var values := PackedFloat32Array()
		for bone: int in _mutable:
			var rotation := pose[bone].basis.orthonormalized().get_rotation_quaternion()
			values.append_array([rotation.x, rotation.y, rotation.z, rotation.w])
		data.key_rotations.append(values)
	return ResourceSaver.save(data, CACHE_PATH) == OK

## The normal foot owner preserves standing hoof orientation. Fit that
## orientation alongside position, inside existing bounds, before baking.
func _fit_leg(pose: Array[Transform3D], index: int, frame: Transform3D, target: Vector3) -> void:
	var leg: Dictionary = pony.profile.legs[index]
	var desired: Basis = leg.sole_basis
	# Existing analytic contact solve selects the normal knee plane,
	# then constrained coordinate descent minimizes both coupled tasks.
	var globals := SOLVER._chain_kinematics(pony.profile.parents, pose, frame, leg.end)
	var pole: Vector3 = globals[leg.middle].origin-globals[leg.root].origin
	var local_fk := SOLVER._chain_kinematics(pony.profile.parents, pose, Transform3D.IDENTITY, leg.end)
	var source_sole: Vector3 = pony.profile.sole_point(leg, local_fk)
	var fitted: Dictionary = leg.duplicate()
	fitted.sole = local_fk[leg.leaf].affine_inverse()*source_sole
	SOLVER.solve(pony.profile.parents,pose,frame,fitted,target,desired,pole)
	for bone: int in leg.chain:
		if pony.joint_limits.joints.has(bone):pose[bone].basis=pony.joint_limits.constrain(bone,pose[bone].basis)
	var best := _cost(pose,leg,frame,target,desired)
	for step: float in [.16,.08,.04,.02,.01,.005,.002,.001]:
		for sweep: int in 10:
			var changed := false
			for bone: int in leg.chain:
				if not pony.joint_limits.joints.has(bone):continue
				var original: Basis = pose[bone].basis
				var held: Basis = original
				for axis: Vector3 in [Vector3.RIGHT,Vector3.UP,Vector3.BACK]:
					for direction: float in [-1.0,1.0]:
						pose[bone].basis=pony.joint_limits.constrain(bone,Basis(axis,step*direction)*original)
						var cost := _cost(pose,leg,frame,target,desired)
						if cost<best:
							best=cost;held=pose[bone].basis;changed=true
				pose[bone].basis=held
			if not changed:break
func _cost(pose: Array[Transform3D], leg: Dictionary, frame: Transform3D, target: Vector3, desired: Basis) -> float:
	var fk := SOLVER._chain_kinematics(pony.profile.parents,pose,frame,leg.end)
	var bottom: Vector3=fk[leg.end].origin-Vector3.UP*float(leg.end_height)
	var position := bottom.distance_squared_to(target)
	var angle := fk[leg.leaf].basis.orthonormalized().get_rotation_quaternion().angle_to(desired.orthonormalized().get_rotation_quaternion())
	return position+angle*angle*.05

func apply_amount(pose: Array[Transform3D], amount: float) -> void:
	if not fit_ready or _keys.is_empty() or amount <= .0001: return
	var cursor := clampf(amount, 0.0, 1.0) * float(GATHER_KEYS - 1)
	var before := mini(int(cursor), GATHER_KEYS - 2)
	var fraction := cursor - before
	for bone: int in _mutable:
		var a: Transform3D = _keys[before][bone]
		var b: Transform3D = _keys[before + 1][bone]
		var rotation := a.basis.orthonormalized().get_rotation_quaternion().slerp(b.basis.orthonormalized().get_rotation_quaternion(), fraction)
		pose[bone].basis = pony.joint_limits.constrain(bone, Basis(rotation).scaled_local(pose[bone].basis.get_scale()))

func pivot_at(amount: float) -> Transform3D:
	return _pivot(clampf(amount, 0.0, 1.0)) if fit_ready else Transform3D.IDENTITY
