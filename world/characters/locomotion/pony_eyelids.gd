extends RefCounted
## Eyelids. The lid itself is drawn by the eye shader (g_lid_closure: the top
## of the eye above that line takes the coat-shadow colour, guide "shadow fill"
## #8CC7E7), so it hugs the eye surface with a crisp edge at any closure. The
## native black lash strips slide down with it. Blink 3-7 s apart, a squint
## when she is lifted, a lazy half-lid when idle or glancing at the player.
## (dev, 2026-09-06: "they need to BLINK ... an eyelid that she sometimes
## half-lids for expression".)

const LID_COLOR := Color("8CC7E7")

var closure := 0.0
var half_lid := 0.0
var _blink_timer := 3.0
var _blink_phase := -1.0
var _squint := 0.0
var _materials: Array[ShaderMaterial] = []
var _lash_pivots: Array[Node3D] = []
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	# From the global generator: random in game, repeatable in a test that calls seed().
	_rng.seed = randi()


## Register one eye: its shader material and the lash strips that ride the lid.
## `up_head` is rest-frame up in head space; `travel` is how far (m) the lash
## line drops at full closure.
func add_eye(mount: Node3D, white: MeshInstance3D, mat: ShaderMaterial, lashes: Array, up_head: Vector3, travel: float) -> void:
	mat.set_shader_parameter("g_lid_color", LID_COLOR)
	_materials.append(mat)
	var pivot := Node3D.new()
	pivot.name = white.name.replace("Eye white", "LashPivot")
	pivot.set_meta("drop", -up_head.normalized() * travel)
	mount.add_child(pivot)
	for lash in lashes:
		var l := lash as Node3D
		if l == null:
			continue
		var t := l.transform
		l.get_parent().remove_child(l)
		l.transform = t
		pivot.add_child(l)
	_lash_pivots.append(pivot)
	_apply()


## Fire a blink now (tests, reactions).
func blink() -> void:
	_blink_phase = 0.0


## A quick squint, used when she is picked up.
func squint(seconds: float = 0.4) -> void:
	_squint = seconds


func update(delta: float, idle_seconds: float, moving: bool, glancing: bool) -> void:
	_blink_timer -= delta
	if _blink_timer <= 0.0 and _blink_phase < 0.0:
		_blink_phase = 0.0
		_blink_timer = _rng.randf_range(3.0, 7.0)
	var blink := 0.0
	if _blink_phase >= 0.0:
		_blink_phase += delta
		# 120 ms down, 160 ms up.
		blink = smoothstep(0.0, 0.12, _blink_phase) if _blink_phase < 0.12 else 1.0 - smoothstep(0.12, 0.28, _blink_phase)
		if _blink_phase >= 0.28:
			_blink_phase = -1.0
			blink = 0.0
	_squint = maxf(_squint - delta, 0.0)
	var wanted_half := 0.0
	if not moving and (idle_seconds > 6.0 or glancing):
		wanted_half = 0.35
	half_lid = move_toward(half_lid, wanted_half, delta / 0.6)
	var squint := 0.5 if _squint > 0.0 else 0.0
	closure = maxf(blink, maxf(half_lid, squint))
	_apply()


func _apply() -> void:
	# In card mode pony_locomotion pushes `closure` itself; these lists are empty.
	for mat in _materials:
		mat.set_shader_parameter("g_lid_closure", closure)
	for pivot in _lash_pivots:
		pivot.position = (pivot.get_meta("drop") as Vector3) * closure
