extends RefCounted
const CROUCH := preload("res://world/minigames/apple_bucking/gather_crouch.gd")
## Gather through existing neck rotations/limits before ordinary foot IK. Navigation
## owns approach, and the body solver preserves planted hoof support afterward.
var actor: Node3D
var owner := ""
var target := Vector3.INF
var amount := 0.0
var gap := INF
var _head := -1
var _chain: Array[int] = []
var _ancestors: Array[int] = []
var _chain_index: Dictionary = {}
var _fk: Array[Transform3D] = []
var _base_rotations: Array[Quaternion] = []
var _base_scales: Array[Vector3] = []
var _mouth_local := Vector3.ZERO
var _bound := false
var _request_time := 0.0
var _support_time := 0.0
var _last_renewal_msec := 0
var _additive: Dictionary = {}
var _crouch: RefCounted
var crouch_amount := 0.0
var crouch_fit_error := INF
var crouch_fit_usec := 0

func reach_to(point: Vector3, lease_owner: String) -> bool:
	if not point.is_finite() or lease_owner.is_empty() or not _available(lease_owner): return false
	if not owner.is_empty() and owner != lease_owner: return false
	owner = lease_owner
	_support_time = 0.0
	target = point
	_request_time = .5
	_last_renewal_msec = Time.get_ticks_msec()
	return true

## Keep native standing turns available until navigation finishes alignment.
## This lease requests support cadence only, without a neck or bow target.
func renew_support(lease_owner: String) -> bool:
	if lease_owner.is_empty() or not _available(lease_owner): return false
	if not owner.is_empty() and owner != lease_owner: return false
	owner = lease_owner
	_support_time = .5
	_last_renewal_msec = Time.get_ticks_msec()
	return true

## A single actively gathering pony needs its normal support solver even
## outside conversation range. The lease and bounded renewal prevent a
## dormant helper from keeping the actor at full rate indefinitely.
func active() -> bool:
	if not is_instance_valid(actor) or Time.get_ticks_msec() - _last_renewal_msec > 1800: return false
	if _body_owner_changed(): return false
	return ((_request_time > 0.0 or _support_time > 0.0) and _available(owner)) or amount > .001 or crouch_amount > .001

## A new physical body owner supersedes the leased bow at once. An ordinary
## stationary release still gets its verified smooth return to standing.
func _body_owner_changed() -> bool:
	if not is_instance_valid(actor): return true
	return actor.get("sleeping") == true or actor.is_held() or actor.actual_speed > .08 \
		or (actor.posture != null and actor.posture.active()) \
		or (actor.flight != null and actor.flight.active())

func _relinquish_pose() -> void:
	owner = ""
	target = Vector3.INF
	_request_time = 0.0
	_support_time = 0.0
	amount = 0.0
	crouch_amount = 0.0
	_additive.clear()

func release(lease_owner: String) -> void:
	if owner != lease_owner: return
	_request_time = 0.0
	_support_time = 0.0
	target = Vector3.INF
	owner = ""

func mouth_point() -> Vector3:
	if not is_instance_valid(actor): return Vector3.INF
	var affection: Node = actor.get_node_or_null("Affection")
	return affection.mouth_point() if affection != null and affection.has_method("mouth_point") else Vector3.INF

func _available(lease_owner: String) -> bool:
	if not is_instance_valid(actor) or actor.get("sleeping") == true or actor.get("motion_paused") == true: return false
	if actor.is_held() or not actor.grounded(): return false
	if actor.posture != null and actor.posture.active(): return false
	if is_instance_valid(actor.get("conversation_target")): return false
	if actor.actual_speed > .08: return false
	var nav: Node = actor.get_node_or_null("Navigator")
	return nav != null and str(nav.get("command_owner")) == lease_owner

func _bind(sk: Skeleton3D) -> bool:
	_head = sk.find_bone("pony_head")
	if _head < 0 or not is_instance_valid(actor): return false
	_chain.clear()
	for name: String in ["pony_head", "pony_neck2", "pony_neck1"]:
		var bone := sk.find_bone(name)
		if bone >= 0: _chain.append(bone)
	_ancestors.clear()
	var ancestor := _head
	while ancestor >= 0:
		_ancestors.push_front(ancestor)
		ancestor = sk.get_bone_parent(ancestor)
	_chain_index.clear()
	for index: int in _ancestors.size(): _chain_index[_ancestors[index]] = index
	_fk.resize(_ancestors.size())
	_base_rotations.resize(_chain.size())
	_base_scales.resize(_chain.size())
	var link: Node = actor.get("neck_link") as Node
	var boop: Node = actor.get("boop_node") as Node
	var point := mouth_point()
	if link == null or boop == null or not point.is_finite(): return false
	var hs: Skeleton3D = boop.head_skeleton
	var head_bone := hs.find_bone("mHead")
	if head_bone < 0 or link._offsets.size() < 3: return false
	var op_head: Transform3D = hs.global_transform * hs.get_bone_global_pose(head_bone)
	var offset: Transform3D = link._offsets[2]
	_mouth_local = offset * (op_head.affine_inverse() * point)
	_bound = true
	_crouch = CROUCH.new()
	var fit_started := Time.get_ticks_usec()
	_crouch.bind(actor)
	crouch_fit_usec = Time.get_ticks_usec() - fit_started
	crouch_fit_error = _crouch.fit_error
	return true

