extends RefCounted
## Cartoon throws own motion until wings catch or the native recovery finishes.
## No damage or ragdoll bones. The director owns the optional spoken reaction.
const POSE = preload("res://world/characters/locomotion/pony_flight_pose.gd")
const FLIGHT = preload("res://world/characters/locomotion/pony_flight.gd")
const FK = preload("res://world/characters/locomotion/limb_solver.gd")
const SQUEES = [preload("res://world/audio/pony/squee_1.ogg"),preload("res://world/audio/pony/squee_2.ogg")]
## Seconds flat on the ground before a pinned landing looks for room to get up.
const STUCK_SECONDS := 2.5
var pony: CharacterBody3D
var state := "idle"
var elapsed := 0.0
var impact_count := 0
var caught := false
var _sounded := false
var _start := Transform3D.IDENTITY
var _initial: Array[Transform3D] = []
var _initial_pivot := Transform3D.IDENTITY
var _pose: RefCounted
var _sound: AudioStreamPlayer3D
## The hop's analytic arc, followed exactly so the swept test and the real path agree.
var _hop_from := Vector3.ZERO
var _hop_velocity := Vector3.ZERO
var _hop_seconds := 0.0

func bind(actor: CharacterBody3D) -> void: pony = actor
func active() -> bool: return state != "idle"

func launch(momentum: Vector3) -> bool:
	if not momentum.is_finite() or momentum.length() < 2.0 or not pony._held: return false
	if pony.posture == null:
		pony.posture = preload("res://world/characters/locomotion/pony_posture.gd").new()
		pony.posture.bind(pony)
	if not pony.posture.ready: return false
	_start = pony.global_transform
	_initial = pony.corrected_pose.duplicate(); _initial_pivot = pony.pivot.transform
	pony.end_interaction()
	pony.carry.reset()
	if pony.flight != null: pony.flight.cancel()
	pony.posture.reset()
	pony.set_sim_tier(pony.SimTier.HERO,0)
	pony.stop()
	pony._interaction = "THROWN"
	pony.floor_snap_length = 0.0
	pony.velocity = momentum.limit_length(16.0)
	pony._heightmap_supported = false
	if _pose == null: _pose = POSE.new(); _pose.bind(pony,false)
	_pose.choose("glide")
	state = "airborne"; elapsed = 0.0; _sounded = false; caught = false; impact_count = 0
	if pony.has_signal("physical_reaction"): pony.emit_signal("physical_reaction", "thrown")
	return true

func cancel() -> void:
	if not active(): return
	state = "idle"
	pony.floor_snap_length = .3 * pony.body_scale
	if pony._interaction == "THROWN": pony._interaction = ""
	if pony.get("expressions") != null: pony.expressions.release_touch("throw")
	if is_instance_valid(_sound): _sound.stop()

## A deliberate hop down from a roof, bed or table she was stranded on (placement_recovery.gd):
## the throw's airborne glide pose and swept body on a ballistic arc aimed at `target`, then she
## lands on her hooves and simply stands, with no splat. False when no arc is clear.
## Apex heights above the higher end: a low hop off a bed first, higher ones to clear a roof edge.
const HOP_LIFTS := [.45, 1.0, 1.6]
func hop(target: Vector3) -> bool:
	var lift := hop_lift(target)
	if not is_finite(lift): return false
	if pony.posture == null:
		pony.posture = preload("res://world/characters/locomotion/pony_posture.gd").new()
		pony.posture.bind(pony)
	_start = pony.global_transform
	_initial = pony.corrected_pose.duplicate(); _initial_pivot = pony.pivot.transform
	if pony.flight != null: pony.flight.cancel()
	pony.posture.reset()
	pony.set_sim_tier(pony.SimTier.HERO,0)
	pony.stop()
	pony.floor_snap_length = 0.0
	_hop_from = pony.global_position + Vector3.UP * HOP_START
	_hop_velocity = hop_velocity(_hop_from,target,lift)
	_hop_seconds = hop_seconds(_hop_from,target,lift)
	pony.velocity = _hop_velocity
	pony._heightmap_supported = false
	if _pose == null: _pose = POSE.new(); _pose.bind(pony,false)
	_pose.choose("glide")
	state = "hopping"; elapsed = 0.0; _sounded = true; caught = false
	return true

