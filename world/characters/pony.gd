extends CharacterBody3D
## A pony that lives in the world: pathfinds, wanders, notices you, and can be
## petted, picked up and carried.
##
## Built in code rather than as a .tscn so the whole character -- collision,
## nav agent, gaze rig, interaction areas -- is described in one readable place
## and can be dropped onto any pony model by path.
##
## Animation is deliberately absent from this file. The source model ships a full pony
## locomotion set (filly_idle, filly_trot, filly_gallop, sit, lay, sleep, boop)
## on a different skeleton, and retargeting it is its own problem. Behaviour is
## built first so that when the clips land they only have to be driven, not
## designed around. Gaze is the exception -- head tracking has to be procedural
## no matter what clips exist, because it follows a target that moves.

enum State { IDLE, WANDER, APPROACH, FOLLOW, HELD }

@export var model_scene: PackedScene
@export_group("Movement")
@export var walk_speed := 1.4
@export var trot_speed := 3.0
@export var turn_speed := 6.0
@export var arrive_distance := 0.6
@export_group("Awareness")
## Beyond this she ignores you entirely.
@export var notice_radius := 14.0
## Inside this she stops advancing -- ponies are not meant to stand in your face.
@export var personal_space := 1.6
## How long she will hold eye contact before losing interest.
@export var attention_span := 7.0
@export_group("Wander")
@export var wander_radius := 22.0
@export var idle_min := 2.5
@export var idle_max := 8.0

var state: State = State.IDLE
var player: Node3D

var skeleton: Skeleton3D
var model: Node3D
var _agent: NavigationAgent3D
var _gaze: LookAtModifier3D
var _gaze_target: Node3D

var _state_timer := 0.0
var _attention := 0.0
var _goal := Vector3.ZERO
var _home := Vector3.ZERO
var _home_set := false
@export var debug_motion := false
var _debug_accum := 0.0
var _debug_last := Vector3.ZERO
var _slaved_skeletons: Array[Skeleton3D] = []
## [slave_skeleton, slave_bone_idx, body_bone_idx] triples, resolved once by name.
var _bone_links: Array = []
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

signal petted(part: String)
signal picked_up
signal dropped


func _ready() -> void:
	_build_body()
	_build_model()
	_build_agent()
	_build_gaze()
	_enter(State.IDLE)


func _build_body() -> void:
	# Upright capsule, despite a pony being long and low. A capsule laid on its
	# side has a *line* of ground contact rather than a point, so is_on_floor()
	# flickers frame to frame on triangle-mesh terrain -- she alternated falling
	# and landing and vibrated in place. Body-shaped collision is not worth that;
	# her nose and tail clipping slightly is invisible next to the jitter.
	var shape := CapsuleShape3D.new()
	shape.radius = 0.36
	shape.height = 1.05
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = shape.height * 0.5
	col.name = "Body"
	add_child(col)

	# Keeps her glued to sloped ground instead of launching off every rise.
	floor_snap_length = 0.5
	floor_max_angle = deg_to_rad(55.0)


func _build_model() -> void:
	if model_scene == null:
		push_error("[pony] no model_scene set")
		return
	model = model_scene.instantiate()
	add_child(model)

	var skeletons := _find_skeletons(model)
	skeletons.sort_custom(func(a, b): return a.get_bone_count() > b.get_bone_count())
	if skeletons.is_empty():
		push_warning("[pony] no Skeleton3D in model; gaze disabled")
		return
	skeleton = skeletons[0]

	# The mane and tail are skinned to a *second*, separate skeleton (the
	# author's jiggle rig). In Blender its bones are constrained to the body
	# rig, but glTF carries no constraints -- so the hair simply ignored the
	# head and stayed put while the neck moved. Bones shared by name are copied
	# across each frame, which is the constraint the export dropped.
	for extra in skeletons.slice(1):
		_slaved_skeletons.append(extra)
		var pairs := 0
		for i in extra.get_bone_count():
			var src := skeleton.find_bone(extra.get_bone_name(i))
			if src >= 0:
				_bone_links.append([extra, i, src])
				pairs += 1
		print("[pony] slaved '%s' (%d bones, %d matched to body rig)" % [
			extra.name, extra.get_bone_count(), pairs])


func _build_agent() -> void:
	_agent = NavigationAgent3D.new()
	_agent.radius = 0.45
	_agent.height = 1.5
	_agent.path_desired_distance = 0.5
	_agent.target_desired_distance = arrive_distance
	# Avoidance off for now: with a single pony there is nothing to avoid, and
	# it fights the arrival logic by nudging her off the final approach.
	_agent.avoidance_enabled = false
	add_child(_agent)


