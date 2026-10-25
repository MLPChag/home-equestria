extends CharacterBody3D
## No attack, damage, hitbox, or combat dependency. Only safe local movement and clips.
var destination := Vector3.ZERO
var requested_speed := 0.0
var observer := Vector3.INF
var retreating := false
var animation: AnimationPlayer
var _clip := ""
var age := 0.0
var retreat_until := 0.0
var reconsider_at := 0.0
var state := "lurking"
var desired_distance := 40.0
var side := 1.0
var travel := 0.0
const SPEEDS := {"walk": 0.4275298, "trot": 1.087912, "run": 2.315790, "stalk": 0.1253557}

func setup(scene: PackedScene) -> void:
	collision_layer = 0; collision_mask = 1
	floor_max_angle = deg_to_rad(32.0); floor_snap_length = 0.35
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new(); capsule.radius = 0.38; capsule.height = 1.35
	shape.shape = capsule; shape.position.y = 0.71; add_child(shape)
	var model := scene.instantiate() as Node3D
	add_child(model)
	animation = model.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	animation.play("idle")

func _physics_process(delta: float) -> void:
	age += delta
	var toward := destination - global_position; toward.y = 0.0
	var desired := toward.normalized() * minf(requested_speed, toward.length() / maxf(delta, 0.001)) if toward.length() > 0.12 else Vector3.ZERO
	if observer.is_finite():
		var away := global_position - observer; away.y = 0.0
		# Never move closer inside the personal-space boundary, even between AI ticks.
		if away.length() < 24.0 or retreating:
			if desired.dot(away) < 0.0: desired = Vector3.ZERO
	velocity.x = desired.x; velocity.z = desired.z
	velocity.y = -0.5 if is_on_floor() else maxf(velocity.y - 15.0 * delta, -6.0)
	var before := global_position
	move_and_slide()
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	travel += moved
	var speed := moved / maxf(delta, 0.001)
	if speed > 0.025:
		rotation.y = lerp_angle(rotation.y, atan2(-desired.x, -desired.z), minf(1.0, delta * 7.0))
	var clip := "idle"
	if speed > 1.65: clip = "run"
	elif speed > 0.65: clip = "trot"
	elif speed > 0.22: clip = "walk"
	elif speed > 0.025: clip = "stalk"
	if clip != _clip:
		animation.play(clip, 0.2); _clip = clip
	animation.speed_scale = clampf(speed / float(SPEEDS[clip]), 0.65, 1.25) if SPEEDS.has(clip) else 1.0
