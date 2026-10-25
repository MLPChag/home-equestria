extends "res://world/characters/hybrid_mare/hybrid_mare.gd"
## The complete original striped Zecora is the only visible pony. The established
## locomotion/interaction rig remains an invisible driver, never a replacement skin.
const ASSET := preload("res://world/characters/zecora/source_asset.gd")
var native_model: Node3D
var native_skeleton: Skeleton3D
var _native_pairs: Array[Vector2i] = []
var _native_offsets: Array[Transform3D] = []
var _native_faces: Array[MeshInstance3D] = []

func _attach_devkit_hair() -> void:
	pass # The source includes her own mane, tail, ears, rings and complete face.

func _redress() -> void:
	# Public shading presets only dress the invisible driver. Native Source textures
	# (stripes, jewelry and iris artwork) retain their own materials and UVs.
	super._redress()
	_near_waiting = false
	if _model != null: _model.visible = false
	if head != null: head.visible = false

func _ready() -> void:
	far_mesh_enabled = false
	near_mesh_enabled = false
	super._ready()
	_model.visible = false
	head.visible = false
	native_model = ASSET.scene("res://world/characters/zecora/fitted.glb").instantiate()
	native_model.name = "OriginalStripedZecora"
	pivot.add_child(native_model)
	native_skeleton = native_model.find_children("*", "Skeleton3D", true, false)[0]
	var mapping: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://world/characters/zecora/rig_map.json"))
	for bone in native_skeleton.get_bone_count():
		var source_name := native_skeleton.get_bone_name(bone)
		if not mapping.has(source_name): continue
		var driver: int = skeleton.find_bone(mapping[source_name])
		assert(driver >= 0)
		var driver_rest := skeleton.global_transform * skeleton.get_bone_global_rest(driver)
		var source_rest := native_skeleton.global_transform * native_skeleton.get_bone_global_rest(bone)
		_native_pairs.append(Vector2i(driver, bone))
		_native_offsets.append(driver_rest.affine_inverse() * source_rest)
	for view: MeshInstance3D in native_model.find_children("*", "MeshInstance3D", true, false):
		if view.mesh.get_blend_shape_count() > 0: _native_faces.append(view)
	skeleton.skeleton_updated.connect(_update_native_pose)
	_update_native_pose()
	set_meta("species", "zebra")
	set_meta("source_art", "enhanced-zercora-model-source-files/SFM-zecora")

func _update_native_pose() -> void:
	if not is_instance_valid(native_skeleton): return
	var into_native := native_skeleton.global_transform.affine_inverse()
	for i in _native_pairs.size():
		var pair := _native_pairs[i]
		native_skeleton.set_bone_global_pose(pair.y, into_native * skeleton.global_transform * skeleton.get_bone_global_pose(pair.x) * _native_offsets[i])
	var blink: float = 1.0 - (1.0-clampf(eye_motion.closure,0.0,1.0)) * (1.0-clampf(eye_motion.expression_closure,0.0,1.0))
	for face in _native_faces:
		for key in ["CloseEyesL", "CloseEyesR"]:
			var slot: int = face.find_blend_shape_by_name(key)
			if slot >= 0: face.set_blend_shape_value(slot, blink)
		var jaw: int = face.find_blend_shape_by_name("JawOpen")
		if jaw >= 0:
			# Existing local Ponese / voice playback owns lip timing.
			face.set_blend_shape_value(jaw, float({"X":0.0,"A":.06,"B":.15,"C":.45,"D":.7,"E":.3,"F":.1,"G":.12,"H":.25}.get(head.mouth.current_viseme, 0.0)))
