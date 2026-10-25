extends RefCounted
## Small supported weight shifts layered onto the original gait, before leg IK.

var offset := Vector3.ZERO
var roll := 0.0
var head_angles := Vector3.ZERO
var gaze_angles := Vector3.ZERO
var gaze_velocity := Vector3.ZERO
var _seconds := 0.0
var _variation := 0.0
var _strength := 0.0
var _attention := 0.0
var _neck: Array[int] = []
var _parent_frames: Array[Basis] = []
var _gaze_target := Vector3.ZERO
var _look_angles := Vector3.ZERO
var _look_time := 0.0
var _gaze_wait := 1.5
var _neck_gaze := Vector3.ZERO
var _random := RandomNumberGenerator.new()
## Standing idle body life (dev 2026-10-14: "her head moves i guess but not her body"): every few
## seconds she settles her weight a little onto one side or back toward her hind legs and holds
## it there, and her barrel rises and falls with each breath. Only while she stands still; the
## leg IK keeps every hoof planted (the body pivot moves, the soles do not), and the support
## term above fades it out on slopes or wherever the legs cannot reach. Metres for a mare of
## standard size; scaled by hip height like the sway.
const WEIGHT_SIDE := Vector2(.012, .022)
const WEIGHT_BACK := Vector2(-.010, .007)
const WEIGHT_HOLD := Vector2(4.5, 12.0)
## Breath: spine arch (radians) between the loins and the withers, and the head's nod with it.
const BREATH_ARCH := 0.012
const BREATH_HEAD := 0.012
var _weight := Vector3.ZERO
var _weight_goal := Vector3.ZERO
var _weight_wait := 3.0
var _spine: Array[int] = []
var _spine_frames: Array[Basis] = []
var breath := 0.0
## Weight shifts begun (tests, traces).
var weight_shifts := 0


func bind(skeleton: Skeleton3D) -> void:
	_neck.clear()
	_parent_frames.clear()
	# Different mares should not breathe or shift their weight in unison.
	_variation = fposmod(float(skeleton.get_instance_id()) * 0.61803398875, TAU)
	_random.seed = skeleton.get_instance_id()
	for name in ["pony_neck1", "pony_neck2", "pony_head"]:
		var index := skeleton.find_bone(name)
		if index < 0:
			continue
		_neck.append(index)
		var parent := skeleton.get_bone_parent(index)
		_parent_frames.append(skeleton.get_bone_global_rest(parent).basis.orthonormalized())
	_spine.clear()
	_spine_frames.clear()
	for name in ["pony_spine1", "pony_spine3"]:
		var index := skeleton.find_bone(name)
		if index < 0 or skeleton.get_bone_parent(index) < 0:
			_spine.clear()
			_spine_frames.clear()
			break
		_spine.append(index)
		_spine_frames.append(skeleton.get_bone_global_rest(skeleton.get_bone_parent(index)).basis.orthonormalized())
	reset()


func reset() -> void:
	offset = Vector3.ZERO
	roll = 0.0
	head_angles = Vector3.ZERO
	gaze_angles = Vector3.ZERO
	gaze_velocity = Vector3.ZERO
	_neck_gaze = Vector3.ZERO
	_gaze_target = Vector3.ZERO
	_gaze_wait = _random.randf_range(4.0, 9.0)
	_look_time = 0.0
	_look_angles = Vector3.ZERO
	_seconds = 0.0
	_strength = 0.0
	_attention = 0.0
	_weight = Vector3.ZERO
	_weight_goal = Vector3.ZERO
	_weight_wait = _random.randf_range(1.5, 6.0)
	breath = 0.0


func update(delta: float, phase: float, movement: float, support: float,
		amount: float, hip_height: float, give: Vector3, attention: float) -> void:
	_seconds += delta
	_strength = lerpf(_strength, clampf(support, 0.0, 1.0) * clampf(amount, 0.0, 1.5),
		1.0 - exp(-delta / 0.25))
	_attention = lerpf(_attention, clampf(attention, 0.0, 1.0) * minf(maxf(amount, 0.0), 1.0),
		1.0 - exp(-delta / 0.25))
	var moving := clampf(movement, 0.0, 1.0)
	var idle_phase := _seconds * TAU / 5.7 + _variation
	var breath_phase := _seconds * TAU / 4.3 + _variation
	# Idle changes are slower than a stride and gently vary in amplitude.
	var idle := sin(idle_phase) * (0.8 + 0.2 * sin(_seconds * TAU / 11.3))
	var stride := sin(TAU * phase)
	var size := hip_height / 0.586
	_update_weight(delta, moving)
	var still := 1.0 - moving
	var desired := Vector3(lerpf(idle * 0.006 + _weight.x, stride * 0.007, moving), 0.0,
		(cos(idle_phase * 0.73) * 0.0025 + _weight.z) * still) * _strength * size
	offset = offset.lerp(desired, 1.0 - exp(-delta / 0.09))
	# Roll around the hips, not the floor. No added vertical body bounce.
	roll = -offset.x / maxf(hip_height, 0.01) * 0.65
	breath = sin(breath_phase) * _strength * still
	var wanted_head := Vector3(sin(breath_phase) * lerpf(BREATH_HEAD, deg_to_rad(0.4), moving) - give.z * 0.3,
		0.0, -roll * 0.65 + give.x * 0.35 * _strength)
	wanted_head.x *= _strength
	wanted_head.y *= _strength
	# The neck follows with a delay, softening the body's changes of direction.
	head_angles = head_angles.lerp(wanted_head, 1.0 - exp(-delta / 0.18))
	_update_gaze(delta, moving)


