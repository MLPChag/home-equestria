extends "res://world/characters/background/background_pony.gd"
## The player's own pony (AnonPony, docs/ANONPONY_DESIGN_2026_10_01.md, section 4): an ordinary
## background pony body with no AI, driven by player/pony_form.gd. It reuses the fitted cutie-mark
## patches and the tail-anchor preload of background_pony.gd; the shared locomotion and hybrid
## player-specific movement policy is implemented through overrides here.

## A drop the player may walk off even at a slow walk, where the base lookahead is short and a
## curb would stop him (times body_scale). Never stricter than the base tolerance.
const PLAYER_MAX_DROP := 0.35
## Collision this far below still counts as ground she is falling to (_recover_support); the
## base support ray reaches only 8 m, and Dash's cloud house stands higher than that.
const FALL_PROBE_DEPTH := 500.0
## Player response (dev 2026-10-01: walking "WAY more responsive like nearly instant"): the NPC
## rates turn at 1.8 and 0.45 rad/s and reach a trot in about a second. Speed changes and turns
## here finish in about a tenth of a second.
const RESPONSE_SCALE := 12.0
const STEER_TURN_RATE := 12.0
const FACE_TURN_RATE := 9.0
## Mane recolour: a brightness ramp (black -> dark, white -> mid) on textured hair, the mid
## colour as the plain fill on untextured hair (thunderlane_hair.glb carries no images). Near
## black, as the Second Life Anonpony preset's mane and tail (dev's screenshot, 2026-10-01).
const MANE_DARK := Color("161619")
const MANE_MID := Color("2e2e33")
## Plain dark tubes on all four lower legs (PonyWardrobe._sock without the stripes). Off: dev
## wants no socks (2026-10-01); fitted OpenPony socks are paused work (docs/NEXT_STEPS.md).
const SOCKS_ENABLED := false
const SOCK_COLOR := Color("3a3a3e")
const SOCK_OFFSET := Vector3(0.0, -0.03, 0.0)
## [bone, fallback bone]: the front carpus and its hind counterpart.
const SOCK_BONES := [["pony_wrist_L", ""], ["pony_wrist_R", ""],
	["pony_tarsal_L", "pony_legLower_L"], ["pony_tarsal_R", "pony_legLower_R"]]

## The rig (desktop or seated) that drives this pony; while its physics is held (loading cover,
## title) the pony stands still too.
var rig: Node3D
## Set by PonyForm while the pony is hidden (hold park, wake poses, debug flight).
var parked := false
## Where the player looks (PonyForm's PlayerLookTarget): her head and eyes follow it.
var look_target: Node3D
## PonyForm places the desktop eye guard after this motor turns the body, just
## before physical movement. The view heading is independent of the body's yaw.
var sync_view_clearance: Callable
var _player_step := preload("res://player/ground_step.gd").new()


## The player is never stranded on a roof the way an NPC can be, and a teleport would fight the
## rig; support recovery and the water escape still apply.
class NoRecovery extends "res://world/characters/locomotion/placement_recovery.gd":
	func update(_pony: CharacterBody3D, _delta: float) -> void:
		pass


func _ready() -> void:
	_borrow_tail_anchors()
	super._ready()
	steer_turn_rate = STEER_TURN_RATE
	face_turn_rate = FACE_TURN_RATE
	# set_body_scale rescales these with the size, so they stay relative.
	profile.acceleration *= RESPONSE_SCALE
	profile.braking *= RESPONSE_SCALE
	placement_recovery = NoRecovery.new()
	collision_layer = 0


## The anchored tail depends on the hair scene only, so an adult AnonPony uses the shipped anchors
## of the background pony whose hair she wears (background/support/<source id>.res), with the
## checks background_pony._ready applies to its own id. Young ponies build theirs at run time
## (their pivot scale changes the pinned length).
func _borrow_tail_anchors() -> void:
	if identity == null or not identity.has_meta(&"hair_source_id") or identity.get("filly") == true: return
	var source := str(identity.get_meta(&"hair_source_id"))
	var id := str(identity.get("id"))
	var hair_scene := str(identity.get("hair_scene"))
	for suffix: String in ["", "LOD1"]:
		if ANCHORS.cache.has(id + suffix): continue
		var path := "res://world/characters/background/support/" + source + suffix + ".res"
		if not ResourceLoader.exists(path): continue
		var anchored := load(path) as ArrayMesh
		if anchored == null: continue
		if anchored.get_meta("anchor_version", -1) != ANCHORS.VERSION or (OS.has_feature("editor") and int(anchored.get_meta("source_mtime", -1)) != FileAccess.get_modified_time(hair_scene)): continue
		ANCHORS.cache[id + suffix] = anchored
		if suffix == "" and anchored.get_meta("contact_version", -1) == PHYSICS.CONTACT_VERSION:
			PHYSICS._contact_cache[anchored.get_instance_id()] = anchored.get_meta("contacts")


