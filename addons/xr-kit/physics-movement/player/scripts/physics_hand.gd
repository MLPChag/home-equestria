extends RigidBody3D

const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
const HAND_POSE_FILTER := preload("res://player/hand_pose_filter.gd")

signal grabbed(object: Node3D, collision_normal: Vector3)
signal dropped_held_object(object: Node3D)
signal hand_reset(hand: Node3D)
signal trigger_haptic(type: String)
signal controller_hand_reset_animation(reset: bool)

@export_group("Variables")
@export_enum("Left", "Right") var hand: String = "Left"
## Filters only the motor target. Physics, colliders, visible hands and grabs
## retain the same rigid-body transform; raw XR tracking remains untouched.
@export var hand_smoothing := true

@export_group("Nodes")
@export var tracker: XRNode3D
@export var controller: XRNode3D
@export var hand_tracker: XRNode3D
# @export var animation_tree: AnimationTree
@export var skeleton: Skeleton3D # Physics hand skeleton node
@export var hand_modifier: XRHandModifier3D # Manages hand poses from OpenXR
@export var grab_joint: Generic6DOFJoint3D # Joint is holding objects
@export var grab_area: ShapeCast3D # Collision detection for grab

# PID controller default values are tuned for subjective feeling of realistic hand physics
# These values have biggest influence on how hand feels and behaves
@export_group("PID Controller Linear")
@export var Kp_linear: float = 800
@export var Ki_linear: float = 0
@export var Kd_linear: float = 80
@export var proportional_limit_linear: float = INF
@export var integral_limit_linear: float = INF
@export var derivative_limit_linear: float = INF

@export_group("PID Controller Angular")
@export var Kp_angular: float = 5
@export var Ki_angular: float = 0
@export var Kd_angular: float = 1
@export var proportional_limit_angular: float = INF
@export var integral_limit_angular: float = INF
@export var derivative_limit_angular: float = INF

var pid_controller_linear: PIDController
var pid_controller_angular: PIDController
var controller_hand_mesh_material: Material
var held_object: PhysicsBody3D = null
var trigger_pressed: bool
var physics_pivot_point: Node3D
var thruster_forward: bool
var thruster_backward: bool
var reset_transform := Transform3D.IDENTITY
var resetting_hand := false
# Home: Equestria patch: start in controller mode. The rig points `tracker` at
# the controller and hand tracking is disabled project-wide, so hand-pose
# grabbing must never trigger before the first tracking_changed signal.
var is_controller_tracking: bool = true
var colliding_object: Object  # PhysicsBody3D, StaticBody3D or Terrain3D (a Node3D, not a CollisionObject3D)
var collision_normal: Vector3
var touch_transforms: Dictionary
var collider_transforms: Dictionary
var ik_colliders: Dictionary
var motor_target := Transform3D.IDENTITY
var _pose_filter := HAND_POSE_FILTER.new()
var _had_tracking := false
var _automatic_reset := false


func _ready() -> void:
	# Colliders are stored in Skeleton's BoneAttachment3D nodes, but they need to be moved to RigidBody as direct children to work
	# We save collider transforms relative to bone in Dictionary collider_transforms, rename them and move to RigidBody
	# This data will be used to position colliders on every physics frame in process_bone() function
	for bone_attachment: BoneAttachment3D in skeleton.get_children().filter(func(node): return node is BoneAttachment3D):
		var bone_id: int = skeleton.find_bone(bone_attachment.get_name())

		# If skeleton bone does not belong to hand, ignore it
		if bone_id not in hand_modifier.bone_ids:
			continue

		collider_transforms[bone_id] = {}
		for collision_shape: CollisionShape3D in bone_attachment.get_children().filter(func(node): return node is CollisionShape3D):
			var new_name: String = str(bone_id) + "_" + collision_shape.get_name()
			collision_shape.set_name(new_name)
			collider_transforms[bone_id][new_name] = collision_shape.transform
			collision_shape.reparent(self, false)

	pid_controller_linear = PIDController.new({
		Kp = Kp_linear,
		Ki = Ki_linear,
		Kd = Kd_linear,
		proportional_limit = proportional_limit_linear,
		integral_limit = integral_limit_linear,
		derivative_limit = derivative_limit_linear
	})
	pid_controller_angular = PIDController.new({
		Kp = Kp_angular,
		Ki = Ki_angular,
		Kd = Kd_angular,
		proportional_limit = proportional_limit_angular,
		integral_limit = integral_limit_angular,
		derivative_limit = derivative_limit_angular
	})
	# Minimal inertia is required for controllable hand rotation
	set_inertia(Vector3(0.01, 0.01, 0.01))
	motor_target = global_transform
	_pose_filter.reset(motor_target, XRServer.world_scale)
	_pose_filter.invalidate()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	# Save latest collision object and collision normal
	if state.get_contact_count() > 0:
		colliding_object = state.get_contact_collider_object(0)
		collision_normal = state.get_contact_local_normal(0)
	else:
		colliding_object = null
		collision_normal = Vector3.ZERO
	# ponytail: hands only give the mare a nudge; real displacement needs the locomotion controller to accept a push velocity.
	# Hands push ponies (the body never does): hand speed into the contact becomes a
	# small body give on the mare, capped by her own apply_body_impulse.
	for i in state.get_contact_count():
		var other: Object = state.get_contact_collider_object(i)
		if other == null or not other.has_method("apply_body_impulse"): continue
		var into := -state.get_contact_local_normal(i)
		into.y = 0.0
		if into.length_squared() < 0.25: continue
		var speed := linear_velocity.dot(into.normalized())
		if speed > 0.2: other.apply_body_impulse(into.normalized() * speed * 0.05)


