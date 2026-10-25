extends SkeletonModifier3D
## Collapses a set of bones (and everything skinned to their subtree) so a
## body part disappears without splitting the mesh. Used for the legs when
## the player sits down: with no leg trackers, a standing pair of legs under
## a seated torso is worse than no legs at all.
##
## The modifier's built-in `influence` does the blending: 0 shows the part,
## 1 removes it; the driver eases it so the legs shrink away over a few
## frames instead of popping. Runs after the IK modifiers because modifier
## order is tree order.

@export var bones: Array[StringName] = []

var _ids := PackedInt32Array()
var _resolved := false


func _process_modification() -> void:
	if influence <= 0.0:
		return
	var skel := get_skeleton()
	if skel == null:
		return
	if not _resolved:
		_resolved = true
		for name in bones:
			var id := skel.find_bone(name)
			if id != -1:
				_ids.append(id)
	# Scale, never translate: the joint stays where IK put it so nothing
	# above it shifts, only the limb below shrinks to a point. The skeleton
	# blends this full collapse by `influence`.
	var scale := 0.001
	for id in _ids:
		var pose := skel.get_bone_pose(id)
		skel.set_bone_pose(id, Transform3D(pose.basis.orthonormalized().scaled(Vector3.ONE * scale), pose.origin))
