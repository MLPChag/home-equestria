extends SkeletonModifier3D
## Native iris controls and skinned lids. The devkit uses mFaceNoseLeft/Right
## for pupils (Copy Location + normal-tracking Shrinkwrap onto IKEye), not mEye*.
## Keep that curved surface, original weights, facial topology and textures.

const CROWD_PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under the crowd lab's --profile-cpu
const FK := preload("res://world/characters/locomotion/limb_solver.gd")
const NATIVE := preload("res://world/characters/locomotion/native_solver.gd")
## PonySolverNative (docs/NATIVE_SOLVER_2026_09_25.md) runs the modifier pass with the same
## result; null keeps the GDScript below.
var native: RefCounted
@export var convergence_degrees := 5.0
var closure := 0.0
## Temporary expression underneath the blink; zero is the fully open default.
var expression_closure := 0.0
var expression_brows: Dictionary = {}
var _brow_shapes: Dictionary = {}
var expression_eyes: Dictionary = {}
var expression_ears: Dictionary = {}
var _eye_shapes: Dictionary = {}
var _ear_shapes: Dictionary = {}
var gaze := Vector2.ZERO # head-local yaw/pitch; radians
## Optional curved iris artwork shares the resolved target/saccade and native lid clock.
var surface_update: Callable
var target_world := Vector3.ZERO
var target_weight := 0.0
var saccades_enabled := true
## PonyCrowd NEAR mares (6 m and beyond): full run every `rate_divisor`-th physics tick,
## the cached bone writes in between. Nobody sees a 20 Hz glance at that range.
var rate_divisor := 1
var rate_phase := 0
var _written: Dictionary = {}
var blink_enabled := true
var _rests: Array[Transform3D] = []
var _parents: Array[int] = []
var _rest_globals: Array[Transform3D] = []
var _lid_open: Dictionary = {}
var _lid_closed: Dictionary = {}
var _eye_bones: Array[int] = []
var _head_bone := -1
var _eye_center_head := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
var _wait := 2.0
var _from := Vector2.ZERO
var _to := Vector2.ZERO
var _offset := Vector2.ZERO
var _scan_offset := Vector2.ZERO
var _fixation := 0.0
var _elapsed := 1.0
var _duration := 0.08
var _blink_wait := 3.0
var _blink_time := -1.0


## Every clip bind() samples. With the rig's bones they are all its poses depend on.
const BIND_CLIPS := ["blink_left", "blink_right", "brows_angry", "brows_sad", "brows_wide", "brows_confused_left",
	"brows_happy_right", "eyes_mad", "eyes_sad", "eyes_wide", "ears_alert", "ears_side", "ears_agitated"]
## [bone names, rests, parents, clips] -> the sampled lid, brow, eye and ear poses. Every head of a
## model shares the rig and the clip library; sampling ~200 clip poses with FK cost each spawn
## a large synchronous stall. The shared dictionaries are only read after bind().
static var _bound := {}

func bind(player: AnimationPlayer) -> void:
	var sk := get_skeleton()
	# From the global generator: random in game, repeatable in a test that calls seed().
	_rng.seed = randi()
	var names := PackedStringArray()
	for i in sk.get_bone_count():
		_rests.append(sk.get_bone_rest(i))
		_parents.append(sk.get_bone_parent(i))
		names.append(sk.get_bone_name(i))
	var clips := []
	for clip: String in BIND_CLIPS:
		clips.append(player.get_animation(clip) if player.has_animation(clip) else null)
	var key := [names, _rests.duplicate(), _parents.duplicate(), clips]
	var bound: Dictionary = _bound.get(key, {})
	if bound.is_empty():
		var errors := PackedStringArray()
		_bind_poses(sk, player, errors)
		_bound[key] = {"rest_globals": _rest_globals.duplicate(), "head": _head_bone, "eyes": _eye_bones.duplicate(),
			"open": _lid_open, "closed": _lid_closed, "brows": _brow_shapes, "eye_shapes": _eye_shapes,
			"ears": _ear_shapes, "center": _eye_center_head, "errors": errors}
	else:
		for message in bound.errors: push_error(message)
		_rest_globals.assign(bound.rest_globals)
		_head_bone = bound.head
		_eye_bones.assign(bound.eyes)
		_lid_open = bound.open
		_lid_closed = bound.closed
		_brow_shapes = bound.brows
		_eye_shapes = bound.eye_shapes
		_ear_shapes = bound.ears
		_eye_center_head = bound.center
	native = NATIVE.create() if NATIVE.enabled("eyes") else null
	if native != null:
		native.bind_eyes(_lid_open, _lid_closed, _eye_shapes, _brow_shapes, _ear_shapes, PackedInt32Array(_eye_bones),
			_head_bone, _eye_center_head, _rest_globals, PackedInt32Array(_parents))


