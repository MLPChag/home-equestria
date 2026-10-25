extends RefCounted
## One-shot stage effects for Trixie's show: smoke puffs, spark fountains, confetti, fireworks,
## feather puffs and spotlights. Every effect frees itself; particle amounts follow the quality
## tier (Quality "weather_particle_scale": thinned on low tiers, never switched off).

const SOUNDS := preload("res://world/audio/interaction_sounds.gd")

static func scale() -> float:
	var quality := Engine.get_main_loop().root.get_node_or_null("/root/Quality") as Node
	return float(quality.get_value("weather_particle_scale", 1.0)) if quality != null else 1.0

static func _dot_texture() -> Texture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1)); gradient.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient; tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5); tex.fill_to = Vector2(0.5, 0.0); tex.width = 64; tex.height = 64
	return tex

static func _material(additive: bool, texture: Texture2D = null) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = texture if texture != null else _dot_texture()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

## A GPUParticles3D that removes itself once its particles are gone.
static func _emitter(parent: Node, at: Vector3, amount: int, lifetime: float, process: ParticleProcessMaterial, quad_size: float, mat: Material, one_shot := true) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = maxi(4, int(amount * scale()))
	p.lifetime = lifetime
	p.one_shot = one_shot
	p.explosiveness = 1.0 if one_shot else 0.0
	p.process_material = process
	p.visibility_aabb = AABB(Vector3(-12, -12, -12), Vector3(24, 24, 24))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new(); quad.size = Vector2(quad_size, quad_size); quad.material = mat
	p.draw_pass_1 = quad
	parent.add_child(p)
	p.global_position = at
	p.emitting = true
	if one_shot:
		p.finished.connect(p.queue_free)
	return p

static func _ramp(a: Color, b: Color) -> GradientTexture1D:
	var g := Gradient.new(); g.set_color(0, a); g.set_color(1, b)
	var t := GradientTexture1D.new(); t.gradient = g
	return t

## A soft cloud of smoke (or magic smoke in `tint`).
static func puff(parent: Node, at: Vector3, tint := Color(0.85, 0.85, 0.9), size := 1.0) -> void:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE; m.emission_sphere_radius = 0.3 * size
	m.direction = Vector3.UP; m.spread = 180.0
	m.initial_velocity_min = 0.6 * size; m.initial_velocity_max = 1.8 * size
	m.gravity = Vector3(0, 0.4, 0); m.damping_min = 1.5; m.damping_max = 2.5
	m.scale_min = 1.0; m.scale_max = 2.2
	var curve := CurveTexture.new(); var c := Curve.new(); c.add_point(Vector2(0, 0.4)); c.add_point(Vector2(1, 1.6)); curve.curve = c
	m.scale_curve = curve
	m.color_ramp = _ramp(Color(tint, 0.85), Color(tint, 0.0))
	_emitter(parent, at, 40, 1.8, m, 0.9 * size, _material(false))

## A fountain of sparks for `seconds`.
static func sparks(parent: Node, at: Vector3, seconds: float, tint := Color(1.0, 0.85, 0.4)) -> void:
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3.UP; m.spread = 14.0
	m.initial_velocity_min = 4.5; m.initial_velocity_max = 6.5
	m.gravity = Vector3(0, -9.0, 0)
	m.scale_min = 0.4; m.scale_max = 0.9
	m.color_ramp = _ramp(Color(tint, 1.0), Color(tint.lightened(0.3), 0.0))
	var p := _emitter(parent, at, 160, 1.1, m, 0.07, _material(true), false)
	var timer := p.get_tree().create_timer(seconds)
	timer.timeout.connect(func() -> void:
		if not is_instance_valid(p): return
		p.emitting = false
		p.get_tree().create_timer(p.lifetime + 0.2).timeout.connect(func() -> void: if is_instance_valid(p): p.queue_free()))

## Confetti burst upward that flutters down.
static func confetti(parent: Node, at: Vector3, up := Vector3.UP, power := 1.0) -> void:
	var m := ParticleProcessMaterial.new()
	m.direction = up.normalized(); m.spread = 28.0
	m.initial_velocity_min = 6.0 * power; m.initial_velocity_max = 10.0 * power
	m.gravity = Vector3(0, -3.0, 0); m.damping_min = 2.0; m.damping_max = 3.5
	m.angle_min = 0.0; m.angle_max = 360.0; m.angular_velocity_min = -360.0; m.angular_velocity_max = 360.0
	m.turbulence_enabled = true; m.turbulence_noise_strength = 0.6; m.turbulence_influence_min = 0.05; m.turbulence_influence_max = 0.15
	m.hue_variation_min = -1.0; m.hue_variation_max = 1.0
	m.color = Color(1.0, 0.45, 0.6)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	var p := _emitter(parent, at, 220, 5.0, m, 0.07, mat)
	(p.draw_pass_1 as QuadMesh).size = Vector2(0.06, 0.035)

