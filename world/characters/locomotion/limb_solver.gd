extends RefCounted
## Analytic IK over two animated subchains. Intermediate joint bends survive.


static func forward_kinematics(parents: PackedInt32Array, local: Array[Transform3D],
		frame: Transform3D = Transform3D.IDENTITY) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	result.resize(local.size())
	for i in local.size():
		result[i] = (frame if parents[i] < 0 else result[parents[i]]) * local[i]
	return result


static func rotate_world(local: Array[Transform3D], globals: Array[Transform3D],
		parents: PackedInt32Array, frame: Transform3D, bone: int, rotation: Quaternion) -> void:
	var parent_basis := frame.basis if parents[bone] < 0 else globals[parents[bone]].basis
	var desired := rotation.normalized() * globals[bone].basis.orthonormalized().get_rotation_quaternion()
	var relative := parent_basis.orthonormalized().get_rotation_quaternion().inverse() * desired
	local[bone].basis = Basis(relative.normalized()).scaled_local(local[bone].basis.get_scale())


static func alignment(from: Vector3, to: Vector3) -> Quaternion:
	if from.length_squared() < 1e-12 or to.length_squared() < 1e-12:
		return Quaternion.IDENTITY
	return Quaternion(from.normalized(), to.normalized()).normalized()


static func solve(parents: PackedInt32Array, local: Array[Transform3D], frame: Transform3D,
		leg: Dictionary, target: Vector3, sole_basis: Basis, pole: Vector3,
		epsilon: float = 0.0001) -> Dictionary:
	var globals := _chain_kinematics(parents, local, frame, int(leg.leaf))
	var root: int = leg.root
	var middle: int = leg.middle
	var leaf: int = leg.leaf
	var r := globals[root].origin
	var m := globals[middle].origin
	var e := globals[leaf].origin
	var a := r.distance_to(m)
	var b := m.distance_to(e)
	var scale := globals[leaf].basis.get_scale()
	var leaf_target := target - sole_basis * (Vector3(leg.sole) * scale)
	var direction := leaf_target - r
	var distance := direction.length()
	if a < epsilon or b < epsilon or distance < epsilon:
		return {"sole": globals[leaf] * Vector3(leg.sole), "error": INF, "clamped": true}
	direction /= distance
	var flex := deg_to_rad(float(leg.get("max_flex_degrees", 180.0)))
	var minimum_reach := sqrt(maxf(0.0, a * a + b * b + 2.0 * a * b * cos(flex)))
	var reach := clampf(distance, maxf(minimum_reach, absf(a - b) + epsilon), a + b - epsilon)
	var bend := pole - direction * pole.dot(direction)
	if bend.length_squared() < 1e-10:
		bend = direction.cross(Vector3.RIGHT)
		if bend.length_squared() < 1e-10:
			bend = direction.cross(Vector3.UP)
	bend = bend.normalized()
	var along := (a * a - b * b + reach * reach) / (2.0 * reach)
	var height := sqrt(maxf(0.0, a * a - along * along))
	var wanted_middle := r + direction * along + bend * height
	rotate_world(local, globals, parents, frame, root, alignment(m - r, wanted_middle - r))
	globals = _chain_kinematics(parents, local, frame, int(leg.leaf))
	rotate_world(local, globals, parents, frame, middle,
		alignment(globals[leaf].origin - globals[middle].origin,
			r + direction * reach - globals[middle].origin))
	globals = _chain_kinematics(parents, local, frame, int(leg.leaf))
	var desired_rotation := sole_basis.orthonormalized().get_rotation_quaternion()
	var old_rotation := globals[leaf].basis.orthonormalized().get_rotation_quaternion()
	rotate_world(local, globals, parents, frame, leaf, desired_rotation * old_rotation.inverse())
	globals = _chain_kinematics(parents, local, frame, int(leg.leaf))
	var sole := globals[leaf] * Vector3(leg.sole)
	return {"sole": sole, "error": sole.distance_to(target), "clamped": absf(reach - distance) > epsilon}