func _bind_poses(sk: Skeleton3D, player: AnimationPlayer, errors: PackedStringArray) -> void:
	_rest_globals = FK.forward_kinematics(_parents, _rests)
	_head_bone = sk.find_bone("mHead")
	for side in ["Left", "Right"]:
		_eye_bones.append(sk.find_bone("mFaceNose" + side))
		var clip: String = "blink_" + side.to_lower()
		var upper := sk.find_bone("mFaceEyeLidUpper" + side)
		var lower := sk.find_bone("mFaceEyeLidLower" + side)
		if not player.has_animation(clip) or upper < 0 or lower < 0:
			errors.append("OpenPony eye motion: missing native blink pose " + side)
			push_error(errors[-1])
			continue
		var anim := player.get_animation(clip)
		var times: Array[float] = [0.0]
		for track in anim.get_track_count():
			if "EyeLid" not in str(anim.track_get_path(track)): continue
			for key in anim.track_get_key_count(track):
				var t := anim.track_get_key_time(track, key)
				if t not in times: times.append(t)
		var max_gap := -INF
		var min_gap := INF
		var opened: Array[Transform3D] = []
		var closed: Array[Transform3D] = []
		for t in times:
			var pose := _sample(anim, t)
			var globals := FK.forward_kinematics(_parents, pose)
			var gap := globals[upper].origin.y - globals[lower].origin.y
			if gap > max_gap:
				max_gap = gap
				opened = pose
			if gap < min_gap:
				min_gap = gap
				closed = pose
		for i in sk.get_bone_count():
			var name := sk.get_bone_name(i)
			if name.ends_with(side) and (name.begins_with("mFaceEyeLid") \
					or name.begins_with("mFaceEyecorner") or name.begins_with("mFaceEyebrow") \
					or name.begins_with("mFaceCheekUpper") or name.begins_with("mFaceForehead")):
				_lid_open[i] = opened[i]
				_lid_closed[i] = closed[i]
	if _head_bone >= 0 and _eye_bones[0] >= 0 and _eye_bones[1] >= 0:
		_bind_brows(player)
		_bind_expression_shapes(player)
	_eye_center_head = _rest_globals[_head_bone].affine_inverse() * \
			((_rest_globals[_eye_bones[0]].origin + _rest_globals[_eye_bones[1]].origin) * .5)


func _sample(anim: Animation, time: float) -> Array[Transform3D]:
	var pose := _rests.duplicate()
	var sk := get_skeleton()
	for track in anim.get_track_count():
		var path := anim.track_get_path(track)
		if path.get_subname_count() == 0: continue
		var i := sk.find_bone(path.get_subname(0))
		if i < 0: continue
		match anim.track_get_type(track):
			Animation.TYPE_POSITION_3D: pose[i].origin = anim.position_track_interpolate(track, time)
			Animation.TYPE_ROTATION_3D:
				pose[i].basis = Basis(anim.rotation_track_interpolate(track, time)).scaled_local(pose[i].basis.get_scale())
	return pose