func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(delta)
	if started > 0: CPU_PROFILE.record("physics_hands", started)

func _physics_step(delta: float) -> void:
	# Use this frame's finger colliders when checking a pending recovery.
	for bone_id in skeleton.get_bone_count():
		process_bone(bone_id)

	# If reset hand was called, we teleport physics hand to reset transform
	if resetting_hand:
		# An obstacle may have moved since automatic recovery was scheduled.
		# Explicit locomotion/recenter resets intentionally retain teleport semantics.
		if not _automatic_reset or (tracker != null and tracker.get_has_tracking_data() \
				and _reset_path_is_clear(reset_transform)):
			set_global_transform(reset_transform)
			linear_velocity = Vector3.ZERO
			angular_velocity = Vector3.ZERO
			_reset_motor_history()
		# Reset values to default
		reset_transform = Transform3D.IDENTITY
		resetting_hand = false
		_automatic_reset = false

	_update_motor_target(delta)

	# Physics hand can be bugged or stuck and we need it to be able to reset itself automatically
	# If physics hand is too far away from target (>0.3m), we reset it back to target position
	var distance_to_target: Vector3 = motor_target.origin - global_transform.origin
	if _had_tracking and distance_to_target.length_squared() > 0.09:
		reset_hand(true)

	# If holding and controller hand is rotated over 160 degrees from physics hand, drop held object
	if held_object:
		var angle = motor_target.basis.get_rotation_quaternion().normalized().angle_to(global_transform.basis.get_rotation_quaternion().normalized())
		
		if abs(angle) > deg_to_rad(160):
			drop_held_object(true)

	move(delta)


func process_bone(bone_id: int) -> void:
	# Update colliders
	var collider_names = collider_transforms.get(bone_id)
	if collider_names:
		for collider_name in collider_names.keys():
			var collider = get_node(collider_name)

			# SIMPLE OPTION FOR MANUAL COLLIDERS ADDED TO BONEATTACHMENT NODES
			# Move collider to bone position
			collider.transform = skeleton.poses.get(bone_id, Transform3D.IDENTITY) * collider_transforms[bone_id][collider_name]

			# COMPLEX OPTION FOR AUTOGENERATED COLLIDERS FROM MESHES
			# This places colliders on correct rest pose (collider is at rest bone), but they dont move with bones
			# collider.transform = skeleton.get_bone_global_pose(0).translated(-skeleton.get_bone_pose(20).origin)


func move(delta: float) -> Vector3:
	var linear_acceleration: Vector3 = pid_controller_linear.calculate(motor_target.origin, global_transform.origin, delta)
	var angular_acceleration: Vector3 = pid_controller_angular.calculate((motor_target.basis * global_transform.basis.inverse()).get_euler(), Vector3.ZERO, delta)

	if controller.free_rotation and held_object:
		return Vector3.ZERO

	# We can set velocities directly or apply forces to RigidBody. Both methods can be used with PID controller, but velocities are much easier to work with as they do not overshoot or oscillate and only Kp needs to be adjusted (Ki and Kd are left at 0). On the other hand (hehe), applying forces results in natural movement where hand is pushing with proper force (ex. push has smaller effect on heavier bodies), pushback is reliably applied when hand is pushing against something and hand rotation is affected by collisions
	# To sum up: use velocities for arcade/simple hand behavior and forces if you want realistic physics
	# set_linear_velocity(linear_acceleration)
	# set_angular_velocity(angular_acceleration)
	apply_central_force(linear_acceleration)
	apply_torque(angular_acceleration)

	return linear_acceleration