## Head tracking via Godot's built-in LookAtModifier3D rather than hand-rolled
## bone maths -- it already handles the smoothing, angle limits and the
## "which axis is forward" problem that makes this fiddly on a quadruped.
func _build_gaze() -> void:
	if skeleton == null:
		return
	var head := _find_bone(["DEF_Head", "Head", "head"])
	if head == "":
		push_warning("[pony] no head bone found; gaze disabled")
		return

	_gaze_target = Node3D.new()
	_gaze_target.name = "GazeTarget"
	add_child(_gaze_target)

	_gaze = LookAtModifier3D.new()
	_gaze.name = "Gaze"
	_gaze.bone_name = head
	# In a Blender rig +Y runs along the bone's *length* -- for a head bone that
	# is neck-to-crown, i.e. roughly upward, not the direction she faces.
	# Declaring it as forward made every "look" come out as a nod. The muzzle
	# points down the bone's -Z, so that is the real forward axis.
	_gaze.forward_axis = SkeletonModifier3D.BONE_AXIS_MINUS_Z
	_gaze.primary_rotation_axis = Vector3.AXIS_Y
	_gaze.use_secondary_rotation = true
	# Limits keep her from owl-necking when the player walks behind her.
	_gaze.symmetry_limitation = false
	_gaze.primary_limit_angle = deg_to_rad(60.0)
	_gaze.secondary_limit_angle = deg_to_rad(28.0)
	_gaze.influence = 0.0
	# Parented before target_node is set: get_path_to needs both nodes already
	# in the tree, and calling it first fails with "common_parent is null" --
	# which left gaze silently disabled.
	skeleton.add_child(_gaze)
	_gaze.target_node = _gaze.get_path_to(_gaze_target)
	print("[pony] gaze bound to bone '%s' (%d bones in rig)" % [
		head, skeleton.get_bone_count()])


func _physics_process(delta: float) -> void:
	# Home is captured on the first physics tick, not in _ready(): the spawner
	# adds the node (running _ready) and only then sets its position, so reading
	# it early records the origin and she spends her life walking toward world
	# zero. Waiting also gives the navigation map a frame to come up.
	if not _home_set:
		_home = global_position
		_home_set = true
		return

	if state == State.HELD:
		return

	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0.0

	_update_awareness(delta)
	_state_timer -= delta

	match state:
		State.IDLE:
			_stop(delta)
			if _state_timer <= 0.0:
				_enter(State.WANDER)
		State.WANDER:
			_move_along_path(delta, walk_speed)
			# Arrival is measured by distance to the goal, not by
			# is_navigation_finished(). That returns true until the agent has
			# processed a newly-set target, so checking it on the frame after
			# _enter() ends the walk before it starts -- she took two steps and
			# stopped, every time.
			if _flat_distance(_goal) <= arrive_distance or _state_timer <= 0.0:
				_enter(State.IDLE)
		State.APPROACH:
			if _player_distance() <= personal_space:
				_stop(delta)
				_face(player.global_position, delta)
			else:
				_agent.target_position = player.global_position
				_move_along_path(delta, trot_speed)
		State.FOLLOW:
			if _player_distance() <= personal_space * 1.6:
				_stop(delta)
				_face(player.global_position, delta)
			else:
				_agent.target_position = player.global_position
				_move_along_path(delta, trot_speed)

	move_and_slide()
	_sync_slaved_skeletons()

	if debug_motion:
		_debug_accum += delta
		if _debug_accum >= 1.0:
			_debug_accum = 0.0
			var moved := global_position.distance_to(_debug_last)
			_debug_last = global_position
			var nxt := _agent.get_next_path_position()
			var blocker := "-"
			if get_slide_collision_count() > 0:
				var c := get_slide_collision(0)
				var o = c.get_collider()
				if o != null:
					blocker = str(o.name)
			print("[pony] %s %s moved %.2f  vel=%.2f  nextpt=%.2f m  goal=%.1f m  reached=%s  hit=%s" % [
				name, State.keys()[state], moved,
				Vector2(velocity.x, velocity.z).length(),
				Vector2(nxt.x - global_position.x, nxt.z - global_position.z).length(),
				_flat_distance(_goal), _agent.is_navigation_finished(), blocker])


## Gaze influence eases rather than snapping, so noticing you reads as a look
## rather than a twitch.
func _update_awareness(delta: float) -> void:
	if player == null or _gaze == null:
		return
	var dist := _player_distance()
	var aware := dist <= notice_radius

	if aware:
		_attention = attention_span
	else:
		_attention = maxf(0.0, _attention - delta)

	if _gaze_target != null and player != null:
		# Aim at the player's head, not their feet.
		_gaze_target.global_position = player.global_position + Vector3.UP * 1.0

	var want: float = 1.0 if (_attention > 0.0 and state != State.WANDER) else 0.0
	_gaze.influence = move_toward(_gaze.influence, want, delta * 2.0)


func _move_along_path(delta: float, speed: float) -> void:
	var next := _agent.get_next_path_position()
	var to_next := next - global_position
	to_next.y = 0.0
	# Deadzone: when the next path point is nearly underfoot, the direction it
	# implies flips wildly frame to frame, which reads as twitching.
	if to_next.length() < 0.2:
		_stop(delta)
		return
	var dir := to_next.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	_face(global_position + dir, delta)