func advance(delta: float) -> void:
	# Attention already owns target_weight for listening, looking and carrying.
	# Fixation competes with exploratory scans regardless of target identity/distance.
	_fixation = lerpf(_fixation, clampf(target_weight, 0.0, 1.0), 1.0 - exp(-delta * 5.0))
	_wait -= delta
	if saccades_enabled and _wait <= 0.0:
		_from = _scan_offset
		var angle := _rng.randf_range(-PI, PI)
		var radius := sqrt(_rng.randf_range(.12, 1.0))
		_to = Vector2(cos(angle) * .044, sin(angle) * .027) * radius
		if _rng.randf() < .18: _to *= .18 # Small corrective return, not a regular reset.
		_duration = _rng.randf_range(.035, .065) + _from.distance_to(_to) * .35
		_elapsed = 0.0
		# Occasional paired shifts amid unequal longer fixations avoid a metronome.
		_wait = _rng.randf_range(.18, .38) if _rng.randf() < .16 else _rng.randf_range(.8, 4.8)
	_elapsed += delta
	var t := clampf(_elapsed / _duration, 0.0, 1.0)
	var eased := t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
	_scan_offset = _from.lerp(_to, eased) if saccades_enabled else Vector2.ZERO
	_offset = _scan_offset * lerpf(1.0, .22, smoothstep(0.0, 1.0, _fixation))
	if not blink_enabled: return
	_blink_wait -= delta
	if _blink_wait <= 0.0 and _blink_time < 0.0:
		_blink_time = 0.0
		_blink_wait = _rng.randf_range(3.0, 7.0)
	closure = 0.0
	if _blink_time >= 0.0:
		_blink_time += delta
		closure = smoothstep(0.0, 0.10, _blink_time) if _blink_time < 0.10 else 1.0 - smoothstep(0.10, 0.26, _blink_time)
		if _blink_time >= 0.26: _blink_time = -1.0


func _unprofiled_process_modification() -> void:
	if not is_inside_tree(): return
	var sk := get_skeleton()
	if not is_instance_valid(sk) or not sk.is_inside_tree(): return
	if _rest_globals.is_empty(): return
	if rate_divisor > 1 and ((Engine.get_physics_frames() + rate_phase) % rate_divisor) != 0:
		# Clip-tier mare: re-apply the last full run (Skeleton3D reverts modifier writes).
		if native != null:
			native.eye_rewrite(sk)
			return
		for b in _written: sk.set_bone_pose(b, _written[b])
		return
	if native != null:
		var scalars := PackedFloat64Array([closure, expression_closure, target_weight, convergence_degrees])
		scalars.append_array(_native_asymmetry())
		native.eye_process(sk, scalars, gaze, _offset, target_world, expression_eyes, expression_brows,
			expression_ears, surface_update)
		return
	_written.clear()
	var lid_closure := 1.0 - (1.0 - clampf(closure, 0.0, 1.0)) * (1.0 - clampf(expression_closure, 0.0, 1.0))
	for i in _lid_open:
		var opened: Transform3D = _lid_open[i]
		# Blend the original eye poses as a convex mix, then close the actual lids.
		# Blinks must still reach the same native closed pose under every expression.
		var total := 0.0
		for shape in expression_eyes:
			if _eye_shapes.get(shape,{}).has(i):total+=clampf(expression_eyes[shape],0.0,1.0)
		var mass := maxf(0.0,1.0-total)
		for shape in expression_eyes:
			if not _eye_shapes.get(shape,{}).has(i):continue
			var weight := clampf(float(expression_eyes[shape]),0.0,1.0)
			if weight < .0001:continue
			mass+=weight
			opened=opened.interpolate_with(_eye_shapes[shape][i],weight/mass)
		var pose: Transform3D = opened.interpolate_with(_lid_closed[i], lid_closure)
		_write(sk, i, pose)
	# Apply only original brow/forehead deltas, above the freshly reset blink pose.
	for shape in _brow_shapes:
		var weight := clampf(float(expression_brows.get(shape,0.0)),0.0,1.0)*(1.0-lid_closure)
		if weight < .0001: continue
		for b in _brow_shapes[shape]:
			var delta: Transform3D = _brow_shapes[shape][b]
			var pose := sk.get_bone_pose(b)
			pose.origin += delta.origin * weight
			pose.basis = pose.basis * Basis(Quaternion.IDENTITY.slerp(delta.basis.get_rotation_quaternion(),weight))
			_write(sk, b,pose)
	# Native ear rotations add to this frame's source pose; no persistent bone reset.
	for shape in expression_ears:
		var weight := clampf(float(expression_ears[shape]),0.0,1.0)
		if weight < .0001:continue
		for b in _ear_shapes.get(shape,{}):
			var delta:Transform3D=_ear_shapes[shape][b]
			var pose:=sk.get_bone_pose(b)
			pose.origin+=delta.origin*weight
			pose.basis=pose.basis*Basis(Quaternion.IDENTITY.slerp(delta.basis.get_rotation_quaternion(),weight))
			_write(sk, b,pose)
	var aim := gaze
	if target_weight > 0.0 and _head_bone >= 0:
		# Read the actual linked head inside its modifier, after body/neck motion.
		# Native head forward is +Z; this avoids guessing native/XR yaw signs.
		var frame := sk.global_transform * sk.get_bone_global_pose(_head_bone)
		var direction := frame.affine_inverse() * target_world - _eye_center_head
		if direction.length_squared() > .0001:
			var directed := Vector2(atan2(direction.x, direction.z),
				atan2(direction.y, Vector2(direction.x, direction.z).length()))
			aim = aim.lerp(directed, clampf(target_weight,0.0,1.0))
	if surface_update.is_valid():
		surface_update.call(surface_angles(0,aim + _offset),surface_angles(1,aim + _offset),lid_closure)
	for side_index in _eye_bones.size():
		var bone := _eye_bones[side_index]
		if bone < 0: continue
		_write(sk, bone, eye_pose(side_index, aim + _offset))