static func refine_constrained(parents: PackedInt32Array, local: Array[Transform3D],
		source: Array[Transform3D], frame: Transform3D, leg: Dictionary, target: Vector3,
		sole_basis: Basis, limits: RefCounted, budget: float) -> void:
	# Share a residual between the upper leg and its neighbours. The distal
	# authored chain stays intact; no segment is translated or stretched.
	var mutable: Array[int] = [int(leg.root), int(leg.proximal), int(leg.middle), int(leg.leaf)]
	for bone in mutable:
		local[bone].basis = limits.constrain(bone, local[bone].basis)
	var globals := _chain_kinematics(parents, local, frame, int(leg.leaf))
	var best_error := (globals[leg.leaf] * Vector3(leg.sole)).distance_to(target)
	if best_error < 0.006:
		return
	# Only the four mutable bones are ever restored: keep those, not the whole pose.
	var best: Array[Transform3D] = [local[mutable[0]], local[mutable[1]], local[mutable[2]], local[mutable[3]]]
	for iteration in 6:
		for bone: int in [leg.middle, leg.proximal, leg.root]:
			globals = _chain_kinematics(parents, local, frame, int(leg.leaf))
			var pivot := globals[bone].origin
			var sole: Vector3 = globals[leg.leaf] * Vector3(leg.sole)
			var rotation := Quaternion.IDENTITY.slerp(alignment(sole - pivot, target - pivot), 0.65)
			rotate_world(local, globals, parents, frame, bone, rotation)
			_bound_rotation(local, source, bone, limits, budget)
		globals = _chain_kinematics(parents, local, frame, int(leg.leaf))
		var before: Quaternion = globals[leg.leaf].basis.orthonormalized().get_rotation_quaternion()
		var desired := sole_basis.orthonormalized().get_rotation_quaternion()
		rotate_world(local, globals, parents, frame, leg.leaf, desired * before.inverse())
		_bound_rotation(local, source, leg.leaf, limits, budget)
		globals = _chain_kinematics(parents, local, frame, int(leg.leaf))
		var error := (globals[leg.leaf] * Vector3(leg.sole)).distance_to(target)
		if error < best_error:
			best_error = error
			best = [local[mutable[0]], local[mutable[1]], local[mutable[2]], local[mutable[3]]]
		if best_error < 0.002:
			break
	for j in 4:
		local[mutable[j]] = best[j]


static func _bound_rotation(local: Array[Transform3D], source: Array[Transform3D],
		bone: int, limits: RefCounted, budget: float) -> void:
	local[bone].basis = limits.constrain(bone, local[bone].basis)
	var before := source[bone].basis.orthonormalized().get_rotation_quaternion()
	var after := local[bone].basis.orthonormalized().get_rotation_quaternion()
	var angle := before.angle_to(after)
	if angle > budget:
		local[bone] = source[bone].interpolate_with(local[bone], budget / angle)
	local[bone].basis = limits.constrain(bone, local[bone].basis)


## Scratch for the chain kinematics: every caller consumes the result before asking for
## the next, and only the leaf's ancestors are ever read, so one shared array per rig
## size replaces a 191-transform allocation per call (a leg solve makes ~25 of them).
static var _scratch: Array[Transform3D] = []
static var _chain_parents := PackedInt32Array()
static var _chains: Dictionary = {}


static func _chain_kinematics(parents: PackedInt32Array, local: Array[Transform3D],
		frame: Transform3D, leaf: int) -> Array[Transform3D]:
	# A leg solve reads only the leaf and its ancestors. Preserve the exact
	# multiplication order without recalculating eyes, mane, tail or other legs.
	if _chain_parents != parents:
		_chain_parents=parents;_chains.clear()
	if not _chains.has(leaf):
		var chain:=PackedInt32Array()
		var ancestor:=leaf
		while ancestor>=0:
			chain.append(ancestor);ancestor=parents[ancestor]
		chain.reverse();_chains[leaf]=chain
	var ancestors:PackedInt32Array=_chains[leaf]
	var result := _scratch
	if result.size() != local.size():
		result.resize(local.size())
	for bone in ancestors:
		result[bone] = (frame if parents[bone] < 0 else result[parents[bone]]) * local[bone]
	return result