## Launch velocity of a hop from `from` that lands on `to`, peaking `lift` above the higher end.
static func hop_velocity(from: Vector3, to: Vector3, lift: float) -> Vector3:
	var rise: float = sqrt(2.0 * 9.8 * (maxf(from.y,to.y) + lift - from.y))
	return Vector3(to.x - from.x,0.0,to.z - from.z) / hop_seconds(from,to,lift) + Vector3.UP * rise

static func hop_seconds(from: Vector3, to: Vector3, lift: float) -> float:
	var apex: float = maxf(from.y,to.y) + lift
	return sqrt(2.0 * (apex - from.y) / 9.8) + sqrt(2.0 * (apex - to.y) / 9.8)

## The lowest HOP_LIFTS apex whose whole arc, swept with her real collision body (plus a few
## centimetres of margin) from just above where she stands to the landing spot, touches nothing;
## NAN when none is clear.
const HOP_START := .06
func hop_lift(target: Vector3) -> float:
	if not target.is_finite(): return NAN
	var start: Vector3 = pony.global_position + Vector3.UP * HOP_START
	var basis: Basis = pony.global_basis
	for lift_m: float in HOP_LIFTS:
		var lift: float = lift_m * pony.body_scale
		var velocity := hop_velocity(start,target,lift)
		var seconds := hop_seconds(start,target,lift)
		var previous := start
		var clear := true
		for i in range(1,11):
			var t: float = seconds * i / 10.0
			var point: Vector3 = start + velocity * t + Vector3.DOWN * 4.9 * t * t
			if i == 10: point = target + Vector3.UP * .05
			if pony.test_move(Transform3D(basis,previous),point - previous,null,.04): clear = false; break
			previous = point
		if clear: return lift
	return NAN

func update(delta: float) -> void:
	elapsed += delta
	if state == "hopping":
		var t: float = minf(elapsed,_hop_seconds)
		pony.velocity = _hop_velocity + Vector3.DOWN * 9.8 * t
		var goal: Vector3 = _hop_from + _hop_velocity * t + Vector3.DOWN * 4.9 * t * t
		# Past the arc's end she sinks the last centimetres onto the floor.
		if elapsed > _hop_seconds: goal = pony.global_position + Vector3.DOWN * 2.0 * delta
		var hit := pony.move_and_collide(goal - pony.global_position)
		pony.actual_speed = Vector2(pony.velocity.x,pony.velocity.z).length()
		if hit != null and hit.get_normal().y > .5:
			# On her hooves: an ordinary standing restart, gait and routine resume.
			cancel(); pony.reset_motion(pony.global_transform); return
		_draw_airborne(delta)
		# Something moved into the arc and she never found a floor: back where she was.
		if elapsed > 4.0: cancel(); pony.reset_motion(_start)
		return
	if state == "recovering":
		pony.velocity = Vector3.DOWN * .25
		pony.move_and_slide()
		pony.posture.update(delta)
		_draw_faceplant()
		if elapsed > .7:
			pony.posture.request("stand")
			# Eyes open again once the splat is over, not only after she is fully up.
			if pony.get("expressions") != null: pony.expressions.release_touch("throw")
		# Landed with no room to rise (a wall, furniture, another body): she would stay
		# pinned flat forever. Slide to the nearest clear spot, else stand up in place.
		if elapsed > STUCK_SECONDS and pony.posture.phase == "hold" and not _shuffle_clear() and elapsed > STUCK_SECONDS + 1.5:
			pony.posture.reset()
		if not pony.posture.active():
			cancel()
			pony.reset_motion(pony.global_transform)
		return
	if elapsed > .18 and not _sounded and pony.identity != null and pony.identity.has_wings() and pony.identity.can_fly:
		if pony.flight == null: pony.flight = FLIGHT.new(); pony.flight.bind(pony)
		if pony.flight.catch_throw():
			caught = true
			# Keep flight's disabled floor snap and opened wings.
			state = "idle"; pony._interaction = ""
			if pony.get("expressions") != null: pony.expressions.release_touch("throw")
			return
	pony.velocity.y -= 9.8 * delta
	var collision := pony.move_and_collide(pony.velocity * delta)
	pony.actual_speed = Vector2(pony.velocity.x,pony.velocity.z).length()
	if collision != null:
		_squee()
		var normal := collision.get_normal()
		# A soft cartoon rebound leaves room to unfold the native get-up pose
		# after a wall hit instead of stranding her nose against the wall.
		pony.velocity = pony.velocity.bounce(normal) * .25
		if normal.y > .5:
			pony.velocity = Vector3.ZERO; pony.actual_speed = 0.0
			pony._interaction = ""
			pony.posture.impact_flop()
			state = "recovering"; elapsed = 0.0
			return
	_draw_airborne(delta)
	# Streaming can remove every collider under a thrown actor. A bounded return
	# to the release point lets normal support recovery take over instead of
	# losing a persistent resident below the world forever.
	if elapsed > 12.0:
		cancel(); pony.reset_motion(_start)

