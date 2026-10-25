extends Node3D
## Magic on a lifted thing, always (dev 2026-10-01: "use this for magic always", "resize it to
## the size of the object"): the "MLP Magic Auras" Garry's Mod addon (Steam Workshop 690684980,
## art in world/characters/magic/aura/, packed by tools/magic/build_magic_aura.gd) remade here.
## - A camera-facing disc with a rippling rim (magic_aura.gdshader), radius MARGIN times the
##   thing's bounding radius, at its centre, in the caster's magic colour.
## - Sparkles popping on a sphere of that radius: SPARKLES_PER_SECOND, each living
##   SPARKLE_LIFE and shrinking from SPARKLE_SIZE times the radius.
## - The cast sound, the sustain loop while held, the disperse sound on release.
## Fades in and out at the addon's rates. UnicornMagic.glow_object makes one;
## UnicornMagic.unglow_object releases it (it disperses and frees itself).
const SHADER := preload("res://world/characters/magic/magic_aura.gdshader")
const GRADIENT := preload("res://world/characters/magic/aura/aura_gradient.res")
const SPARKLES := preload("res://world/characters/magic/aura/sparkles_atlas.res")
const CAST := preload("res://world/characters/magic/aura/magic_cast.res")
const SUSTAIN := preload("res://world/characters/magic/aura/magic_sustain.res")
const DISPERSE := preload("res://world/characters/magic/aura/magic_disperse.res")
## The addon's constants: MARGIN_RATIO, pma_visibility 200/255, FADE_IN_SPEED 800 and
## FADE_OUT_SPEED 500 (alpha per second out of 255), 100 rim vertices, pma_particle_speed 200,
## PARTICLE_LIFE_PERIOD 0.2, PARTICLE_SIZE_RATIO 0.1, volumes 0.75 x (cast 0.5, sustain 1, disperse 0.2).
const MARGIN := 1.2
const VISIBILITY := 200.0 / 255.0
const FADE_IN := 800.0 / 255.0
const FADE_OUT := 500.0 / 255.0
const RIM_VERTICES := 100
const SPARKLES_PER_SECOND := 200.0
const SPARKLE_LIFE := 0.2
const SPARKLE_SIZE := 0.1
const BASE_VOLUME := 0.75
## Quieter and shorter than the addon (dev 2026-10-02: "make the magic sound fade out quickly and
## be more subtle and less loud"): everything at SOUND_SCALE, and the sustain hum fades to silence
## over SUSTAIN_FADE seconds after the cast instead of looping while the thing is held.
const SOUND_SCALE := 0.45
const SUSTAIN_FADE := 1.0
var target: Node3D
var color := Color(1.0, 0.0, 0.588)
var radius := 0.2
## 1 for magic seen from outside; less on the player's own held thing, which floats a hand's
## breadth from her eyes (dev 2026-10-02 first person: the full aura filled the view).
var strength := 1.0
## No cast, hum or disperse sound: the always-on VR magic hands (player/magic_hands/) use the
## same aura as a small wisp and would otherwise chime every time they appear.
var silent := false
var _centre_local := Vector3.ZERO
var _alpha := 0.0
var _casting := true
var _disc: MeshInstance3D
var _material: ShaderMaterial
var _sparkles: GPUParticles3D
var _sustain: AudioStreamPlayer3D
var _fixed_radius := -1.0
var _visual_layer := 1

static var _fan: ArrayMesh

## An aura on `thing` in `magic_color`, added to the scene (it follows the thing, not its parent).
## No class_name: a new global class needs an editor scan before a plain run can see it.
## `quiet` makes it silent (see `silent`).
static func create(thing: Node3D, magic_color: Color, aura_strength := 1.0, fixed_radius := -1.0, quiet := false) -> Node3D:
	if not is_instance_valid(thing) or not thing.is_inside_tree(): return null
	var aura: Node3D = (load("res://world/characters/magic/magic_aura.gd") as GDScript).new()
	aura.name = "MagicAura"
	aura.set("silent", quiet)
	aura.set("target", thing)
	aura.set("color", Color(magic_color, 1.0))
	aura.set("strength", clampf(aura_strength, 0.05, 1.0))
	aura.set("_fixed_radius", fixed_radius)
	var scene: Node = thing.get_tree().current_scene
	if scene == null: scene = thing.get_tree().root
	scene.add_child(aura)
	return aura

## Fade out with the disperse sound, then free.
func is_magic_aura() -> bool:
	return true

func set_visual_layer(layer: int) -> void:
	_visual_layer = layer
	if is_instance_valid(_disc): _disc.layers = layer
	if is_instance_valid(_sparkles): _sparkles.layers = layer

func release() -> void:
	if not _casting: return
	_casting = false
	if is_instance_valid(_sustain): _sustain.stop()
	if not silent: _play(DISPERSE, 0.12, 1.0)
	if is_instance_valid(_sparkles): _sparkles.emitting = false