## White feathers spilling out (the doves' hat).
static func feathers(parent: Node, at: Vector3) -> void:
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3.UP; m.spread = 70.0
	m.initial_velocity_min = 1.0; m.initial_velocity_max = 2.5
	m.gravity = Vector3(0, -0.6, 0); m.damping_min = 1.0; m.damping_max = 1.6
	m.angle_min = 0.0; m.angle_max = 360.0; m.angular_velocity_min = -120.0; m.angular_velocity_max = 120.0
	m.turbulence_enabled = true; m.turbulence_noise_strength = 0.5
	m.color_ramp = _ramp(Color(1, 1, 1, 1), Color(1, 1, 1, 0))
	var mat := _material(false)
	var p := _emitter(parent, at, 30, 3.5, m, 0.06, mat)
	(p.draw_pass_1 as QuadMesh).size = Vector2(0.03, 0.07)

## One firework: a rocket climbs from `from` to `apex`, then bursts in `tint`. The boom arrives
## after the flash, delayed by the distance to `listener`.
static func firework(parent: Node, from: Vector3, apex: Vector3, tint: Color, listener: Node3D = null) -> void:
	var rocket := Node3D.new(); rocket.name = "FireworkRocket"
	parent.add_child(rocket); rocket.global_position = from
	var tm := ParticleProcessMaterial.new()
	tm.direction = Vector3.DOWN; tm.spread = 10.0
	tm.initial_velocity_min = 0.5; tm.initial_velocity_max = 1.2
	tm.gravity = Vector3(0, -2.0, 0)
	tm.color_ramp = _ramp(Color(1.0, 0.8, 0.5, 1.0), Color(1.0, 0.5, 0.2, 0.0))
	var trail := _emitter(rocket, from, 60, 0.6, tm, 0.08, _material(true), false)
	trail.local_coords = false
	SOUNDS.play_at(rocket, "show_whoosh", from)
	var climb := rocket.create_tween()
	climb.tween_property(rocket, "global_position", apex, 1.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	climb.tween_callback(func() -> void:
		trail.emitting = false
		_burst(parent, apex, tint)
		var delay := 0.0
		if is_instance_valid(listener): delay = listener.global_position.distance_to(apex) / 343.0
		parent.get_tree().create_timer(delay).timeout.connect(func() -> void:
			if is_instance_valid(parent) and parent is Node3D: SOUNDS.play_at(parent as Node3D, "show_firework", apex))
		rocket.get_tree().create_timer(1.0).timeout.connect(rocket.queue_free))

static func _burst(parent: Node, at: Vector3, tint: Color) -> void:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE; m.emission_sphere_radius = 0.15
	m.direction = Vector3.UP; m.spread = 180.0
	m.initial_velocity_min = 6.0; m.initial_velocity_max = 8.0
	m.gravity = Vector3(0, -2.5, 0); m.damping_min = 2.2; m.damping_max = 3.0
	m.color_ramp = _ramp(Color(tint.lightened(0.15), 1.0), Color(tint, 0.0))
	_emitter(parent, at, 180, 1.8, m, 0.32, _material(true))
	var flash := OmniLight3D.new()
	flash.light_color = tint; flash.omni_range = 30.0; flash.light_energy = 0.0; flash.shadow_enabled = false
	parent.add_child(flash); flash.global_position = at
	var t := flash.create_tween()
	t.tween_property(flash, "light_energy", 6.0, 0.06)
	t.tween_property(flash, "light_energy", 0.0, 0.7)
	t.tween_callback(flash.queue_free)

## A stage spotlight at `from` aimed at `target`, faded in; returns it so the show can fade it out.
static func spotlight(parent: Node, from: Vector3, target: Vector3, tint := Color(1.0, 0.95, 0.85)) -> SpotLight3D:
	var light := SpotLight3D.new()
	light.light_color = tint; light.spot_range = from.distance_to(target) + 6.0; light.spot_angle = 14.0
	light.light_energy = 0.0; light.shadow_enabled = false
	parent.add_child(light)
	light.look_at_from_position(from, target, Vector3.UP)
	light.create_tween().tween_property(light, "light_energy", 9.0, 0.4)
	return light

static func fade_out(light: Light3D, seconds := 0.6) -> void:
	if not is_instance_valid(light): return
	var t := light.create_tween()
	t.tween_property(light, "light_energy", 0.0, seconds)
	t.tween_callback(light.queue_free)
