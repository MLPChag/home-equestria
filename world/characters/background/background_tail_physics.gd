extends "res://world/characters/hybrid_mare/hybrid_tail_physics.gd"
## Attachment hair is part of the collar in every pose. Classify it in rest
## space; bending must not turn intentionally embedded roots into body contacts.
var _collar_contacts: PackedByteArray = []

func bind(owner_pony: Node3D, supplied_skeleton: Skeleton3D = null) -> void:
	super.bind(owner_pony, supplied_skeleton)
	var frames := _frames(Transform3D.IDENTITY)
	_contact_mount = Transform3D.IDENTITY
	_collar_contacts.resize(skin_contacts.size())
	for i in skin_contacts.size():
		_collar_contacts[i] = int(_point(skin_contacts[i], frames).distance_squared_to(_base_pose[0].origin) < .11 * .11)
	_contact_kernel.build(skin_contacts, _collar_contacts, .00001)
	_native_retry = true

func _deepest(frames: Array[Transform3D], anchor: Vector3) -> Dictionary:
	return super._deepest(frames, anchor)

func _project(contact: Dictionary, frames: Array[Transform3D], mount: Transform3D) -> void:
	super._project(contact, frames, mount)
	# A moving rump can require more than one correction per pass on long hair.
	# Spend the extra projection only while a measurable overlap remains.
	for retry in 1:
		var corrected := _frames(mount)
		var remaining := _deepest(corrected, (mount * _base_pose[0]).origin)
		if remaining.is_empty() or remaining.depth <= .002: break
		super._project(remaining, corrected, mount)