func _stop(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)


func _face(target: Vector3, delta: float) -> void:
	var flat := target - global_position
	flat.y = 0.0
	if flat.length_squared() < 0.0001:
		return
	var want := atan2(flat.x, flat.z)
	rotation.y = lerp_angle(rotation.y, want, minf(1.0, turn_speed * delta))


## Copies body-rig bone poses onto the mane/tail jiggle skeleton, standing in
## for the Blender constraints glTF discards. Without it the hair is welded to
## the model root and stays put while the head moves.
func _sync_slaved_skeletons() -> void:
	for link in _bone_links:
		var slave: Skeleton3D = link[0]
		slave.set_bone_global_pose(link[1], skeleton.get_bone_global_pose(link[2]))


## Horizontal distance only -- terrain height differences must not make her
## think she has arrived, or fail to.
func _flat_distance(to: Vector3) -> float:
	return Vector2(global_position.x - to.x, global_position.z - to.z).length()


func _player_distance() -> float:
	return INF if player == null else global_position.distance_to(player.global_position)


func _enter(next: State) -> void:
	if next != state:
		print("[pony] %s: %s -> %s  at %s" % [
			name, State.keys()[state], State.keys()[next], global_position.round()])
	state = next
	match next:
		State.IDLE:
			_state_timer = randf_range(idle_min, idle_max)
		State.WANDER:
			_state_timer = 20.0
			_goal = _pick_wander_point()
			_agent.target_position = _goal
			if debug_motion:
				# The straight-line distance to a goal says nothing about whether
				# it is reachable. Asking for the path shows how far the navmesh
				# actually carries her, which is how a fragmented mesh shows up.
				var p := NavigationServer3D.map_get_path(
					get_world_3d().navigation_map, global_position, _goal, true)
				var endpt: Vector3 = _goal if p.is_empty() else p[p.size() - 1]
				var reach := Vector2(endpt.x - _goal.x, endpt.z - _goal.z).length()
				print("[pony]   wander goal %s (%.1f m away) path=%d pts, ends %.1f m from goal" % [
					_goal.round(), _flat_distance(_goal), p.size(), reach])
		State.APPROACH, State.FOLLOW:
			_state_timer = 999.0


## Wander targets are picked around her home rather than her current position,
## so she drifts around a neighbourhood instead of random-walking out of town.
func _pick_wander_point() -> Vector3:
	var map := get_world_3d().navigation_map
	for i in 8:
		var angle := randf() * TAU
		# sqrt() keeps destinations spread evenly across the disc instead of
		# clustering them near the centre.
		var dist := sqrt(randf()) * wander_radius
		var candidate := _home + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
		var point := NavigationServer3D.map_get_closest_point(map, candidate)
		if point.distance_to(candidate) < 4.0:
			return point
	# Falling back to _home would be wrong if _home itself is unreachable;
	# standing still is the honest failure.
	return global_position


# --- Interaction (M3) -----------------------------------------------------

func follow(who: Node3D) -> void:
	player = who
	_enter(State.FOLLOW)


func stay() -> void:
	_enter(State.IDLE)


func approach(who: Node3D) -> void:
	player = who
	_enter(State.APPROACH)


## Called by whatever touched her, with the body part name. The reaction itself
## is left to listeners so the same touch can drive animation, sound and
## affinity separately.
func pet(part: String) -> void:
	_attention = attention_span
	petted.emit(part)


func pick_up(holder: Node3D) -> void:
	if state == State.HELD:
		return
	state = State.HELD
	velocity = Vector3.ZERO
	var xform := global_transform
	get_parent().remove_child(self)
	holder.add_child(self)
	global_transform = xform
	picked_up.emit()


func drop(at: Vector3, world_parent: Node) -> void:
	if state != State.HELD:
		return
	var holder := get_parent()
	if holder != null:
		holder.remove_child(self)
	world_parent.add_child(self)
	global_position = at
	rotation = Vector3(0.0, rotation.y, 0.0)
	_home = at
	_enter(State.IDLE)
	dropped.emit()


# --- Helpers --------------------------------------------------------------

## The model carries two skeletons -- the body rig (87 bones) and a separate
## mane/tail physics rig (36). Depth-first "first one found" picked the physics
## rig, so gaze was driving hair bones and the body never moved. Choose the one
## with the most bones: the body rig is always the larger by a wide margin.
func _find_skeletons(node: Node) -> Array[Skeleton3D]:
	var found: Array[Skeleton3D] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is Skeleton3D:
			found.append(n as Skeleton3D)
	return found


func _find_bone(candidates: Array) -> String:
	for name in candidates:
		if skeleton.find_bone(str(name)) >= 0:
			return str(name)
	return ""