func _update_motor_target(delta: float) -> void:
	var tracked := tracker != null and tracker.get_has_tracking_data()
	if not tracked:
		# Do not chase an invalid hand tracker at the origin or throw a held
		# object when the controller is briefly occluded. Hold the last target.
		_pose_filter.invalidate()
		if _had_tracking:
			_reset_motor_history()
		_had_tracking = false
		return
	var raw := tracker.global_transform
	motor_target = _pose_filter.sample(raw, delta, XRServer.world_scale) if hand_smoothing \
		else _pose_filter.reset(raw, XRServer.world_scale)
	if not _had_tracking or _pose_filter.was_reset and hand_smoothing:
		_reset_motor_history()
	_had_tracking = true


func _reset_motor_history() -> void:
	# A new tracking frame/reset must not become a derivative impulse.
	pid_controller_linear.reset(motor_target.origin - global_position)
	pid_controller_angular.reset((motor_target.basis * global_basis.inverse()).get_euler())


func _reset_path_is_clear(target: Transform3D) -> bool:
	# A centre ray misses walls caught by fingers or the edge of the palm.
	# Enclose every enabled collider in a sphere, so translation and any hand
	# rotation are safe. This conservative check runs only for rare recoveries.
	if colliding_object != null or held_object != null or not target.is_finite():
		return false
	# Rigid bodies should have conformal bases. Refuse recovery if that invariant
	# is broken instead of underestimating a sheared or nonuniformly scaled hand.
	if not global_basis.is_conformal() or not target.basis.is_conformal():
		return false
	var radius := 0.0
	for child in get_children():
		if not child is CollisionShape3D or child.disabled or child.shape == null:
			continue
		var bounds: AABB = child.shape.get_debug_mesh().get_aabb()
		for corner in 8:
			radius = maxf(radius, (child.transform * bounds.get_endpoint(corner)).length())
	if radius <= 0.0:
		return false
	radius *= maxf(global_basis.x.length(), target.basis.x.length())
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.collision_mask = collision_mask
	var excluded: Array[RID] = [get_rid()]
	for body in get_collision_exceptions():
		if is_instance_valid(body):
			excluded.append(body.get_rid())
	query.exclude = excluded
	query.transform = Transform3D(Basis.IDENTITY, global_position)
	var space := get_world_3d().direct_space_state
	# cast_motion ignores shapes already overlapping; check both endpoints too.
	if not space.intersect_shape(query, 1).is_empty():
		return false
	query.motion = target.origin - global_position
	var sweep := space.cast_motion(query)
	if sweep.size() != 2 or sweep[0] < 1.0:
		return false
	query.motion = Vector3.ZERO
	query.transform.origin = target.origin
	return space.intersect_shape(query, 1).is_empty()


func grab() -> Node3D:
	if get_meta("inventory_busy",false):return null
	if held_object:
		return held_object

	# TODO: Highlight object which will be grabbed when hand is close to it
	# TODO: highlight color based on object mass
	# TODO: Select object closest to grab_area center (or palm)
	grab_area.force_shapecast_update()
	if grab_area.is_colliding():
		# Get object we just grabbed
		var candidate = grab_area.get_collider(0)
		# Terrain3D supplies physics RIDs but is not a PhysicsBody3D node.
		if not candidate is PhysicsBody3D:
			return null
		held_object = candidate
		# Snap hand to object when grabbed
		var grip_pose = skeleton.get_node(hand + "Hand/GripPose")
		global_transform = global_transform.translated(grab_area.get_collision_point(0) - grip_pose.global_transform.origin)
		
		# Rotate hand so wrist matches collision normal
		global_transform.basis = Basis.looking_at(grab_area.get_collision_normal(0), (skeleton.global_transform * skeleton.get_bone_global_pose(0)).basis.y) * skeleton.get_bone_global_pose(0).basis.inverse()
		
		# Physics pivot point attaches to Physics Hand and rotates with it
		# TODO: If other hand is holding an object with free rotation, do not update pivot point
		physics_pivot_point = Node3D.new()
		add_child(physics_pivot_point)

		# Move grab joint to physics hand position (pivot point) and rotate into collision normal, so disabling angular limit below will always result in correct rotation angle
		grab_joint.global_transform = Transform3D(Basis.looking_at(grab_area.get_collision_normal(0), (skeleton.global_transform * skeleton.get_bone_global_pose(0)).basis.y), global_transform.origin)
		
		# Set joint between hand and grabbed object
		grab_joint.set_node_a(get_path())
		grab_joint.set_node_b(held_object.get_path())

		# If holding a static object, we let physical hand rotate freely on the surface of the object
		if held_object.is_class("StaticBody3D"):
			grab_joint.set_flag_z(grab_joint.FLAG_ENABLE_ANGULAR_LIMIT, false)

		if held_object.is_class("RigidBody3D"):
			grab_joint.set_flag_z(grab_joint.FLAG_ENABLE_ANGULAR_LIMIT, true)
			held_object.set_angular_damp(1) # Reduce rotational forces to make holding more natural
			var center_of_mass = physics_pivot_point.global_transform.origin - held_object.global_transform.origin
			held_object.set_center_of_mass_mode(1) # Enable custom center of mass
			held_object.set_center_of_mass(center_of_mass)

		# TODO: Check how it works after collider has been moved under Body node
		held_object.set_collision_layer_value(12, true) # Held objects are in layer 12 to filter out collisions with player head

		grabbed.emit(held_object, grab_area.get_collision_normal(0))

		return held_object
	else:
		return null


