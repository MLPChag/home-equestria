extends Node3D
## Rainbow Dash's trail (dev 2026-09-26): a ribbon of the six rainbow bands left behind her when
## she flies fast, fading over a second and a half, and the sonic rainboom: an expanding rainbow
## ring with a boom when she breaks the sound barrier. Fed by pony_flight.gd every tick.

const BANDS := [Color("ff3a30"), Color("ff9a1f"), Color("ffe02e"), Color("5ed63a"), Color("2f8dff"), Color("9a4dff")]
const LIFE := 1.6
const STEP := 0.025
const WIDTH := 0.55
const BOOM_SECONDS := 1.6
const BOOM_RADIUS := 70.0

var _points: Array = []          # {pos, dir, t}
var _trail := MeshInstance3D.new()
var _mesh := ImmediateMesh.new()
var _material := StandardMaterial3D.new()
var _booms: Array = []           # {pos, normal, t}
var _boom_mesh := ImmediateMesh.new()
var _boom_node := MeshInstance3D.new()
var _scale := 1.0
var _emitting := false

func _ready() -> void:
	top_level = true
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.vertex_color_is_srgb = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.no_depth_test = false
	for node: MeshInstance3D in [_trail, _boom_node]:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.material_override = _material
		add_child(node)
	_trail.mesh = _mesh
	_boom_node.mesh = _boom_mesh

## Her position (trail height), velocity, and whether she is fast enough to leave a trail.
func feed(at: Vector3, velocity: Vector3, emitting: bool, body_scale: float) -> void:
	_scale = body_scale
	_emitting = emitting
	var now := Time.get_ticks_msec() / 1000.0
	if emitting and velocity.length() > 0.1 and (_points.is_empty() or now - float(_points[-1].t) >= STEP):
		_points.append({"pos": at, "dir": velocity.normalized(), "t": now})

## The sonic rainboom: a rainbow ring across her path, growing and fading, and the boom.
func rainboom(at: Vector3, velocity: Vector3) -> void:
	_booms.append({"pos": at, "normal": velocity.normalized() if velocity.length() > 0.1 else Vector3.FORWARD, "t": Time.get_ticks_msec() / 1000.0})
	var boom := AudioStreamPlayer3D.new()
	boom.stream = _make_boom()
	boom.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	boom.unit_size = 60.0
	boom.max_distance = 4000.0
	boom.volume_db = 4.0
	add_child(boom)
	boom.global_position = at
	boom.play()
	boom.finished.connect(boom.queue_free)

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	while not _points.is_empty() and now - float(_points[0].t) > LIFE: _points.pop_front()
	_draw_trail(now)
	_draw_booms(now)
	if _points.is_empty() and _booms.is_empty() and not _emitting: queue_free()

func _camera_pos() -> Vector3:
	var cam := preload("res://world/player_view.gd").camera(self)
	return cam.global_position if cam != null else Vector3.ZERO

## Six bands side by side; the ribbon turns to face the viewer along its length.
func _draw_trail(now: float) -> void:
	_mesh.clear_surfaces()
	if _points.size() < 2: return
	var eye := _camera_pos()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(_points.size() - 1):
		var a: Dictionary = _points[i]
		var b: Dictionary = _points[i + 1]
		var age_a := clampf((now - float(a.t)) / LIFE, 0.0, 1.0)
		var age_b := clampf((now - float(b.t)) / LIFE, 0.0, 1.0)
		var side_a := _side(a, eye) * WIDTH * _scale * (1.0 + age_a * 0.8)
		var side_b := _side(b, eye) * WIDTH * _scale * (1.0 + age_b * 0.8)
		for band in BANDS.size():
			var f0 := float(band) / BANDS.size() - 0.5
			var f1 := float(band + 1) / BANDS.size() - 0.5
			var ca: Color = BANDS[band]; ca.a = (1.0 - age_a) * 0.85
			var cb: Color = BANDS[band]; cb.a = (1.0 - age_b) * 0.85
			var pa: Vector3 = a.pos
			var pb: Vector3 = b.pos
			_quad(_mesh, pa + side_a * f0, pa + side_a * f1, pb + side_b * f1, pb + side_b * f0, ca, ca, cb, cb)
	_mesh.surface_end()

func _side(point: Dictionary, eye: Vector3) -> Vector3:
	var dir: Vector3 = point.dir
	var side := dir.cross(eye - (point.pos as Vector3))
	if side.length_squared() < 1e-6: side = dir.cross(Vector3.UP)
	return side.normalized()

func _draw_booms(now: float) -> void:
	_boom_mesh.clear_surfaces()
	var alive: Array = []
	for boom: Dictionary in _booms:
		var t := (now - float(boom.t)) / BOOM_SECONDS
		if t < 1.0: alive.append(boom)
	_booms = alive
	if _booms.is_empty(): return
	_boom_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for boom: Dictionary in _booms:
		var t := clampf((now - float(boom.t)) / BOOM_SECONDS, 0.0, 1.0)
		var radius := lerpf(2.0, BOOM_RADIUS, 1.0 - pow(1.0 - t, 3.0)) * _scale
		var band_w := radius * 0.05
		var n: Vector3 = boom.normal
		var u := n.cross(Vector3.UP)
		if u.length_squared() < 1e-6: u = n.cross(Vector3.RIGHT)
		u = u.normalized()
		var v := n.cross(u).normalized()
		var segments := 72
		for band in BANDS.size():
			var r0 := radius - band_w * (band + 1)
			var r1 := radius - band_w * band
			var c: Color = BANDS[band]; c.a = (1.0 - t) * 0.9
			for k in segments:
				var a0 := TAU * k / segments
				var a1 := TAU * (k + 1) / segments
				var d0 := u * cos(a0) + v * sin(a0)
				var d1 := u * cos(a1) + v * sin(a1)
				var o: Vector3 = boom.pos
				_quad(_boom_mesh, o + d0 * r0, o + d0 * r1, o + d1 * r1, o + d1 * r0, c, c, c, c)
	_boom_mesh.surface_end()

static func _quad(mesh: ImmediateMesh, a: Vector3, b: Vector3, c: Vector3, d: Vector3, ca: Color, cb: Color, cc: Color, cd: Color) -> void:
	for pair in [[a, ca], [b, cb], [c, cc], [a, ca], [c, cc], [d, cd]]:
		mesh.surface_set_color(pair[1])
		mesh.surface_add_vertex(pair[0])

## A deep boom with a cracking front, made once.
static func _make_boom() -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * 1.6)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 340
	var low := 0.0
	for i in n:
		var t := float(i) / rate
		var env := exp(-t * 3.2) * minf(1.0, t * 400.0)
		low = lerpf(low, rng.randf_range(-1.0, 1.0), 0.04)
		var crack := rng.randf_range(-1.0, 1.0) * exp(-t * 30.0) * 0.5
		var thump := sin(TAU * 38.0 * t) * exp(-t * 4.0) * 0.6
		data.encode_s16(i * 2, int(clampf((low * 2.5 + crack + thump) * env, -1.0, 1.0) * 32767))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.data = data
	return wav