## Radians both eyes turn inward toward something right at her nose (a booping finger,
## hybrid_mare.gd): the same per-eye path as background_eye_motion.gd's asymmetric gaze, which the
## native eye pass applies (angles * 0.2 plus the inward shift). 0 = ordinary gaze.
var cross_inward := 0.0

func surface_angles(side_index: int, angles: Vector2) -> Vector2:
	if cross_inward > 0.0:
		var side := 1.0 if side_index == 0 else -1.0
		return angles * 0.2 + Vector2(-side * cross_inward, 0.0)
	return angles


## For the native pass: [1 when surface_angles() shifts the eyes, inward, vertical radians].
func _native_asymmetry() -> PackedFloat64Array:
	return PackedFloat64Array([1.0 if cross_inward > 0.0 else 0.0, cross_inward, 0.0])


func eye_pose(side_index: int, angles: Vector2) -> Transform3D:
	var side := 1.0 if side_index == 0 else -1.0
	var bone := _eye_bones[side_index]
	var rest := _rest_globals[bone]
	# Least-squares quadric of the devkit IKEye helper (4097 vertices/side),
	# transformed from Blender Z-up to native skeleton space. No new eye shape.
	var center := Vector3(side * 0.07155437, 0.91847255, 0.31813008)
	var metric := Basis(Vector3(477.04993, 0.0, side * 378.63708),
		Vector3(0.0, 60.65196, 0.0), Vector3(side * 378.63708, 0.0, 493.82285))
	var neutral := (metric * (rest.origin - center)).normalized()
	var yaw := -side * deg_to_rad(convergence_degrees) + clampf(angles.x, -0.08, 0.08)
	var normal := (Basis(Vector3.UP, yaw) * neutral).normalized()
	# The devkit helper is a tall ellipsoid, so equal normal angles cause far
	# more vertical travel. Limit it to the visible socket instead of rolling
	# the pupil almost completely behind a lid on an ordinary upward glance.
	normal.y = clampf(normal.y + clampf(angles.y, -.25, .25) * .2, -.06, .06)
	normal = normal.normalized()
	var inverse := metric.inverse()
	var surface := center + inverse * normal / sqrt(normal.dot(inverse * normal))
	# Calibrate the fitted surface to the exact authored rest (fit residual <2%).
	var rest_surface := center + inverse * neutral / sqrt(neutral.dot(inverse * neutral))
	var posed := Transform3D(Basis(Quaternion(neutral, normal)) * rest.basis,
		rest.origin + surface - rest_surface)
	return _rest_globals[_parents[bone]].affine_inverse() * posed


## A cached distant face must not depend on modifier callback timing, a blink,
## or where the first instance happened to look. Build a snapshot without touching
## the live skeleton: Skeleton3D restores modifier writes after rendering.
func neutral_global_poses() -> Array[Transform3D]:
	var sk := get_skeleton()
	var poses: Array[Transform3D] = []
	for b in sk.get_bone_count():
		poses.append(_lid_open.get(b, sk.get_bone_pose(b)))
	for side in _eye_bones.size():
		if _eye_bones[side] >= 0:
			poses[_eye_bones[side]] = eye_pose(side, Vector2.ZERO)
	return FK.forward_kinematics(_parents, poses)