func drop_held_object(haptic: bool = false) -> void:
	if held_object:
		grab_joint.set_node_a("")
		grab_joint.set_node_b("")
		held_object.set_collision_layer_value(12, false)

		if held_object.is_class("RigidBody3D"):
			held_object.set_angular_damp(0)
			held_object.set_center_of_mass_mode(0)

		dropped_held_object.emit(held_object)

		held_object = null
		physics_pivot_point.free()
		skeleton.set_show_rest_only(false)
		var ik_nodes: Array[Node] = skeleton.get_children().filter(func(node): return node is SkeletonIK3D)
		for ik_node in ik_nodes:
			ik_node.stop()

		if haptic:
			trigger_haptic.emit("drop_held_object")


func reset_hand(automatic: bool = false) -> void:
	var target := tracker.global_transform if tracker != null and tracker.get_has_tracking_data() else global_transform
	if automatic and (not _had_tracking or not _reset_path_is_clear(target)):
		return
	drop_held_object()
	skeleton.set_show_rest_only(false)
	# Teleport physics hand back to controller position
	# Value of reset_transform will be read on the next physics frame
	reset_transform = target
	_automatic_reset = automatic
	motor_target = _pose_filter.reset(reset_transform, XRServer.world_scale)
	_reset_motor_history()
	resetting_hand = true
	hand_reset.emit(self)


func _on_grab(grab: bool) -> void:
	if grab and tracker != null and tracker.get_has_tracking_data():
		grab()
	else:
		drop_held_object()


func _on_hand_pose_recognition_new_pose(previous_pose: StringName, pose: StringName) -> void:
	# Do not grab/drop based on hand poses when we receive data from controller
	if is_controller_tracking:
		return

	if pose in ["half_grip", "full_grip", "thumb_up", "point"] and previous_pose in ["open", "rest"]:
		grab()

	if pose in ["open", "rest"]:
		drop_held_object()


func _on_click(released: bool):
	if held_object and released:
		drop_held_object()
	
	# TODO: if not holding an object, apply boost

	
func _on_long_click(released: bool):
	grab()
	# TODO: if holding an object and not released, enable free hand rotation


func _on_controller_tracking_changed(is_tracking: bool):
	if is_tracking:
		tracker = controller
	elif hand_tracker != null and hand_tracker.get_has_tracking_data():
		tracker = hand_tracker
	# Controllers-only sessions have no fallback hand pose. Retain the last
	# controller source until it recovers instead of following an empty node.
	is_controller_tracking = tracker == controller
	_pose_filter.invalidate()
	_had_tracking = false


class PIDController:
	var Kp: float
	var Ki: float
	var Kd: float
	var error: Vector3
	var proportional: Vector3
	var proportional_limit: float
	var previous_error: Vector3
	var integral: Vector3
	var integral_limit: float
	var derivative: Vector3
	var derivative_limit: float
	var output: Vector3

	func _init(args) -> void:
		Kp = args.Kp
		Ki = args.Ki
		Kd = args.Kd
		proportional_limit = args.proportional_limit
		integral_limit = args.integral_limit
		derivative_limit = args.derivative_limit
		previous_error = Vector3(0, 0, 0)
		integral = Vector3(0, 0, 0)


	func update(args) -> void:
		Kp = args.Kp
		Ki = args.Ki
		Kd = args.Kd
		integral_limit = args.integral_limit
		derivative_limit = args.derivative_limit


	func calculate(target: Vector3, current: Vector3, delta: float) -> Vector3:
		if delta <= 0.0:
			return Vector3.ZERO
		error = target - current
		proportional = error
		proportional = proportional.limit_length(proportional_limit)
		integral += error * delta
		integral = integral.limit_length(integral_limit)
		derivative = (error - previous_error) / delta
		derivative = derivative.limit_length(derivative_limit)
		previous_error = error
		output = Kp * proportional + Ki * integral + Kd * derivative

		return output


	func reset(current_error: Vector3 = Vector3.ZERO) -> void:
		previous_error = current_error
		integral = Vector3.ZERO
		derivative = Vector3.ZERO
