extends RefCounted
## Where the player's mouth is, and where a thing carried in it sits
## (docs/ANONPONY_DESIGN_2026_10_01.md section 12.7). Human Anon keeps the fixed offsets from the
## eye that eating and the desktop hand always used; AnonPony uses her own muzzle
## (player/pony_form.gd), so food, drink and carried things meet the pony's mouth.
const PONY_FORM := preload("res://player/pony_form.gd")

## The point eating and drinking aim at.
static func point(camera: Node3D) -> Vector3:
	var form: Node = _form(camera)
	if form != null: return form.mouth_world()
	return camera.global_position - camera.global_basis.y * .08 - camera.global_basis.z * .04

## Where a carried thing sits: AnonPony holds it in her mouth, oriented to her view; human Anon
## at `human_local` relative to the camera.
static func hold_transform(camera: Node3D, human_local: Transform3D) -> Transform3D:
	var form: Node = _form(camera)
	if form != null: return form.hold_transform()
	return camera.global_transform * human_local

## The player's PonyForm while its avatar exists, else null (human, room-scale VR, scene change).
static func _form(camera: Node3D) -> Node:
	if not is_instance_valid(camera) or not camera.is_inside_tree(): return null
	var form: Node = PONY_FORM.find(camera.get_tree())
	if form == null or not is_instance_valid(form.get("avatar")): return null
	return form
