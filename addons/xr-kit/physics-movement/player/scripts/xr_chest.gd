extends Node3D

func _process(delta: float) -> void:
	# Home: Equestria - a tracking drop can leave a non-finite pose for a frame;
	# keep last frame's chest rather than propagate NaN into the physics hands.
	if not %XRCamera.global_transform.is_finite() or not %PhysicsHandLeft.global_transform.is_finite() \
			or not %PhysicsHandRight.global_transform.is_finite():
		return
	# chest is always 30cm below camera
	global_transform.origin = %XRCamera.global_transform.origin - %XROrigin.global_transform.basis.y * 0.3
	# we rotate chest based on camera and wrists positions
	var camera_forward: Vector3 = -%XRCamera.global_transform.basis.z.normalized() / 2 # camera influence is halved compared to hands influence
	# influences are merged to create final vector
	var target_vector: Vector3 = (global_transform.origin + camera_forward + %PhysicsHandLeft.global_transform.origin + %PhysicsHandRight.global_transform.origin) / 3
	# keep rotation along chest Y axis, so it doesn't look up or down
	var look_at_vector = target_vector.slide(Vector3(0,1,0)) + Vector3(0, global_transform.origin.y, 0)
	# rotate chest. looking_at() rejects targets within a RELATIVE epsilon of
	# the origin (1.5 mm at 150 m from the world origin), so mirror that test
	# instead of a fixed 1 mm to stop the "origin and target can't be equal" spam.
	if global_position.distance_squared_to(look_at_vector) > .000001 \
			and not global_position.is_equal_approx(look_at_vector):
		global_transform = global_transform.looking_at(look_at_vector, %XROrigin.global_transform.basis.y)
