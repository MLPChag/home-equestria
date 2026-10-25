extends "res://world/characters/openpony/openpony_eye_motion.gd"
## Per-eye bias uses the native curved eye surface, skin and blinking mechanism.
@export var asymmetric_gaze := false
@export var inward_radians := 0.055
@export var vertical_radians := 0.20

func surface_angles(side_index: int, angles: Vector2) -> Vector2:
	if asymmetric_gaze:
		var side := 1.0 if side_index == 0 else -1.0
		# Anatomical left: inward/down. Right: inward/up. Keep the asymmetry
		# during attention and saccades without exceeding the native socket bounds.
		angles = angles * 0.2 + Vector2(-side * inward_radians, -side * vertical_radians)
	return angles

func eye_pose(side_index: int, angles: Vector2) -> Transform3D:
	return super.eye_pose(side_index, surface_angles(side_index,angles))

func _native_asymmetry() -> PackedFloat64Array:
	return PackedFloat64Array([1.0 if asymmetric_gaze else 0.0, inward_radians, vertical_radians])