func _ready() -> void:
	top_level = true
	_measure()
	_disc = MeshInstance3D.new()
	_disc.name = "Disc"
	_disc.layers = _visual_layer
	_disc.mesh = _fan_mesh()
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("gradient", GRADIENT)
	_material.set_shader_parameter("aura_color", color)
	_material.set_shader_parameter("alpha", 0.0)
	_material.render_priority = 100
	_disc.material_override = _material
	_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The fan turns to face the camera in its shader: bounds for any facing.
	_disc.custom_aabb = AABB(-Vector3.ONE * 1.2, Vector3.ONE * 2.4)
	add_child(_disc)
	_sparkles = _make_sparkles()
	_sparkles.layers = _visual_layer
	add_child(_sparkles)
	_place()
	if silent: return
	_play(CAST, 0.5, randf_range(0.95, 1.1))
	_sustain = _play(SUSTAIN, 0.6, 1.0)
	var fade := create_tween()
	fade.tween_property(_sustain, "volume_db", -60.0, SUSTAIN_FADE)
	fade.tween_callback(_sustain.stop)

func _process(delta: float) -> void:
	if _casting and not is_instance_valid(target): release()
	_alpha = move_toward(_alpha, VISIBILITY * strength if _casting else 0.0, (FADE_IN if _casting else FADE_OUT) * delta)
	_material.set_shader_parameter("alpha", _alpha)
	if not _casting and _alpha <= 0.0 and (not is_instance_valid(_sparkles) or not _sparkles.emitting):
		queue_free()
		return
	_place()

## The thing's bounding radius and centre, from its meshes at the moment it is lifted.
func _measure() -> void:
	if not is_instance_valid(target): return
	if _fixed_radius > 0.0:
		# Callers clamp their own sizes (horn and bursts to 5 cm); the VR wisps are smaller.
		radius = maxf(_fixed_radius, .01)
		_centre_local = Vector3.ZERO
		return
	var box := AABB()
	var first := true
	var items: Array = target.find_children("*", "VisualInstance3D", true, false)
	if target is VisualInstance3D: items.append(target)
	for node: Node in items:
		var visual := node as VisualInstance3D
		if not visual.is_visible_in_tree() or visual is GPUParticles3D or visual is Light3D: continue
		var world_box := visual.global_transform * visual.get_aabb()
		box = world_box if first else box.merge(world_box)
		first = false
	if first: box = AABB(target.global_position - Vector3.ONE * 0.1, Vector3.ONE * 0.2)
	radius = maxf(box.size.length() * 0.5 * MARGIN, 0.05)
	_centre_local = target.global_transform.affine_inverse() * box.get_center()

func _place() -> void:
	if is_instance_valid(target): global_position = target.global_transform * _centre_local
	_disc.scale = Vector3.ONE * radius

func _make_sparkles() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "Sparkles"
	particles.amount = maxi(4, int(SPARKLES_PER_SECOND * SPARKLE_LIFE * strength))
	particles.lifetime = SPARKLE_LIFE
	particles.local_coords = true
	particles.visibility_aabb = AABB(-Vector3.ONE * radius * 1.5, Vector3.ONE * radius * 3.0)
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
	process.emission_sphere_radius = radius
	process.gravity = Vector3.ZERO
	process.angle_min = 0.0; process.angle_max = 360.0
	process.anim_offset_min = 0.0; process.anim_offset_max = 1.0
	var shrink := Curve.new(); shrink.add_point(Vector2(0, 1)); shrink.add_point(Vector2(1, 0))
	var shrink_texture := CurveTexture.new(); shrink_texture.curve = shrink
	process.scale_curve = shrink_texture
	particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * radius * SPARKLE_SIZE * 2.0
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.particles_anim_h_frames = 3
	material.particles_anim_v_frames = 1
	material.albedo_texture = SPARKLES
	material.render_priority = 101
	material.disable_fog = true
	quad.material = material
	particles.draw_pass_1 = quad
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.emitting = true
	return particles

func _play(stream: AudioStream, volume: float, pitch: float) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.volume_db = linear_to_db(BASE_VOLUME * SOUND_SCALE * volume * strength)
	player.pitch_scale = pitch
	player.unit_size = 4.0
	var settings := get_node_or_null("/root/Settings")
	if settings != null and settings.has_method("route"): settings.route(player, "SFX")
	add_child(player)
	player.play()
	if stream != SUSTAIN: player.finished.connect(player.queue_free)
	return player

static func _fan_mesh() -> ArrayMesh:
	if _fan != null: return _fan
	var verts := PackedVector3Array(); var uvs := PackedVector2Array(); var angles := PackedVector2Array()
	verts.append(Vector3.ZERO); uvs.append(Vector2(1.0, 0.5)); angles.append(Vector2.ZERO)
	for i in RIM_VERTICES + 1:
		var a := TAU * float(i) / float(RIM_VERTICES)
		verts.append(Vector3(sin(a), cos(a), 0.0)); uvs.append(Vector2(0.0, 0.5)); angles.append(Vector2(a, 0.0))
	var indices := PackedInt32Array()
	for i in RIM_VERTICES: indices.append_array([0, i + 1, i + 2])
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts; arrays[Mesh.ARRAY_TEX_UV] = uvs; arrays[Mesh.ARRAY_TEX_UV2] = angles
	arrays[Mesh.ARRAY_INDEX] = indices
	_fan = ArrayMesh.new()
	_fan.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return _fan
