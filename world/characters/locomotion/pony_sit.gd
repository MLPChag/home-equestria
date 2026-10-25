extends RefCounted
## A reversible FK rest posture, fitted once to this rig's existing joint bounds.
## Only rotations and the model pivot change. Physics/root translation stays owned
## by locomotion; this module never stretches a bone or manufactures support.

const SOLVER := preload("res://world/characters/locomotion/limb_solver.gd")
const KEY_COUNT := 25
const MAX_SLOPE := deg_to_rad(10.0)
const MAX_SPREAD := 0.025
const MAX_CONTACT_ERROR := 0.025
const MAX_PENETRATION := 0.006
const HIP_DROP_RATIO := 0.55
const PITCH := deg_to_rad(47.0)

var pony: CharacterBody3D
var active := false
var settled := false
var blend := 0.0
var blend_velocity := 0.0
var refusal := ""
var variant := "ground"
var local_targets: Array[Vector3] = []
var contacts: Array[bool] = [true, true, true, true]
var max_fit_error := 0.0
var fit_errors := {"ground": INF, "edge": INF}
var fit_penetration := {"ground": INF, "edge": INF}
var _keys: Array = []
var _edge_keys: Array = []
var _seat_center := Vector3.ZERO
var _rest_fk: Array[Transform3D] = []
var _mutable: Array[int] = []
var _slope := Quaternion.IDENTITY


func bind(owner_pony: CharacterBody3D) -> void:
	pony = owner_pony
	_rest_fk = SOLVER.forward_kinematics(pony.profile.parents, pony.profile.rest)
	_seat_center = _rest_fk[pony.skeleton.find_bone("pony_hips")].origin
	_mutable.clear()
	for leg in pony.profile.legs:
		for bone: int in leg.chain:
			if pony.joint_limits.joints.has(bone):
				_mutable.append(bone)
	_build_keys()
	reset()


func request_sit(support: Dictionary) -> bool:
	refusal = ""
	if pony == null or _keys.is_empty():
		refusal = "Sit rig is not bound"
		return false
	# The caller probes the whole support footprint and passes a model-local
	# normal; it must revalidate while seated and call stand() if support moves.
	var normal: Vector3 = support.get("normal", Vector3.UP)
	var requested := "edge" if bool(support.get("edge", false)) else "ground"
	var spread := float(support.get("height_spread", INF))
	var clearance := float(support.get("edge_clearance", 0.0))
	if pony._held:
		refusal = "Cannot sit while held"
	elif not normal.is_finite() or normal.length_squared() < 0.5 or normal.angle_to(Vector3.UP) > MAX_SLOPE:
		refusal = "Seat slope exceeds 10 degrees"
	elif not support.get("seat_supported", false):
		refusal = "No support under the rump"
	elif not _both(support.get("front_supported", [])):
		refusal = "Both front hooves need support"
	elif not is_finite(spread) or spread < 0.0 or spread > MAX_SPREAD:
		refusal = "Seat contacts differ by more than 25 mm"
	elif bool(support.get("edge", false)):
		if not is_finite(clearance) or clearance < pony.profile.hip_height * 0.45:
			refusal = "Hanging hind legs need verified free space"
	elif not _both(support.get("hind_supported", [])):
		refusal = "Hind hoof support is missing"
	if refusal.is_empty() and (float(fit_errors[requested]) > MAX_CONTACT_ERROR
			or float(fit_penetration[requested]) > MAX_PENETRATION):
		refusal = "Sit contacts cannot fit this rig within existing tolerances"
	if not refusal.is_empty():
		stand()
		return false
	if blend > 0.001:
		# Do not swap the ground and edge solutions under a seated pony.
		active = true
		return true
	variant = requested
	_slope = Quaternion(Vector3.UP, normal.normalized())
	active = true
	return true


func stand() -> void:
	active = false
	settled = false


func reset() -> void:
	active = false
	settled = false
	blend = 0.0
	blend_velocity = 0.0
	variant = "ground"
	refusal = ""
	_slope = Quaternion.IDENTITY
	contacts.fill(true)
	_update_targets()


