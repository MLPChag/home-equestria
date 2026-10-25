class_name HybridNeckLink
extends Node
## Drive OpenPony neck/head bones from the native mare rig so the grafted head follows the body.
##
## The OpenPony head (own Skeleton3D, own face bones for mouth/blink) sits on the native body at a
## fixed rest offset (tools/fit_bell_hybrid_neck.py). After every native skeleton update the three
## OpenPony chain bones take the world motion of their native counterparts relative to rest, so both
## sides of the shared neck rim deform identically: the body's rim is weighted
## pony_head/pony_neck2/pony_spine3 and the head's rim HEAD/NECK/CHEST (children of mHead/mNeck/mChest).
##
## The native locomotion poses its bones inside a SkeletonModifier3D, and Skeleton3D restores the
## unmodified pose after skinning, so the modified poses are only readable from `skeleton_updated`.
## The OpenPony poses are written as plain bone poses there; its own modifiers (mouth) layer on top.

const PAIRS := [["pony_spine3", "mChest"], ["pony_neck2", "mNeck"], ["pony_head", "mHead"]]

var source: Skeleton3D
var target: Skeleton3D
var _source_bones: PackedInt32Array = []
var _target_bones: PackedInt32Array = []
var _offsets: Array[Transform3D] = []
var _linked := false
## Last modified body frames used by the link, before Skeleton3D restores its plain poses.
var source_poses: Dictionary = {}


func link(body_skeleton: Skeleton3D, openpony_skeleton: Skeleton3D) -> bool:
	source = body_skeleton
	target = openpony_skeleton
	_source_bones.clear()
	_target_bones.clear()
	_offsets.clear()
	source_poses.clear()
	_linked = false
	if source == null or target == null:
		return false
	for pair in PAIRS:
		var s: int = source.find_bone(pair[0])
		var t: int = target.find_bone(pair[1])
		if s < 0 or t < 0:
			push_warning("HybridNeckLink: missing bone pair %s" % [pair])
			continue
		var source_rest := source.global_transform * source.get_bone_global_rest(s)
		var target_rest := target.global_transform * target.get_bone_global_rest(t)
		_source_bones.append(s)
		_target_bones.append(t)
		_offsets.append(source_rest.affine_inverse() * target_rest)
	_linked = _source_bones.size() == PAIRS.size()
	if _linked and not source.skeleton_updated.is_connected(_on_source_updated):
		source.skeleton_updated.connect(_on_source_updated)
	return _linked


## Off while the far render LOD shows a merged mesh on the body skeleton alone.
var enabled := true
const PROFILE := preload("res://tools/crowd_cpu_profile.gd")


func _on_source_updated() -> void:
	if not enabled or not _linked or not is_instance_valid(source) or not is_instance_valid(target) \
			or not source.is_inside_tree() or not target.is_inside_tree():
		return
	var started := Time.get_ticks_usec() if PROFILE.enabled else 0
	var into_target := target.global_transform.affine_inverse()
	for i in _source_bones.size():
		var source_pose := source.get_bone_global_pose(_source_bones[i])
		source_poses[_source_bones[i]] = source_pose
		var world := source.global_transform * source_pose * _offsets[i]
		target.set_bone_global_pose(_target_bones[i], into_target * world)
	if PROFILE.enabled: PROFILE.record("neck_link", started)
