extends Node3D
## A breath of Spike's green dragon fire. Rides his mouth for the length of the breath, then frees
## itself. Given a letter (a physical scroll or note), the flame turns it to green sparks and it is
## gone: sent to Princess Celestia.

const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const BREATH_DELAY := 0.95
const BREATH := 1.0

var _spike: Node3D
var _flame: CPUParticles3D
var _light: OmniLight3D

func start(spike: Node3D, letter: Node3D = null) -> void:
	_spike = spike
	_flame = CPUParticles3D.new()
	_flame.emitting = false
	_flame.amount = 70
	_flame.lifetime = 0.45
	_flame.explosiveness = 0.0
	_flame.direction = Vector3(0, 0.15, -1)
	_flame.spread = 14.0
	_flame.initial_velocity_min = 1.2
	_flame.initial_velocity_max = 2.0
	_flame.gravity = Vector3(0, 1.2, 0)
	_flame.scale_amount_min = 0.5
	_flame.scale_amount_max = 1.1
	var curve := Curve.new(); curve.add_point(Vector2(0, 0.4)); curve.add_point(Vector2(0.3, 1.0)); curve.add_point(Vector2(1, 0.0))
	_flame.scale_amount_curve = curve
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.85, 1.0, 0.6, 1.0))
	ramp.set_color(1, Color(0.1, 0.75, 0.25, 0.0))
	ramp.add_point(0.45, Color(0.35, 0.95, 0.35, 0.85))
	_flame.color_ramp = ramp
	var quad := QuadMesh.new(); quad.size = Vector2(0.07, 0.07)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = _soft_dot()
	quad.material = material
	_flame.mesh = quad
	add_child(_flame)
	_light = OmniLight3D.new(); _light.light_color = Color(0.4, 1.0, 0.45); _light.omni_range = 1.6; _light.light_energy = 0.0
	add_child(_light)
	_run(letter)

func _soft_dot() -> Texture2D:
	var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		for x in 16:
			var d := Vector2(x - 7.5, y - 7.5).length() / 7.5
			image.set_pixel(x, y, Color(1, 1, 1, clampf(1.0 - d, 0.0, 1.0) ** 1.5))
	return ImageTexture.create_from_image(image)

func _process(_delta: float) -> void:
	if not is_instance_valid(_spike): return
	var mouth: Vector3 = _spike.global_transform * (Vector3(0, 0.43, -0.28) * float(_spike.get("body_scale")))
	global_transform = Transform3D(_spike.global_basis.orthonormalized(), mouth)

func _run(letter: Node3D) -> void:
	if not await SHUTDOWN.seconds(self, BREATH_DELAY): return
	_flame.emitting = true
	_light.light_energy = 1.4
	if letter != null and is_instance_valid(letter):
		var sparks := CPUParticles3D.new()
		sparks.one_shot = true; sparks.amount = 40; sparks.lifetime = 0.9; sparks.explosiveness = 0.9
		sparks.direction = Vector3.UP; sparks.spread = 60.0; sparks.initial_velocity_min = 0.4; sparks.initial_velocity_max = 1.2
		sparks.gravity = Vector3(0, 0.6, 0); sparks.mesh = _flame.mesh; sparks.color = Color(0.4, 1.0, 0.45)
		_spike.get_parent().add_child(sparks)
		sparks.global_position = letter.global_position
		sparks.emitting = true
		letter.queue_free()
		sparks.finished.connect(sparks.queue_free)
	if not await SHUTDOWN.seconds(self, BREATH): return
	_flame.emitting = false
	_light.light_energy = 0.0
	if not await SHUTDOWN.seconds(self, 0.6): return
	queue_free()
