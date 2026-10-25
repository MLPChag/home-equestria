extends Node3D
## Being bucked (dev 2026-09-28): ringing in the ears and a black vignette flash around the eyes.
## A camera-attached quad (both XR eyes see it) and a non-positional ring that fades over 3 s.
const SECONDS := 3.2
static var _ring: AudioStreamWAV
var _started_ms := 0
var _quad: MeshInstance3D
var _material: ShaderMaterial

static func play(camera: Camera3D) -> void:
	if not is_instance_valid(camera): return
	var old := camera.get_node_or_null("BuckDaze")
	if old != null: old.queue_free()
	var daze := preload("res://player/buck_daze.gd").new()
	daze.name = "BuckDaze"
	camera.add_child(daze)

func _ready() -> void:
	# Real time, always processed: a pause or a disabled rig must never leave the dark on his eyes.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_ms = Time.get_ticks_msec()
	_material = ShaderMaterial.new()
	_material.shader = preload("res://player/buck_vignette.gdshader")
	_material.render_priority = 127
	_quad = MeshInstance3D.new()
	var plane := QuadMesh.new(); plane.size = Vector2(0.9, 0.7)
	_quad.mesh = plane
	_quad.material_override = _material
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.position = Vector3(0, 0, -0.12)
	add_child(_quad)
	var ring := AudioStreamPlayer.new()
	ring.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	ring.stream = _ring_stream()
	ring.volume_db = -12.0
	add_child(ring)
	ring.play()

func _process(_delta: float) -> void:
	var time := (Time.get_ticks_msec() - _started_ms) / 1000.0
	# Black at once, a dark ring lingering, then gone.
	var darkness := 1.0 - smoothstep(0.08, SECONDS * 0.6, time)
	_material.set_shader_parameter("amount", darkness)
	if time >= SECONDS: queue_free()

## A dull thump, then a soft high ring that fades (tinnitus), well under the game's other sounds.
static func _ring_stream() -> AudioStreamWAV:
	if _ring != null: return _ring
	var rate := 22050
	var count := int(rate * SECONDS)
	var bytes := PackedByteArray(); bytes.resize(count * 2)
	for i in count:
		var t := float(i) / rate
		var thump := sin(TAU * 58.0 * t) * exp(-t / 0.12) * 0.7
		var ring := (sin(TAU * 3150.0 * t) + 0.5 * sin(TAU * 3156.0 * t)) * 0.16 * (1.0 - exp(-t / 0.25)) * exp(-t / 0.9)
		bytes.encode_s16(i * 2, roundi(clampf(thump + ring, -1.0, 1.0) * 32767))
	_ring = AudioStreamWAV.new()
	_ring.format = AudioStreamWAV.FORMAT_16_BITS
	_ring.mix_rate = rate
	_ring.data = bytes
	return _ring