## Nearest spot within about a metre, reachable without passing through a wall, where the
## get-up sweep has room. Moves her there and returns true, or leaves her and returns false.
func _shuffle_clear() -> bool:
	var origin := pony.global_position
	var space := pony.get_world_3d().direct_space_state
	var scale: float = pony.body_scale
	var chest: Vector3 = Vector3.UP * .45 * scale
	for radius: float in [.35, .7, 1.05]:
		for i in 8:
			var offset: Vector3 = Vector3.FORWARD.rotated(Vector3.UP, TAU * i / 8.0) * radius * scale
			var ray := PhysicsRayQueryParameters3D.create(origin + chest, origin + offset + chest, 1 | 2, [pony.get_rid()])
			if not space.intersect_ray(ray).is_empty(): continue
			pony.global_position = origin + offset
			if pony.posture.clearance("stand"): return true
	pony.global_position = origin
	return false

func _draw_airborne(delta: float) -> void:
	var horizontal := Vector2(pony.velocity.x,pony.velocity.z).length()
	if horizontal > .1: pony.rotation.y = atan2(-pony.velocity.x,-pony.velocity.z)
	_pose.advance(delta)
	var amount := smoothstep(0.0,.18,elapsed)
	for i in pony.corrected_pose.size():
		pony.corrected_pose[i] = _initial[i].interpolate_with(pony.corrected_pose[i],amount)
	pony.modifier.prepared = pony.corrected_pose
	var pitch := clampf(atan2(pony.velocity.y,maxf(horizontal,.1)),-.65,.45)
	var basis := Basis(Vector3.RIGHT,pitch)
	var centre := Vector3(0,.6,0)
	pony.pivot.transform = _initial_pivot.interpolate_with(Transform3D(basis,centre-basis*centre),amount)
	pony._apply_body_scale()

func _squee() -> void:
	if _sounded: return
	_sounded = true; impact_count += 1
	if _sound == null:
		_sound = AudioStreamPlayer3D.new(); _sound.name = "ThrowSquee"
		_sound.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
		_sound.max_distance = 24.0; _sound.unit_size = 2.0; _sound.volume_db = -14.0
		pony.add_child(_sound)
	_sound.position = Vector3(0,.45,-.4) * pony.body_scale
	_sound.stream = SQUEES[randi() % SQUEES.size()]
	_sound.pitch_scale = randf_range(1.05,1.18); _sound.play()
	if pony.get("expressions") != null: pony.expressions.touch("throw",.85,.95)

func _draw_faceplant() -> void:
	if elapsed > .6 or pony.posture._native_pose.is_empty(): return
	# Brief muzzle-down splat over the native prone legs, then lift the head
	# before getting up. Use the existing neck limits and preserve bone lengths.
	var pose: Array[Transform3D] = pony.posture._native_pose.duplicate()
	var amount := smoothstep(0.0,.12,elapsed) * (1.0 - smoothstep(.3,.6,elapsed))
	for name in ["pony_neck1","pony_neck2","pony_head"]:
		var bone: int = pony.joint_limits.names[name]
		var bend: Basis = pony.joint_limits.pose_basis(name,Vector3(deg_to_rad(-26.0),0,0))
		pose[bone].basis = pose[bone].basis.orthonormalized().slerp(bend.orthonormalized(),amount).scaled_local(pose[bone].basis.get_scale())
	pony.corrected_pose = pose; pony.modifier.prepared = pose
	# Tip the whole prone silhouette nose-first too. Lift only enough to keep
	# the native hoof soles above the supporting plane; no bone scaling.
	var tilt: Basis = pony.posture._slope * Basis(Vector3.RIGHT,-.3 * amount)
	var pivot := Transform3D(tilt.scaled_local(Vector3.ONE * pony.body_scale),Vector3.ZERO)
	var globals := FK.forward_kinematics(pony.profile.parents,pose,pivot * pony._model_frame)
	var bottom := 0.0
	for leg: Dictionary in pony.profile.legs:
		bottom = minf(bottom,(globals[leg.leaf] * Vector3(leg.sole)).dot(pony.posture._slope.y))
	pivot.origin = pony.posture._slope.y * -bottom
	pony.pivot.transform = pivot
