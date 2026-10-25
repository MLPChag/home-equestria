extends Node
## The devkit mane uses mHead/mChest, its tail mTail1..6. Copy the linked
## OpenPony head and native pelvis *inside* skeleton_updated, before skinning.
var body: Skeleton3D
var head: Skeleton3D
var hair: Skeleton3D
var body_hips := -1
var hair_pelvis := -1
var pelvis_offset := Transform3D.IDENTITY
var head_pairs: Array[Vector2i] = []
var head_offsets: Array[Vector3] = []
## Off while the far render LOD shows a merged mesh on the body skeleton alone.
var enabled := true
var skull_frame := Transform3D.IDENTITY
var _head_rest_inverse := Transform3D.IDENTITY
const PROFILE := preload("res://tools/crowd_cpu_profile.gd")

func bind(body_sk: Skeleton3D, head_sk: Skeleton3D, hair_sk: Skeleton3D,
		tail_offset_world := Vector3.ZERO, mane_offset_world := Vector3.ZERO) -> void:
	body = body_sk
	head = head_sk
	hair = hair_sk
	_head_rest_inverse = head.get_bone_global_rest(head.find_bone("mHead")).affine_inverse()
	body_hips = body.find_bone("pony_hips")
	hair_pelvis = hair.find_bone("mPelvis")
	var body_rest := body.global_transform * body.get_bone_global_rest(body_hips)
	var hair_rest := hair.global_transform * hair.get_bone_global_rest(hair_pelvis)
	hair_rest.origin += tail_offset_world
	pelvis_offset = body_rest.affine_inverse() * hair_rest
	for name in ["mChest","mNeck","mHead"]:
		var pair := Vector2i(head.find_bone(name),hair.find_bone(name))
		head_pairs.append(pair)
		# The mane offset is fixed in each bone's own frame, so it nods with the head.
		var rest := head.global_transform * head.get_bone_global_rest(pair.x)
		head_offsets.append(rest.basis.inverse() * mane_offset_world)
	body.skeleton_updated.connect(_body_updated)
	head.skeleton_updated.connect(_head_updated)

func _body_updated() -> void:
	if not enabled or not is_instance_valid(hair) or not hair.is_inside_tree(): return
	var started := Time.get_ticks_usec() if PROFILE.enabled else 0
	var world := body.global_transform * body.get_bone_global_pose(body_hips) * pelvis_offset
	hair.set_bone_global_pose(hair_pelvis,hair.global_transform.affine_inverse()*world)
	if PROFILE.enabled: PROFILE.record("hair_link", started)

func _head_updated() -> void:
	if not enabled or not is_instance_valid(hair) or not hair.is_inside_tree(): return
	var started := Time.get_ticks_usec() if PROFILE.enabled else 0
	for i in head_pairs.size():
		var pair := head_pairs[i]
		var posed := head.get_bone_global_pose(pair.x)
		if i == 2:
			var motion := posed * _head_rest_inverse
			posed = motion * skull_frame * motion.affine_inverse() * posed
		var world := head.global_transform * posed * Transform3D(Basis.IDENTITY, head_offsets[i])
		hair.set_bone_global_pose(pair.y,hair.global_transform.affine_inverse()*world)
	if PROFILE.enabled: PROFILE.record("hair_link", started)
