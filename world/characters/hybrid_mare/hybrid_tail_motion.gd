extends SkeletonModifier3D
## Pinned native tail with damped joints and contact constraints.
const SPRINGS := preload("res://world/characters/hybrid_mare/hybrid_tail_physics.gd")
var pony: Node3D
var springs: RefCounted
var _previous_velocity := Vector3.ZERO
var _history := false
var _skipped_delta := 0.0
var _pose:Array[Transform3D]=[]
var _read_bones:=PackedInt32Array()
var _body_ends:=PackedInt32Array()
## Tail bone poses of the last two integrations (the springs only rotate the joints; offsets and
## scales stay at rest) and the steps since the latest.
var _to: Array[Transform3D] = []
var _from_rotation: Array[Quaternion] = []
var _to_rotation: Array[Quaternion] = []
var _steps := 0
## Tail floor contacts: real rays on the solver; in the clip tiers the plane her own floor rays
## measured (six rays every 50 ms per pony were two thirds of a clip pony's rays).
var _ray_floor := Callable()
var _plane_floor := Callable()

func bind(owner_pony: Node3D) -> void:
	pony = owner_pony
	springs = SPRINGS.new()
	springs.bone_names = ["mTail1","mTail2","mTail3","mTail4","mTail5","mTail6"]
	springs.mount_name = "mPelvis"
	var identity: Resource = pony.get("identity")
	if identity != null:
		var limits: Array = []
		for deg in identity.tail_bend_limits_deg: limits.append(deg_to_rad(float(deg)))
		springs.angle_limits = limits
		springs.terminal_length = identity.tail_terminal_length
		springs.segment_radii = PackedFloat32Array(identity.tail_segment_radii)
	else:
		springs.angle_limits = [deg_to_rad(60),deg_to_rad(75),deg_to_rad(80),deg_to_rad(80),deg_to_rad(75),deg_to_rad(70)]
		springs.terminal_length = .21088 * .82
		springs.segment_radii = PackedFloat32Array([.045,.065,.085,.075,.05,.016])
	springs.bind(pony,get_skeleton())
	_ray_floor = springs.floor_probe
	if pony.has_method("clip_floor_hit"):
		_plane_floor = Callable(pony, "clip_floor_hit")
	_pose.clear();_read_bones.clear();_body_ends.clear()
	var sk:=get_skeleton()
	for i in sk.get_bone_count():_pose.append(sk.get_bone_rest(i))
	# Only the mount and its ancestors: apply_pose() rewrites every tail joint from its rest.
	for tip in springs.bones:
		var bone:int=sk.get_bone_parent(tip)
		while bone>=0:
			if bone not in _read_bones and bone not in springs.bones:_read_bones.append(bone)
			bone=sk.get_bone_parent(bone)
	for name in ["pony_hips","pony_spine3"]:_body_ends.append(pony.skeleton.find_bone(name))

const PROFILE := preload("res://tools/crowd_cpu_profile.gd")

func _process_modification_with_delta(delta: float) -> void:
	if springs == null or not is_instance_valid(pony) or not pony.is_inside_tree(): return
	if not PROFILE.enabled:
		_springs_tick(delta)
		return
	var started := Time.get_ticks_usec()
	var integrated := _springs_tick(delta)
	PROFILE.record("tail_springs", started)
	# Integration ticks alone (includes the record above, about 1.5 us); the rest only interpolate.
	if integrated: PROFILE.record("tail_springs_integrate", started)

## True when this step ran the springs pass rather than only the in-between write.
func _springs_tick(delta: float) -> bool:
	var sk := get_skeleton()
	# Integrate at the mare's own rate: hero_divisor for HERO (60/30 Hz), her 20 Hz logic beat
	# in the clip tiers (pony_locomotion.is_logic_tick). In between, the modifier writes the tail
	# interpolated between the last two integrated poses, one integration behind, since
	# Skeleton3D reverts modifier writes after skinning (dev 2026-09-25: logic at 20 Hz,
	# visuals every step).
	var near: bool = pony.get("sim_tier") == 1
	var divisor: int = pony.LOGIC_DIVISOR if near else maxi(int(pony.hero_divisor), 1)
	_skipped_delta += delta
	var integrate: bool = pony.is_logic_tick() if near else (divisor <= 1 or ((pony._tick + pony.sim_phase) % divisor) == 0)
	if not integrate and _history:
		_steps += 1
		_write_between(sk, float(_steps + 1) / divisor)
		return false
	springs.cheap_floor=true  # dev 2026-09-17: jigglebones + floor for every tier, no skin scan
	springs.contact_iterations=4
	# The body capsule feeds only the skin scan; the floor-only pass never reads it.
	if not springs.cheap_floor:
		# Read the prepared FK, not Skeleton3D's temporarily restored pre-modifier pose.
		var frame:Transform3D=pony.global_transform*pony.pivot.transform*pony._model_frame
		var body_pose:Array=pony.corrected_pose if not pony.corrected_pose.is_empty() else pony.profile.rest
		var ends:Array[Vector3]=[]
		for b in _body_ends:
			var local:Transform3D=body_pose[b]
			var parent:int=pony.profile.parents[b]
			while parent>=0:local=body_pose[parent]*local;parent=pony.profile.parents[parent]
			ends.append((frame*local).origin)
		springs.body_capsules.assign([{"a":ends[0],"b":ends[1],"radius":.11}])
	# The spring solver reads only the tail mount's ancestry; it writes the six tail joints.
	# All other hair-skeleton bones remain untouched by this modifier.
	for i in _read_bones:_pose[i]=sk.get_bone_pose(i)
	if not pony.motion_paused and integrate:
		var step := _skipped_delta
		_skipped_delta = 0.0
		var acceleration: Vector3 = (pony.velocity - _previous_velocity) / maxf(step,.001) if _history else Vector3.ZERO
		_previous_velocity = pony.velocity
		_history = true
		springs.update(step,acceleration)
	# NEAR: contact projection only on integrate ticks and with two passes instead of
	# the full budget; the weighted contact scan was 3.2 ms per tick for 16 ponies.
	var plane: bool = near and _plane_floor.is_valid()
	springs.floor_probe = _plane_floor if plane else _ray_floor
	# One plane for the whole chain: her floor plane is the same for every tip until the next ray.
	springs.floor_is_plane = plane
	springs._contact_enabled=not pony.motion_paused and (integrate or not near)
	springs.apply_pose(_pose)
	var bones: Array = springs.bones
	var fresh := _to.size() != bones.size()
	if fresh:
		_to.resize(bones.size())
		_to_rotation.resize(bones.size())
	# The previous target becomes the start; reuse the two buffers instead of copying.
	var previous := _from_rotation
	_from_rotation = _to_rotation
	_to_rotation = previous
	if _to_rotation.size() != bones.size(): _to_rotation.resize(bones.size())
	for k in bones.size():
		_to[k] = _pose[bones[k]]
		_to_rotation[k] = _to[k].basis.get_rotation_quaternion()
	if fresh:
		_from_rotation = _to_rotation.duplicate()
	_steps = 0
	_write_between(sk, 1.0 / divisor)
	return true


## Tail pose `t` of the way from the previous integration's result to the latest one.
func _write_between(sk: Skeleton3D, t: float) -> void:
	var bones: Array = springs.bones
	if t >= 1.0:
		for k in bones.size(): sk.set_bone_pose(bones[k], _to[k])
		return
	for k in bones.size():
		sk.set_bone_pose_position(bones[k], _to[k].origin)
		sk.set_bone_pose_rotation(bones[k], _from_rotation[k].slerp(_to_rotation[k], t))