func _bind_brows(player: AnimationPlayer) -> void:
	var sk := get_skeleton()
	for name in ["brows_angry","brows_sad","brows_wide","brows_confused_left","brows_happy_right"]:
		if not player.has_animation(name): continue
		var anim := player.get_animation(name)
		var best := -1.0
		var chosen: Dictionary = {}
		# Native pose clips include returns to neutral; sample their maximum authored pose.
		for sample_index in 17:
			var pose := _sample(anim,anim.length*sample_index/16.0)
			var deltas: Dictionary = {}
			var amount := 0.0
			for b in _lid_open:
				var bone := sk.get_bone_name(b)
				if not (bone.begins_with("mFaceEyebrow") or bone.begins_with("mFaceForehead")): continue
				var delta := Transform3D(_rests[b].basis.inverse()*pose[b].basis,pose[b].origin-_rests[b].origin)
				amount += delta.origin.length()+absf(delta.basis.get_rotation_quaternion().get_angle())*.02
				deltas[b]=delta
			if amount > best: best=amount;chosen=deltas
		_brow_shapes[name]=chosen


func _bind_expression_shapes(player: AnimationPlayer) -> void:
	var sk := get_skeleton()
	for name in ["eyes_mad","eyes_sad","eyes_wide","ears_alert","ears_side","ears_agitated"]:
		if not player.has_animation(name):continue
		var anim := player.get_animation(name)
		var ear: bool = name.begins_with("ears_")
		var best := -INF
		var chosen:Dictionary={}
		for sample_index in 17:
			var pose:=_sample(anim,anim.length*sample_index/16.0)
			var amount:=0.0
			var values:Dictionary={}
			for b in sk.get_bone_count():
				var bone:=sk.get_bone_name(b)
				if ear:
					if not bone.begins_with("mFaceEar"):continue
					var delta:=Transform3D(_rests[b].basis.inverse()*pose[b].basis,pose[b].origin-_rests[b].origin)
					values[b]=delta
					amount+=absf(delta.basis.get_rotation_quaternion().get_angle())
				elif _lid_open.has(b) and (bone.begins_with("mFaceEyeLid") or bone.begins_with("mFaceEyecorner") or bone.begins_with("mFaceCheekUpper")):
					values[b]=pose[b]
			if not ear:
				var globals:=FK.forward_kinematics(_parents,pose)
				for side in ["Left","Right"]:
					var upper:=sk.find_bone("mFaceEyeLidUpper"+side)
					var lower:=sk.find_bone("mFaceEyeLidLower"+side)
					amount+=(globals[upper].origin.y-globals[lower].origin.y)*(1.0 if name=="eyes_wide" else -1.0)
			if amount>best:best=amount;chosen=values
		if ear:_ear_shapes[name]=chosen
		else:_eye_shapes[name]=chosen
	_bind_pinned_ears(sk)


## Flustered ears (dev 2026-09-28): folded back along the skull. No source clip has this pose,
## so each ear root turns back about the head's side axis and the ear tip follows it.
const EAR_PIN_ANGLE := deg_to_rad(55.0)
func _bind_pinned_ears(sk: Skeleton3D) -> void:
	var head := sk.find_bone("mHead")
	if head < 0: return
	var side_axis: Vector3 = _rest_globals[head].basis.x.normalized()
	var back: Vector3 = -_rest_globals[head].basis.z.normalized()
	var pinned := {}
	for side in ["Left", "Right"]:
		var root := sk.find_bone("mFaceEar1" + side)
		var tip := sk.find_bone("mFaceEar2" + side)
		if root < 0 or tip < 0: continue
		var frame: Basis = _rest_globals[root].basis.orthonormalized()
		var along: Vector3 = (_rest_globals[tip].origin - _rest_globals[root].origin).normalized()
		var turn := Basis(side_axis, EAR_PIN_ANGLE)
		var other := Basis(side_axis, -EAR_PIN_ANGLE)
		if (other * along).dot(back) > (turn * along).dot(back): turn = other
		pinned[root] = Transform3D(frame.inverse() * turn * frame, Vector3.ZERO)
	if not pinned.is_empty(): _ear_shapes["ears_pinned"] = pinned


func _process_modification() -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_process_modification()
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("eye_motion", started)


func _write(sk: Skeleton3D, bone: int, pose: Transform3D) -> void:
	sk.set_bone_pose(bone, pose)
	_written[bone] = pose