func _physics_process(delta: float) -> void:
	if parked: return
	if is_instance_valid(rig) and not rig.is_physics_processing(): return
	super._physics_process(delta)
	_quiet_glances()


## Never on the pony layer: nothing the player aims or reaches with may hit his own body.
func _update_contact_rules() -> void:
	if collision_layer != 0:
		collision_layer = 0


## Brushing a rail must not repeatedly stop all keyboard/stick travel for 0.4 seconds.
## The physical slide and existing support probes still decide which motion is possible.
func _preserve_wall_slide() -> bool:
	return true

func _move_player_step(delta: float) -> bool:
	if sync_view_clearance.is_valid(): sync_view_clearance.call()
	if _held or _blocked or _touch_blocks() or _desired.length_squared() < .0001 or (posture != null and posture.active()):
		_player_step.reset(); return false
	return _player_step.move(self,delta,profile.step_height,_step_support_safe)

func _step_support_safe(future: Transform3D) -> bool:
	for leg in profile.legs:
		var point: Vector3 = future * pivot.transform * _model_frame * Vector3(leg.neutral_sole)
		var hit := _probe(point,profile.step_height)
		if hit.is_empty() or absf(float(hit.position.y)-point.y)>profile.step_height \
				or Vector3(hit.normal).angle_to(Vector3.UP)>deg_to_rad(profile.max_slope_degrees):
			return false
	return true


## Always HERO, whatever the crowd ranking says.
func body_pinned() -> bool:
	return true


## Resting posture belongs to player input, on the ground as well as on furniture.
func request_posture(kind: String) -> bool:
	var accepted: bool = super.request_posture(kind)
	if posture != null: posture.automatic_rest = false
	return accepted


func _keep_partner_in_view(_delta: float) -> void:
	pass


func needs_full_rate() -> bool:
	return true


func _attention_target() -> Node3D:
	return look_target if is_instance_valid(look_target) else null


## The base probe (pony_locomotion._safe_ahead). A rise keeps the base rule; a drop is refused
## only when deeper than the base tolerance or PLAYER_MAX_DROP, whichever is larger. An empty
## probe is still refused. In the air the check is off: a jump off a roof already left the ledge
## behind, and refusing the empty ground ahead stopped her dead above the drop.
func _safe_ahead(speed: float) -> bool:
	if speed < 0.01 or not _initialized or (not is_on_floor() and not _heightmap_supported):
		return true
	# Backing up (S, pony_form._steer), the ground that matters is behind her.
	var forward := (global_basis.z if backing else -global_basis.z).normalized()
	var lookahead := speed * speed / (2.0 * profile.braking) + profile.hip_height
	for fraction: float in [0.5, 1.0]:
		var point: Vector3 = global_position + forward * lookahead * fraction
		if is_on_floor():
			var normal := get_floor_normal()
			point.y -= normal.dot(forward) * lookahead * fraction / maxf(normal.y, .1)
		var rise: float = lookahead * fraction * tan(deg_to_rad(profile.max_slope_degrees))
		var hit := _probe(point, rise)
		if hit.is_empty():
			return false
		var tolerance: float = profile.hip_height * 0.2 + rise
		var step: float = float(hit.position.y) - global_position.y
		if step > tolerance or -step > maxf(tolerance, PLAYER_MAX_DROP * body_scale):
			return false
	return true


## The base support recovery (pony_support_recovery.gd) moves a pony more than 0.6 m above her
## floor straight onto it, and with no floor within 8 m holds the terrain height: right for an NPC
## stranded by a late zone load, but for the player it cut every real fall short (tester: jumping
## off Dash's cloud house teleported her straight down). While collision lies below her she falls
## under gravity; sunk under a surface, or with nothing below at all, the base recovery applies.
func _recover_support() -> void:
	if _falling_to_ground(): return
	super._recover_support()


func _falling_to_ground() -> bool:
	var near := _support_ray(0.6)
	if not near.is_empty():
		return global_position.y > float(near.position.y) + 0.6
	var terrain: float = WorldTerrain.instance.height_at(global_position) if is_instance_valid(WorldTerrain.instance) else NAN
	if is_finite(terrain) and global_position.y < terrain: return false
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.6,
		global_position - Vector3.UP * FALL_PROBE_DEPTH, floor_mask, [get_rid()])
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()