func update(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	var remaining := minf(delta, 0.25)
	while remaining > 0.000001:
		var dt := minf(remaining, 1.0 / 120.0)
		remaining -= dt
		var target := 1.0 if active else 0.0
		# A critically damped transition has weight but no repeated idle bounce.
		blend_velocity += ((target - blend) * 36.0 - blend_velocity * 12.0) * dt
		blend_velocity = clampf(blend_velocity, -1.1, 1.1)
		blend = clampf(blend + blend_velocity * dt, 0.0, 1.0)
	if absf((1.0 if active else 0.0) - blend) < 0.00005 and absf(blend_velocity) < 0.0005:
		blend = 1.0 if active else 0.0
		blend_velocity = 0.0
	settled = active and blend == 1.0
	_update_targets()


func body_transform() -> Transform3D:
	return Transform3D(Basis(_slope), Vector3.ZERO) * _pivot(blend)


func apply_pose(pose: Array[Transform3D]) -> void:
	if blend <= 0.0 or _keys.is_empty():
		return
	var keys: Array = _edge_keys if variant == "edge" else _keys
	var cursor := blend * (KEY_COUNT - 1)
	var before := mini(int(cursor), KEY_COUNT - 2)
	var fraction := cursor - before
	for bone in _mutable:
		var a: Transform3D = keys[before][bone]
		var b: Transform3D = keys[before + 1][bone]
		var rotation := a.basis.orthonormalized().get_rotation_quaternion().slerp(b.basis.orthonormalized().get_rotation_quaternion(), fraction)
		pose[bone].basis = pony.joint_limits.constrain(bone, Basis(rotation).scaled_local(pose[bone].basis.get_scale()))


func _pivot(amount: float) -> Transform3D:
	var pitch := Basis(Vector3.RIGHT, PITCH * amount)
	var origin := _seat_center - pitch * _seat_center
	origin.y -= pony.profile.hip_height * HIP_DROP_RATIO * amount
	return Transform3D(pitch, origin)


func _target(index: int, amount: float, edge: bool) -> Vector3:
	var start: Vector3 = pony.profile.legs[index].neutral_sole
	var side := -1.0 if index % 2 == 0 else 1.0
	var finish := start if index < 2 else Vector3(side * 0.18, 0.0, -0.20)
	if edge and index >= 2:
		finish = Vector3(side * 0.16, -0.15, 0.33)
	var target := start.lerp(finish, amount)
	# Hooves re-place in an arc while the hips sink; resting contacts remain fixed.
	if index >= 2 and amount > 0.0 and amount < 1.0:
		target.y += sin(PI * amount) * 0.055
	return target


func _update_targets() -> void:
	local_targets.clear()
	if pony == null:
		return
	var free_fk: Array[Transform3D] = []
	if variant == "edge" and not _edge_keys.is_empty():
		var pose: Array[Transform3D] = pony.profile.standing.duplicate()
		apply_pose(pose)
		free_fk = SOLVER.forward_kinematics(pony.profile.parents, pose, body_transform())
	for i in 4:
		# Dangling feet follow their authored FK; they never claim a contact.
		local_targets.append(pony.profile.sole_point(pony.profile.legs[i], free_fk) if i >= 2 and not free_fk.is_empty()
			else _slope * _target(i, blend, false))
		contacts[i] = i < 2 or blend == 0.0 or (blend == 1.0 and variant == "ground")


func _build_keys() -> void:
	_keys.clear()
	_edge_keys.clear()
	max_fit_error = 0.0
	for edge in [false, true]:
		var keys: Array = []
		var variant_error := 0.0
		var penetration := 0.0
		for key in KEY_COUNT:
			var amount := float(key) / (KEY_COUNT - 1)
			var pose: Array[Transform3D] = pony.profile.standing.duplicate()
			if key > 0:
				_seed(pose, amount, edge)
				for i in 4:
					if i < 2 or not edge:
						_fit_leg(pose, i, _pivot(amount), _target(i, amount, edge))
			pony.joint_limits.apply(pose)
			var fk := SOLVER.forward_kinematics(pony.profile.parents, pose, _pivot(amount))
			for i in 4:
				var sole: Vector3 = pony.profile.sole_point(pony.profile.legs[i], fk)
				if i < 2 or not edge:
					variant_error = maxf(variant_error, sole.distance_to(_target(i, amount, edge)))
					penetration = maxf(penetration, -sole.y)
			keys.append(pose)
		var name := "edge" if edge else "ground"
		fit_errors[name] = variant_error
		fit_penetration[name] = penetration
		max_fit_error = maxf(max_fit_error, variant_error)
		if edge:
			_edge_keys = keys
		else:
			_keys = keys


func _seed(pose: Array[Transform3D], amount: float, edge: bool) -> void:
	var back := {"flank": 9.0, "femur": 5.0, "tibia": -13.0, "legLower": 47.0, "tarsal": -31.0, "hoof": -44.0}
	if edge:
		back = {"flank": -20.0, "femur": -15.0, "tibia": -8.0, "legLower": 30.0, "tarsal": -20.0, "hoof": -18.0}
	var front := {"shoulder": -25.0, "upperArm": 0.0, "lowerArm": 15.0, "wrist": -18.0, "hand": -8.0, "finger": 0.0}
	for i in 4:
		var table: Dictionary = front if i < 2 else back
		for part: String in table:
			var name := "pony_%s_%s" % [part, "L" if i % 2 == 0 else "R"]
			var bone: int = pony.joint_limits.names[name]
			var splay := (-1.0 if i % 2 == 0 else 1.0) * (3.0 if i < 2 else 5.0) if part in ["shoulder", "flank"] else 0.0
			pose[bone].basis = pony.joint_limits.pose_basis(name, Vector3(deg_to_rad(table[part]) * amount, 0.0, deg_to_rad(splay) * amount))


func _fit_leg(pose: Array[Transform3D], index: int, frame: Transform3D, target: Vector3) -> void:
	var leg: Dictionary = pony.profile.legs[index]
	# Bind-time constrained coordinate fitting authors FK rotations for this rig.
	# Runtime only interpolates these rotations; there is no per-frame IK here.
	for iteration in 128:
		for bone: int in leg.chain:
			if not pony.joint_limits.joints.has(bone):
				continue
			var globals := SOLVER._chain_kinematics(pony.profile.parents, pose, frame, leg.end)
			var goal := target + Vector3.UP * float(leg.end_height)
			var rotation := Quaternion.IDENTITY.slerp(SOLVER.alignment(globals[leg.end].origin - globals[bone].origin, goal - globals[bone].origin), 0.4)
			SOLVER.rotate_world(pose, globals, pony.profile.parents, frame, bone, rotation)
			pose[bone].basis = pony.joint_limits.constrain(bone, pose[bone].basis)
		var fk := SOLVER._chain_kinematics(pony.profile.parents, pose, frame, leg.end)
		if pony.profile.sole_point(leg, fk).distance_to(target) < 0.001:
			break


static func _both(values: Array) -> bool:
	return values.size() == 2 and bool(values[0]) and bool(values[1])