## The standing weight: a new lean every WEIGHT_HOLD seconds (now and then square again), eased in
## over about a second. Walking takes her back to the stride's own sway at once.
func _update_weight(delta: float, moving: float) -> void:
	if moving > 0.05:
		_weight_goal = Vector3.ZERO
		_weight_wait = maxf(_weight_wait, _random.randf_range(1.5, 4.0))
	else:
		_weight_wait -= delta
		if _weight_wait <= 0.0:
			shift_weight()
	_weight = _weight.lerp(_weight_goal, 1.0 - exp(-delta / 0.55))


## Settle onto the other side now (also the idle fidget picker's "shift"); a quarter of the
## time she squares up instead.
func shift_weight() -> void:
	_weight_wait = _random.randf_range(WEIGHT_HOLD.x, WEIGHT_HOLD.y)
	if _random.randf() < .25 and _weight_goal != Vector3.ZERO:
		_weight_goal = Vector3.ZERO
		return
	var side := -signf(_weight_goal.x) if _weight_goal.x != 0.0 else (-1.0 if _random.randf() < .5 else 1.0)
	_weight_goal = Vector3(side * _random.randf_range(WEIGHT_SIDE.x, WEIGHT_SIDE.y), 0.0,
		_random.randf_range(WEIGHT_BACK.x, WEIGHT_BACK.y))
	weight_shifts += 1


## A directed look (head-frame pitch/yaw radians) that overrides the random
## glances for `duration` seconds; the navigator uses it for the player.
func is_looking() -> bool:
	return _look_time > 0.0


func look_toward(angles: Vector3, duration: float) -> void:
	_look_angles = angles
	_look_time = duration


func _update_gaze(delta: float, moving: float) -> void:
	_gaze_wait -= delta
	if _look_time > 0.0:
		_look_time -= delta
		_gaze_target = _look_angles
		_gaze_wait = maxf(_gaze_wait, 0.6)
	elif _gaze_wait <= 0.0:
		# Look, settle, hold; some looks return forward. No continuous sweep.
		var forward := _random.randf() < 0.65
		_gaze_target = Vector3.ZERO if forward else Vector3(
			deg_to_rad(_random.randf_range(-5.0, 7.0)),
			deg_to_rad(_random.randf_range(5.0, 14.0)) * (-1.0 if _random.randf() < 0.5 else 1.0),
			deg_to_rad(_random.randf_range(-2.0, 2.0)))
		_gaze_wait = _random.randf_range(7.0, 16.0)
	var target := _gaze_target * _attention * lerpf(1.0, 0.35, moving)
	# Acceleration and angular speed limits keep even a reversed glance
	# continuous. The near-critical spring starts firmly and settles softly.
	var steps := maxi(1, ceili(delta * 120.0))
	var dt := delta / steps
	for step in steps:
		var acceleration := ((target - gaze_angles) * 100.0 - gaze_velocity * 19.0).limit_length(deg_to_rad(360.0))
		gaze_velocity = (gaze_velocity + acceleration * dt).limit_length(deg_to_rad(80.0))
		gaze_angles += gaze_velocity * dt
		_neck_gaze = _neck_gaze.lerp(gaze_angles, 1.0 - exp(-dt / 0.085))


## Narrow the head: a scale along the model's side axis, applied to the head
## bone's local basis after the pose, so everything skinned to the head (mane,
## eyes, lashes) narrows with it (dev, 2026-09-07: "make her head less wide").
var _head_width := 1.0
var _head_side_axis := Vector3.RIGHT


func set_head_width(skeleton: Skeleton3D, width: float) -> void:
	_head_width = width
	if _neck.size() >= 3:
		var rest := skeleton.get_bone_global_rest(_neck[2]).basis
		_head_side_axis = (rest.inverse() * Vector3.RIGHT).normalized()


