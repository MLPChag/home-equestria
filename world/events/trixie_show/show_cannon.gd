extends Node
## The human cannonball (show_program.gd act "cannon"). Only when Anon watches from the crowd:
## Trixie wheels her cannon out beside the stage and asks him (AI line) to be fired out of it.
## The cannon gets the blue interaction outline; walking up to it means yes, staying away for
## ASK_SECONDS or walking off means no and Trixie shrugs it off. On yes he is loaded, a drum roll
## and fuse, a boom, and he flies a short arc over the crowd into a hay pile behind it, landing
## in the ordinary knockdown flop (player_knockdown.gd) to get up from. The player body is moved
## every physics tick (full rate). With Reduced motion on, the eyes close and open on the hay
## instead of flying.

const CANNON := preload("res://world/events/trixie_show/props/cannon.glb")
const HAY := preload("res://world/events/trixie_show/props/hay_pile.scn")
const FX := preload("res://world/events/trixie_show/show_fx.gd")
const OUTLINE := preload("res://world/ui/interact_outline.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const VIGNETTE := preload("res://player/buck_vignette.gdshader")
const COVER := preload("res://world/ui/sleep_cover.gd")
const CANNON_SCALE := 0.75
## In the cannon's own frame (props/cannon.glb, origin under the wheels): muzzle centre and the
## barrel's direction (forward and up).
const MUZZLE := Vector3(0.0, 2.944, 1.019)
const BARREL := Vector3(0.0, 0.72, 0.69)
const ASK_SECONDS := 25.0
const YES_RADIUS := 1.7
const WATCH_RANGE := 26.0
const FLIGHT_SECONDS := 2.4
const APEX := 6.0

var program: Node
var _cannon: Node3D
var _hay: Node3D
var _body: CharacterBody3D
var _flight_from := Vector3.ZERO
var _flight_to := Vector3.ZERO
var _flight_t := -1.0
var _vignette: MeshInstance3D
var _cover: Node
var _owns_body := false
var _body_was_processing := false
var _body_was_locked := false
var _body_before := Transform3D.IDENTITY
var _velocity_before := Vector3.ZERO
var _cancelled := false
## True while Trixie waits for his answer (labs walk up then).
var asking := false

func perform(p: Node) -> bool:
	program = p
	var runtime: Node = program.runtime
	var camera: Node3D = runtime._camera()
	var game: Node = runtime.game
	_body = (game.player.get_node_or_null("Body") if bool(game.get("xr_active")) else game.player) as CharacterBody3D
	if camera == null or _body == null: return false
	var front: Vector3 = runtime.stage_front()
	if camera.global_position.distance_to(front) > WATCH_RANGE or bool(_body.get("controls_locked")): return false
	var facing: Vector3 = runtime.facing()
	var side: Vector3 = facing.cross(Vector3.UP)
	# Rolled out from behind the stage to the ground beside it, aimed over the crowd.
	var rest := front + side * 4.2 + facing * 1.2
	rest.y = program._ground(rest)
	_flight_to = front + facing * 19.5 + side * 1.0
	_flight_to.y = program._ground(_flight_to)
	_hay = HAY.instantiate() as Node3D
	program._stage_set.add_child(_hay)
	_hay.global_position = _flight_to
	# She floats the hay over the crowd from behind the stage (nothing pops in).
	program._float_in(_hay, 0.0, 2.4, program._backstage() + Vector3.UP * 2.0)
	_cannon = CANNON.instantiate() as Node3D
	program._stage_set.add_child(_cannon)
	var aim := _flight_to - rest; aim.y = 0.0
	# The barrel points along the cannon's local +Z (glTF), so face that toward the hay.
	_cannon.global_basis = Basis.looking_at(-aim.normalized(), Vector3.UP).scaled(Vector3.ONE * CANNON_SCALE)
	_cannon.global_position = rest + side * 7.0 - facing * 6.0
	var roll := _cannon.create_tween()
	roll.tween_property(_cannon, "global_position", rest, 2.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	SOUNDS.play_at(_cannon, "prop_furniture", rest)
	if not await program._wait(2.8): return false
	program._line("cannon_ask")
	var meshes: Array[GeometryInstance3D] = OUTLINE.meshes(_cannon)
	for m: GeometryInstance3D in meshes: OUTLINE.set_amount(m, 1.0)
	var waited := 0.0
	var yes := false
	asking = true
	while waited < ASK_SECONDS:
		if not await program._wait(0.25): _clear_outline(meshes); return false
		waited += 0.25
		var at := _body.global_position
		if Vector2(at.x - rest.x, at.z - rest.z).length() < YES_RADIUS: yes = true; break
		if camera.global_position.distance_to(front) > WATCH_RANGE + 8.0: break
	asking = false
	_clear_outline(meshes)
	if not yes:
		program._line("cannon_declined")
		program._react("giggle", 3.0)
		await _wheel_away(rest + side * 7.0 - facing * 6.0)
		return true
	await _fire()
	if _cancelled or not program._alive: return false
	await _wheel_away(rest + side * 7.0 - facing * 6.0)
	return true

func _clear_outline(meshes: Array[GeometryInstance3D]) -> void:
	for m: GeometryInstance3D in meshes:
		if is_instance_valid(m): OUTLINE.set_amount(m, 0.0)

func _muzzle() -> Vector3:
	return _cannon.global_transform * MUZZLE

func _fire() -> void:
	if _cancelled or not is_instance_valid(_body): return
	_owns_body = true
	_body_was_processing = _body.is_physics_processing()
	_body_was_locked = bool(_body.get("controls_locked"))
	_body_before = _body.global_transform
	_velocity_before = _body.velocity
	_body.set("controls_locked", true)
	# Loaded: a puff and he is in the barrel.
	program._poof(_body.global_position + Vector3.UP * 0.9, 1.0)
	_flight_from = _muzzle() - Vector3.UP * 1.5
	_place_body(_flight_from)
	_body.set_physics_process(false)
	program._line("cannon_fire")
	# Drum roll (fuse sparks at the back of the barrel), then the boom.
	var fuse: Vector3 = _cannon.global_transform * Vector3(0.0, 1.2, -1.1)
	FX.sparks(program._stage_set, fuse, 2.2, Color(1.0, 0.7, 0.3))
	SOUNDS.play_at(_cannon, "prop_spray", fuse)
	if not await program._wait(2.4): cancel(); return
	_flight_to = _landing(_flight_to)
	var dir := (_cannon.global_basis.orthonormalized() * BARREL).normalized()
	FX.puff(program._stage_set, _muzzle(), Color(0.85, 0.85, 0.9), 1.8)
	FX.confetti(program._stage_set, _muzzle(), dir, 0.8)
	SOUNDS.play_at(_cannon, "show_boom", _muzzle())
	program._react("gasp", 2.5)
	var settings := get_node_or_null("/root/Settings")
	var reduced: bool = settings != null and bool(settings.get_value("access/reduced_motion"))
	if reduced:
		_cover = COVER.new(); _cover.name = "CannonCover"
		program.runtime.game.add_child(_cover); _cover.setup(program.runtime.game)
		await _cover.close_eyes()
		if _cancelled or not program._alive: return
		_place_body(_flight_to + Vector3.UP * 0.3)
		await _cover.open_eyes()
		if _cancelled or not program._alive: return
		_cover.finish()
		_cover = null
		_land()
	else:
		_add_vignette()
		_flight_t = 0.0
		set_physics_process(true)
		while _flight_t >= 0.0:
			if not await program._wait(0.1): cancel(); return
	program._react("smile", 6.0)
	program._line("cannon_land")
	await program._wait(3.0)

func _physics_process(delta: float) -> void:
	if _flight_t < 0.0: set_physics_process(false); return
	_flight_t += delta / FLIGHT_SECONDS
	var u := minf(_flight_t, 1.0)
	var p := _flight_from.lerp(_flight_to, u) + Vector3.UP * (4.0 * (APEX + maxf(_flight_from.y - _flight_to.y, 0.0) * 0.5) * u * (1.0 - u))
	_place_body(p)
	if is_instance_valid(_vignette): (_vignette.material_override as ShaderMaterial).set_shader_parameter("amount", 0.55 * sin(PI * u))
	if u >= 1.0:
		_flight_t = -1.0
		_land()

## The top of what is really there (the hay pile, else the ground's collision), a little above
## it: the terrain height alone can sit under the collider and drop him through the world.
func _landing(at: Vector3) -> Vector3:
	var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 6.0, at - Vector3.UP * 6.0)
	ray.exclude = [_body.get_rid()]
	var hit := _body.get_world_3d().direct_space_state.intersect_ray(ray)
	return (hit.position as Vector3) + Vector3.UP * 0.15 if not hit.is_empty() else at + Vector3.UP * 1.0

func _place_body(at: Vector3) -> void:
	if not is_instance_valid(_body): return
	_body.global_position = at
	_body.velocity = Vector3.ZERO

func _land() -> void:
	if not _owns_body: return
	_release_body(false)
	if not is_instance_valid(_body): return
	# A flop into the hay: the ordinary knockdown recline, then he gets up when he likes.
	var knock: Variant = _body.get("knockdown")
	if knock is RefCounted:
		var facing: Vector3 = program.runtime.facing()
		(knock as RefCounted).call("start", _body, facing * 1.5 + Vector3.UP * 0.5)

func _add_vignette() -> void:
	var camera := (program.runtime._camera() as Node3D)
	if camera == null: return
	_vignette = MeshInstance3D.new()
	var quad := QuadMesh.new(); quad.size = Vector2(0.9, 0.7)
	_vignette.mesh = quad
	var mat := ShaderMaterial.new(); mat.shader = VIGNETTE; mat.render_priority = 127
	mat.set_shader_parameter("amount", 0.0)
	_vignette.material_override = mat
	_vignette.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vignette.position = Vector3(0, 0, -0.12)
	camera.add_child(_vignette)

func _wheel_away(off: Vector3) -> void:
	if _cancelled or not program._alive or not is_instance_valid(_cannon): return
	var roll := _cannon.create_tween()
	roll.tween_property(_cannon, "global_position", off, 2.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	if not await program._wait(2.5): return
	# Rolled back out of sight behind the stage before it goes.
	if is_instance_valid(_cannon): _cannon.queue_free()
	# The hay stays under him until the stage set goes after the show.

func _exit_tree() -> void:
	cancel()

func cancel() -> void:
	_cancelled = true
	asking = false
	_release_body(true)
	if is_instance_valid(_cover): _cover.finish()
	_cover = null

func _release_body(restore_position: bool) -> void:
	_flight_t = -1.0
	set_physics_process(false)
	if is_instance_valid(_vignette): _vignette.queue_free()
	_vignette = null
	if not _owns_body: return
	_owns_body = false
	if not is_instance_valid(_body): return
	if restore_position:
		_body.global_transform = _body_before
		_body.velocity = _velocity_before
	_body.set_physics_process(_body_was_processing)
	_body.set("controls_locked", _body_was_locked)
