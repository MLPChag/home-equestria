extends RefCounted
## Building a pony's body at _ready (split from pony_locomotion.gd, 2026-10-13): model and rig
## binding, the native solver, look, collision capsule, the terrain modifier and the live clip
## head (their add_child order is their modifier order), baked gait clips and crowd membership.
## The order below is the original order; the fields it fills stay on the pony.

const NATIVE := preload("res://world/characters/locomotion/native_solver.gd")
const MODIFIER := preload("res://world/characters/locomotion/pony_terrain_modifier.gd")
const BAKED_GAITS := preload("res://world/characters/locomotion/baked_gaits.gd")
const CLIP_HEAD := preload("res://world/characters/locomotion/pony_clip_head.gd")
const SOLVE_BATCH := preload("res://world/characters/locomotion/pony_solve_batch.gd")
const POSE_BATCH := preload("res://world/characters/locomotion/gpu/pony_pose_batch.gd")


static func build(pony: CharacterBody3D) -> void:
	pony.hoof_hold.bind(pony)
	var pivot := Node3D.new()
	pivot.name = "ModelPivot"
	pony.pivot = pivot
	pony.add_child(pivot)
	var model_scene: PackedScene = pony.model_scene
	var model := model_scene.instantiate()
	pivot.add_child(model)
	pony._model = model
	var skeleton: Skeleton3D = pony._find_class(model, "Skeleton3D")
	var animation: AnimationPlayer = pony._find_class(model, "AnimationPlayer")
	pony.skeleton = skeleton
	pony.animation = animation
	var profile: Resource = pony.profile
	if skeleton == null or animation == null or not profile.bind(skeleton, animation):
		push_error("Cannot bind native mare locomotion")
		pony.set_physics_process(false)
		return
	pony._model_frame = pony.global_transform.affine_inverse() * skeleton.global_transform
	pony.joint_limits.bind(profile, skeleton)
	var native: RefCounted = NATIVE.create()
	pony._native = native
	if native != null:
		native.bind_rig(profile.parents)
		pony.joint_limits.bind_native(native)
		pony.self_collision.native = native if NATIVE.enabled("self_collision") else null
		native.bind_probe(pony, pony.get_rid())
		pony._native_probe = NATIVE.enabled("probe")
		pony._native_body = NATIVE.enabled("body")
	pony.step_timing.bind(profile)
	var secondary: RefCounted = pony.secondary
	secondary.bind(skeleton)
	secondary.bind_lids(skeleton)
	var blend_bones: Variant = profile.blend_bones
	for side in ["L", "R"]:
		for bone in secondary.lid_bones(side, true) + secondary.lid_bones(side, false):
			if blend_bones.has(bone): pony._lids_static = false
	secondary.set_head_width(skeleton, pony.head_width)
	pony.carry.bind(pony)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.38, 0.68, 0.85)
	material.roughness = 0.85
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.metallic = 0.0
	var preserve: bool = pony.preserve_model_materials
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		if not preserve:
			mesh.material_override = material
	if preserve and pony.show_shading:
		pony._apply_show_shading(model)
	if preserve and pony.eyes_enabled:
		pony._attach_eyes(skeleton)
	var shape := CapsuleShape3D.new()
	shape.radius = 0.19
	shape.height = 0.85
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position.y = shape.height / 2.0
	pony.add_child(collision)
	pony._collision = collision
	pony.collision_layer = 2
	var identity: Resource = pony.identity
	var floor_mask: int = 1 | (int(pony.CLOUD_LAYER) if identity != null and identity.has_method("has_wings") and identity.has_wings() else 0)
	pony.floor_mask = floor_mask
	pony.collision_mask = floor_mask
	pony.floor_snap_length = 0.3
	pony.floor_max_angle = deg_to_rad(profile.max_slope_degrees)
	pony.floor_constant_speed = true
	var modifier := MODIFIER.new()
	modifier.native = native if NATIVE.enabled("terrain_modifier") else null
	pony.modifier = modifier
	skeleton.add_child(modifier)
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS
	# Godot 4.5 keeps a pointer into its animation table while playing. Adding/removing
	# libraries can relocate that table; stop the sampled trot before changing it.
	animation.stop(true)
	var baked: AnimationLibrary = BAKED_GAITS.attach(animation, skeleton, model_scene.resource_path if model_scene != null else "")
	pony._baked = baked
	if baked != null:
		# Only the baked clips play on this player. The model's own native library (the trot, and the
		# gallop the gait profile added) was read once by profile.bind() above, and the mixer walks
		# every track of every library it holds on each advance.
		for library_name in animation.get_animation_library_list():
			if library_name != BAKED_GAITS.LIBRARY:
				animation.remove_animation_library(library_name)
		animation.play(pony._baked_name(BAKED_GAITS.STAND))
	# Right after the terrain modifier: the live head bends the clip's neck before any
	# proportion modifier (fillies) or the head/hair links read it.
	var clip_head := CLIP_HEAD.new()
	clip_head.name = "ClipHead"
	clip_head.pony = pony
	clip_head.native = native if NATIVE.enabled("clip_head") else null
	clip_head.active = false
	pony._clip_head = clip_head
	skeleton.add_child(clip_head)
	modifier.modification_processed.connect(Callable(pony, "_measure_visible_soles"))
	pony.reset_motion(pony.global_transform)
	pony._pose_batch = POSE_BATCH.for_pony(pony)
	pony._solve_batch = SOLVE_BATCH.for_pony(pony) if native != null else null
	pony.add_to_group(PonyCrowd.MEMBERS)
	pony._crowd = PonyCrowd.for_pony(pony)