func apply_pose(pose: Array[Transform3D], limits: RefCounted) -> void:
	# Breath: the loins lift the back a hair and the withers level it again, so the barrel
	# between them rises and falls; rotations only, inside the spine's limits.
	if _spine.size() == 2 and absf(breath) > 0.0005:
		for i in 2:
			var bone := _spine[i]
			var frame := _spine_frames[i]
			var pitch := BREATH_ARCH * breath * (1.0 if i == 0 else -1.0)
			pose[bone].basis = limits.constrain(bone, frame.inverse() * Basis(Vector3.RIGHT, pitch) * frame * pose[bone].basis)
	for i in _neck.size():
		var bone := _neck[i]
		var parent := _parent_frames[i]
		var share := 0.3 if i == 2 else 0.35
		# Head leads; the two neck joints share the follow-through. Their sum
		# converges on the requested angle without rotating any bone twice.
		var gaze := gaze_angles - _neck_gaze * 0.55 if i == 2 else _neck_gaze * 0.275
		var additive := parent.inverse() * Basis.from_euler(head_angles * share + gaze) * parent
		pose[bone].basis = limits.constrain(bone, additive * pose[bone].basis)
		if i == 2 and _head_width != 1.0:
			var k := _head_width - 1.0
			var a := _head_side_axis
			var squeeze := Basis(
				Vector3(1.0 + k * a.x * a.x, k * a.x * a.y, k * a.x * a.z),
				Vector3(k * a.y * a.x, 1.0 + k * a.y * a.y, k * a.y * a.z),
				Vector3(k * a.z * a.x, k * a.z * a.y, 1.0 + k * a.z * a.z))
			pose[bone].basis = pose[bone].basis * squeeze


## A bounded additive head layer on native rest clips. Never rewrites limb poses,
## joint translations or the authored resting neck's baseline rotation.
func apply_rest_gaze(pose: Array[Transform3D]) -> void:
	for i in _neck.size():
		var parent := _parent_frames[i]
		var gaze := gaze_angles - _neck_gaze * .55 if i == 2 else _neck_gaze * .275
		gaze = gaze.limit_length(deg_to_rad(50))
		pose[_neck[i]].basis = parent.inverse() * Basis.from_euler(gaze) * parent * pose[_neck[i]].basis


## Geometry eyelids (round 9): each socket rim carries two arcs of short
## bones under pony_head, pony_lid_{upper,lower}_{L,R}_{00..16}. Column i of the
## upper arc sits over column i of the lower arc; 00 and 16 are the shared
## corners. Closing slides each upper bone down its column toward the lower
## bone's rest and lifts the lower bone a share of the way up.
const LID_COLUMNS := 17
var _lid_upper: Dictionary = {}  # side ("L"/"R") -> Array[int]
var _lid_lower: Dictionary = {}
var _lid_rest: Dictionary = {}  # bone index -> rest local origin


func bind_lids(skeleton: Skeleton3D) -> void:
	_lid_upper.clear()
	_lid_lower.clear()
	_lid_rest.clear()
	for side in ["L", "R"]:
		var upper: Array[int] = []
		var lower: Array[int] = []
		for i in LID_COLUMNS:
			var u := skeleton.find_bone("pony_lid_upper_%s_%02d" % [side, i])
			var l := skeleton.find_bone("pony_lid_lower_%s_%02d" % [side, i])
			if u < 0 or l < 0:
				upper.clear()
				lower.clear()
				break
			upper.append(u)
			lower.append(l)
			_lid_rest[u] = skeleton.get_bone_rest(u).origin
			_lid_rest[l] = skeleton.get_bone_rest(l).origin
		if not upper.is_empty():
			_lid_upper[side] = upper
			_lid_lower[side] = lower


func has_lids() -> bool:
	return not _lid_upper.is_empty()


func lid_bones(side: String, upper: bool) -> Array[int]:
	var arcs: Dictionary = _lid_upper if upper else _lid_lower
	var found: Array[int] = []
	if arcs.has(side):
		found = arcs[side]
	return found


func lid_rest_origin(bone: int) -> Vector3:
	return _lid_rest.get(bone, Vector3.ZERO)


## `pose` is the local pose list indexed by bone (the same array apply_pose
## takes). Corners (00 and 16) stay put.
func apply_lids(pose: Array[Transform3D], closure: float, lower_share: float = 0.3) -> void:
	if _lid_upper.is_empty():
		return
	var c := clampf(closure, 0.0, 1.0)
	for side in _lid_upper:
		var upper: Array[int] = _lid_upper[side]
		var lower: Array[int] = _lid_lower[side]
		for i in upper.size():
			if i == 0 or i == upper.size() - 1:
				continue
			var u: int = upper[i]
			var l: int = lower[i]
			var rest_u: Vector3 = _lid_rest[u]
			var rest_l: Vector3 = _lid_rest[l]
			pose[u].origin = rest_u + (rest_l - rest_u) * c
			pose[l].origin = rest_l + (rest_u - rest_l) * c * lower_share