func apply_source(pose: Array[Transform3D], delta: float) -> void:
	if _body_owner_changed():
		_relinquish_pose()
		return
	_support_time = maxf(0.0, _support_time - delta)
	if _request_time <= 0.0 and amount < .001 and crouch_amount < .001:
		if _support_time <= 0.0: owner = ""
		target = Vector3.INF
		return
	var sk: Skeleton3D = actor.skeleton
	if not _bound and not _bind(sk): return
	_request_time = maxf(0.0, _request_time - delta)
	var active_request := _request_time > 0.0 and target.is_finite() and _available(owner)
	amount = move_toward(amount, 1.0 if active_request else 0.0, delta / .65)
	# Gathering lowers through a fitted supported bow, rather than asking
	# neck joints to reach a target below their standing envelope.
	var low_target: bool = active_request and target.y - actor.global_position.y < .35 * float(actor.body_scale)
	crouch_amount = move_toward(crouch_amount, 1.0 if low_target and _crouch.fit_ready else 0.0, delta / .8)
	_crouch.apply_amount(pose, smoothstep(0.0, 1.0, crouch_amount))
	if amount < .001:
		if not active_request:
			owner = ""
			target = Vector3.INF
			_additive.clear()
		return
	if not active_request:
		for bone: int in _additive:
			var extra: Quaternion = _additive[bone]
			pose[bone].basis = actor.joint_limits.constrain(bone, pose[bone].basis * Basis(Quaternion.IDENTITY.slerp(extra, smoothstep(0.0, 1.0, amount))))
		return
	var frame: Transform3D = actor.global_transform * actor.pivot.transform * actor._model_frame
	var goal: Vector3 = frame.affine_inverse() * target
	for index: int in _chain.size():
		_base_rotations[index] = pose[_chain[index]].basis.orthonormalized().get_rotation_quaternion()
		_base_scales[index] = pose[_chain[index]].basis.get_scale()
	# Forward kinematics comes from the same sampled source and model frame
	# used by locomotion. No deferred modifier output becomes next tick's input.
	_update_fk(pose)
	for iteration: int in 10:
		if (_fk[-1] * _mouth_local).distance_to(goal) < .025: break
		for bone: int in _chain:
			var index: int = _chain_index[bone]
			var pivot: Vector3 = _fk[index].origin
			var lip: Vector3 = _fk[-1] * _mouth_local
			var before := lip - pivot
			var after := goal - pivot
			if before.length_squared() < .00001 or after.length_squared() < .00001: continue
			var turn := Quaternion(before.normalized(), after.normalized())
			var cap := deg_to_rad(12.0)
			if turn.get_angle() > cap: turn = Quaternion.IDENTITY.slerp(turn, cap / turn.get_angle())
			var parent_basis := _fk[index - 1].basis if index > 0 else Basis.IDENTITY
			pose[bone].basis = parent_basis.inverse() * Basis(turn) * parent_basis * pose[bone].basis
			pose[bone].basis = actor.joint_limits.constrain(bone, pose[bone].basis)
			_update_fk(pose, index)
	for index: int in _chain.size():
		var bone: int = _chain[index]
		var base: Quaternion = _base_rotations[index]
		var solved: Quaternion = pose[bone].basis.orthonormalized().get_rotation_quaternion()
		_additive[bone] = base.inverse() * solved
		pose[bone].basis = actor.joint_limits.constrain(bone, Basis(base.slerp(solved, smoothstep(0.0, 1.0, amount))).scaled_local(_base_scales[index]))
	_update_fk(pose)
	gap = (frame * _fk[-1] * _mouth_local).distance_to(target)

## Only the cached head ancestor chain needs FK. Reuse its small array and
## update descendants of the joint just changed; no full-body array per CCD step.
func _update_fk(pose: Array[Transform3D], start: int = 0) -> void:
	for index: int in range(start, _ancestors.size()):
		_fk[index] = pose[_ancestors[index]] if index == 0 else _fk[index - 1] * pose[_ancestors[index]]

## Locomotion calls this on its terrain-fitted pivot before probing/solving
## feet. The fitted source-leg rotations above already preserve every sole.
func apply_body_pivot(body_pivot: Node3D) -> void:
	if _body_owner_changed():
		_relinquish_pose()
		return
	if _crouch == null or crouch_amount <= .0001 or not _crouch.fit_ready: return
	var model: Transform3D = actor._model_frame
	body_pivot.transform *= model * _crouch.pivot_at(smoothstep(0.0, 1.0, crouch_amount)) * model.affine_inverse()

