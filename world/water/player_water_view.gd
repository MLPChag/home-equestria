extends Node3D
## Camera-owned water presentation, independent of swimming/flight controls.
## One water-layer ray per physics tick; no scene scans, screen copies or camera motion.
const WATER := preload("res://world/water/water_contact.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const CATALOGUE := preload("res://world/audio/environment_catalogue.gd")
var body: Node3D
var surface := -INF
var immersion := 0.0
var submerged := false
var splash_count := 0
var _camera: Camera3D
var _clock: Node
var _overlay: MeshInstance3D
var _material: ShaderMaterial
var _ripple: MeshInstance3D
var _ripple_material: ShaderMaterial
var _ripple_age := 2.0
var _previous_feet := Vector3.INF
var _was_in_water := false
var _water_travel := 0.0
var _water_sound_wait := 0.0


func _ready() -> void:
	SOUNDS.register_catalogue(self, CATALOGUE.EVENTS)
	_camera = get_parent() as Camera3D
	_clock = get_node_or_null("/root/TimeOfDay")
	if _camera == null:
		set_physics_process(false)
		set_process(false)
		return
	_overlay = MeshInstance3D.new()
	_overlay.name = "UnderwaterHaze"
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	quad.flip_faces = true
	_overlay.mesh = quad
	_material = ShaderMaterial.new()
	_material.shader = preload("res://world/water/underwater_view.gdshader")
	_material.render_priority = 127
	_overlay.material_override = _material
	_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_overlay.extra_cull_margin = 16384.0
	# Same priority as ink; smaller sorting distance draws water over the outline.
	_overlay.sorting_offset = -1000.0
	add_child(_overlay)
	_overlay.hide()
	_ripple = MeshInstance3D.new()
	_ripple.name = "WaterEntryRipple"
	var plane := PlaneMesh.new()
	plane.size = Vector2(3.6, 3.6)
	plane.subdivide_width = 32
	plane.subdivide_depth = 32
	_ripple.mesh = plane
	_ripple_material = ShaderMaterial.new()
	_ripple_material.shader = preload("res://world/water/entry_ripple.gdshader")
	_ripple_material.render_priority = 10
	_ripple.material_override = _ripple_material
	_ripple.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ripple)
	_ripple.top_level = true
	_ripple.hide()


func _physics_process(delta: float) -> void:
	var eye := _camera.global_position
	var feet := body.global_position if is_instance_valid(body) else eye
	if not eye.is_finite() or not feet.is_finite(): return
	# Query below the feet so we also see a surface just before body entry.
	var probe := Vector3(eye.x, minf(eye.y, feet.y) - 0.4, eye.z)
	surface = WATER.surface_above(get_world_3d().direct_space_state, probe)
	var has_water := is_finite(surface)
	var depth := surface - eye.y if has_water else -INF
	# Centimetre hysteresis avoids flickering when bobbing at the surface.
	submerged = depth > (-0.015 if submerged else 0.015)
	if has_water:
		_material.set_shader_parameter("surface_y", surface)
	var in_water := has_water and feet.y < surface - 0.08
	_water_sound_wait = maxf(0.0, _water_sound_wait - delta)
	if in_water and not _was_in_water and _previous_feet.is_finite():
		var movement := feet - _previous_feet
		# Loading/teleporting underwater is not a jump. Body entry works with the head dry.
		if movement.length() < 2.0 and movement.length() / maxf(delta, 0.001) > 0.4:
			entry(Vector3(eye.x, surface + 0.045, eye.z), clampf(-movement.y / maxf(delta, 0.001) / 4.0, 0.45, 1.0))
			_water_sound_wait = 1.0
	# A quiet paddle is earned by actual body travel, with a gap between strokes.
	# Grounded shallows already use the planted-foot water contacts; still treading is quiet.
	if in_water and _was_in_water and _previous_feet.is_finite():
		var movement := feet - _previous_feet
		var grounded := is_instance_valid(body) and body.has_method("is_on_floor") and bool(body.call("is_on_floor"))
		if grounded or movement.length() > .75: _water_travel = 0.0
		else: _water_travel += Vector2(movement.x, movement.z).length()
		if _water_travel >= .85 and _water_sound_wait <= 0.0:
			SOUNDS.play_event(self, "env_wade", {"intensity": .6 if submerged else 1.0}, Vector3(eye.x, surface, eye.z))
			_water_travel = 0.0
			_water_sound_wait = 1.2
	else: _water_travel = 0.0
	_was_in_water = in_water
	_previous_feet = feet


func _process(delta: float) -> void:
	immersion = move_toward(immersion, 1.0 if submerged else 0.0, delta * 10.0)
	_overlay.visible = immersion > 0.001
	if _overlay.visible:
		_material.set_shader_parameter("immersion", immersion)
		_material.set_shader_parameter("daylight", float(_clock.call("daylight")) if is_instance_valid(_clock) else 1.0)
	if _ripple_age < 1.4:
		_ripple_age += delta
		_ripple_material.set_shader_parameter("age", _ripple_age)
		_ripple.visible = _ripple_age < 1.4


func entry(at: Vector3, strength: float) -> void:
	_ripple.global_position = at
	_ripple_age = 0.0
	_ripple_material.set_shader_parameter("age", 0.0)
	_ripple_material.set_shader_parameter("strength", strength)
	_ripple.show()
	splash_count += 1
	SOUNDS.play_event(self, "env_splash", {"intensity": clampf(strength, .25, 1.0)}, at)