## Base shading, then the mane and tail in Anonfilly greys. These materials are built per pony by
## pony_locomotion._apply_show_shading, so no NPC is touched; _redress calls this again.
func _apply_show_shading(model: Node) -> void:
	super._apply_show_shading(model)
	if identity == null or model == null: return
	var prefix := str(identity.get("hair_prefix")) + "Devkit"
	var meshes: Array = [model] if model is MeshInstance3D else model.find_children("*", "MeshInstance3D", true, false)
	for node in meshes:
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null or not String(mi.name).begins_with(prefix): continue
		for surface in mi.mesh.get_surface_count():
			var material := mi.get_surface_override_material(surface) as ShaderMaterial
			if material != null: _recolour_mane(material)


func _recolour_mane(material: ShaderMaterial) -> void:
	var current: Variant = material.get_shader_parameter("color")
	var alpha := 1.0
	if current is Color: alpha = current.a
	var fill: Color
	if material.get_shader_parameter("base_texture") != null:
		# Any source palette works: the texture's brightness picks between the two greys, and
		# `color` (which multiplies the texture) goes white.
		material.set_shader_parameter("replace_texture_palette", true)
		material.set_shader_parameter("texture_palette_source_a", Color.BLACK)
		material.set_shader_parameter("texture_palette_source_b", Color.WHITE)
		material.set_shader_parameter("texture_palette_a", MANE_DARK)
		material.set_shader_parameter("texture_palette_b", MANE_MID)
		fill = Color(1.0, 1.0, 1.0, alpha)
	else:
		# Untextured: a palette swap would map the sampler's white default to a flat colour.
		material.set_shader_parameter("replace_texture_palette", false)
		fill = Color(MANE_MID, alpha)
	material.set_shader_parameter("color", fill)
	# The two-tone band was computed from the source colour; recompute it from the new fill.
	var shadow: Variant = material.get_shader_parameter("shadow_color")
	if shadow is Color and float(shadow.a) > 0.0:
		material.set_shader_parameter("shadow_color", _shade_of(fill))


## Socks on the lower legs. PonyForm calls this before set_body_scale: the attachments sit under
## the skeleton under the pivot, so the body scale, the young scale and later size changes all
## carry them. The pattern of PonyWardrobe._on_bone, but sized from the pivot (where body_scale
## lives), not from the never-scaled root.
func add_socks() -> void:
	if not SOCKS_ENABLED or skeleton == null or pivot == null: return
	var frame := global_basis.orthonormalized()
	var size := pivot.global_basis.get_scale().x
	for pair: Array in SOCK_BONES:
		var bone := str(pair[0])
		if skeleton.find_bone(bone) < 0: bone = str(pair[1])
		var index := skeleton.find_bone(bone) if not bone.is_empty() else -1
		if index < 0: continue
		var node_name := "AnonSock_" + bone
		if skeleton.get_node_or_null(node_name) != null: continue
		var attachment := BoneAttachment3D.new()
		attachment.name = node_name
		attachment.bone_name = bone
		skeleton.add_child(attachment)
		var piece := _sock()
		attachment.add_child(piece)
		# Laid out in the body frame as she stands now, then it follows the bone.
		var at := skeleton.global_transform * skeleton.get_bone_global_pose(index)
		piece.transform = at.affine_inverse() * Transform3D(frame.scaled(Vector3.ONE * size), at.origin + frame * SOCK_OFFSET * size)


static func _sock() -> Node3D:
	var root := Node3D.new()
	root.name = "Sock"
	var tube := CylinderMesh.new()
	tube.top_radius = 0.042
	tube.bottom_radius = 0.045
	tube.height = 0.16
	tube.radial_segments = 14
	var material := StandardMaterial3D.new()
	material.albedo_color = SOCK_COLOR
	material.roughness = 0.95
	var mesh := MeshInstance3D.new()
	mesh.mesh = tube
	mesh.material_override = material
	mesh.position = Vector3(0.0, -0.07, 0.0)
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh)
	return root


## Her head follows the player's look without wandering off on its own: no look-away breaks in
## the attention sessions, no idle head looks and no random glances while the marker is set.
func _quiet_glances() -> void:
	if not is_instance_valid(look_target): return
	if attention != null:
		attention.set("_session", 1.0)
		attention.set("_idle_time", 0.0)
		attention.set("_idle_wait", 1.0)
	secondary._gaze_wait = maxf(secondary._gaze_wait, 1.0)
