extends Node3D
## Petting and booping Spike, by hand in VR or by clicking on desktop. One node answers as both a
## pony's touch body (pony_touch_body.gd: desktop_offer, desktop_pet, petting, pet_region, pets) and
## her boop node (hybrid_boop.gd: arm, boop, nose_world, snoot, boops, kisses), so the player's
## desktop interactions, kisser, head guard and spectator view treat him like any pony.
## Regions: "head" (scratches between the spines), "chin", "belly" (he loves a belly rub), "back".
## A hand resting and moving on a region for PET_DELAY seconds is a petting session; a quick tap
## on the snout is a boop.

const PET_DELAY := 0.35
const PET_HOLD := 0.6
const BOOP_SPEED := 0.25
const BOOP_REST := 0.8
## Region spheres in Spike's own frame (metres at body scale 1; -Z ahead, Y up).
const REGIONS := {
	"head": [Vector3(0, 0.66, 0.02), 0.15],
	"chin": [Vector3(0, 0.43, -0.13), 0.07],
	"belly": [Vector3(0, 0.24, -0.08), 0.09],
	"back": [Vector3(0, 0.3, 0.09), 0.09],
}
const NOSE := Vector3(0, 0.46, -0.27)
## The head sphere for desktop picking: the face and skull together.
const SKULL_LOCAL := Vector3(0, 0.56, -0.05)
const SKULL_RADIUS := 0.2

var spike: CharacterBody3D
## Booping/petting hands (game_mare_wiring.gd arm_boop) and the inventory's hand sampler.
var hands: Array[Node3D] = []
var hand_sampler: Callable
## His head as a physics body, a child of Spike himself like a pony's snoot (hybrid_boop.gd): the
## player's head guard keeps the camera out of it and hands meet it on the face layer.
var snoot: AnimatableBody3D
const FACE_LAYER := 4
var _skull_offset := Transform3D.IDENTITY
var head_skeleton: Skeleton3D
var _head_bone := -1
var pets := 0
var boops := 0
var kisses := 0
var petting := false
var pet_region := ""
var strong_blush_time := 0.0
var _hand_last: Dictionary = {}
var _contact_time := 0.0
var _last_contact := -10.0
var _boop_rest := 0.0
var _desktop_left := 0.0
var _desktop_region := ""

func bind(body: CharacterBody3D, skeleton: Skeleton3D) -> void:
	spike = body
	head_skeleton = skeleton
	_head_bone = skeleton.find_bone("Head") if skeleton != null else -1
	snoot = AnimatableBody3D.new(); snoot.name = "Snoot"
	snoot.sync_to_physics = true
	snoot.collision_layer = FACE_LAYER | preload("res://player/head_contact_query.gd").LAYER
	snoot.collision_mask = 0
	for spec in [["SkullShape", SKULL_LOCAL, SKULL_RADIUS], ["NoseShape", NOSE, 0.05]]:
		var shape := SphereShape3D.new(); shape.radius = spec[2]
		var cs := CollisionShape3D.new(); cs.name = spec[0]; cs.shape = shape; cs.position = spec[1]
		snoot.add_child(cs)
	spike.add_child.call_deferred(snoot)

func arm(left_hand: Node3D, right_hand: Node3D, _left_controller: Node, _right_controller: Node) -> void:
	hands.clear()
	for hand in [left_hand, right_hand]:
		if hand != null: hands.append(hand)

func _scale() -> float:
	return float(spike.body_scale) if spike != null else 1.0

func _world(local: Vector3) -> Vector3:
	return spike.global_transform * (local * _scale())

func nose_world() -> Vector3:
	return _world(NOSE)

## The snoot is a child of his root, so it moves with him; its shapes follow his size. Physics
## bodies keep the scale they entered with (Jolt), so the shapes are resized, not the body.
var _shape_scale := 1.0
func _place_snoot() -> void:
	if snoot == null or is_equal_approx(_shape_scale, _scale()): return
	_shape_scale = _scale()
	for cs: CollisionShape3D in snoot.get_children():
		var base: Vector3 = SKULL_LOCAL if cs.name == "SkullShape" else NOSE
		cs.position = base * _shape_scale
		(cs.shape as SphereShape3D).radius = (SKULL_RADIUS if cs.name == "SkullShape" else 0.05) * _shape_scale

func skull_world() -> Vector3:
	return _world(SKULL_LOCAL)

func _sync_snoot() -> void:
	_place_snoot()

func wake_tick() -> void:
	if spike != null and spike.sleeping and spike.has_method("wake_up"): spike.wake_up()

func boop() -> void:
	wake_tick()
	boops += 1
	_boop_rest = BOOP_REST
	if spike.has_method("on_booped"): spike.on_booped()

func play_kiss(_db := -24.0, _soft := false) -> void:
	kisses += 1
	if spike.expressions != null: spike.expressions.kiss()

func play_breath() -> void: pass

func sustain_blush(seconds := 1.0) -> void:
	strong_blush_time = maxf(strong_blush_time, seconds)
	if spike.expressions != null: spike.expressions.fluster(seconds)

## Desktop pick along the camera ray: the nearest region sphere it crosses.
func desktop_offer(origin: Vector3, end: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var nearest := INF
	var spheres: Dictionary = REGIONS.duplicate()
	spheres["face"] = [SKULL_LOCAL, SKULL_RADIUS]
	for region: String in spheres:
		var centre := _world(spheres[region][0])
		var radius: float = float(spheres[region][1]) * _scale()
		var hit := Geometry3D.segment_intersects_sphere(origin, end, centre, radius)
		if hit.is_empty(): continue
		var point: Vector3 = hit[0]
		var distance := origin.distance_to(point)
		if distance < nearest:
			nearest = distance
			best = {"target": spike, "point": point, "normal": Vector3(hit[1]), "region": "head" if region == "face" else region}
	return best

func desktop_pet(region: String) -> void:
	_desktop_left = PET_HOLD
	_desktop_region = region

func desktop_pet_end() -> void:
	_desktop_left = 0.0
	_desktop_region = ""

func _physics_process(delta: float) -> void:
	if spike == null: return
	_sync_snoot()
	_boop_rest = maxf(0.0, _boop_rest - delta)
	strong_blush_time = maxf(0.0, strong_blush_time - delta)
	var region := ""
	var now := Time.get_ticks_msec() / 1000.0
	if not spike.is_held():
		for hand in hands:
			if not is_instance_valid(hand): continue
			var at := hand.global_position
			var last: Vector3 = _hand_last.get(hand, at)
			var speed := at.distance_to(last) / maxf(delta, 1e-4)
			_hand_last[hand] = at
			if _boop_rest <= 0.0 and speed > BOOP_SPEED and at.distance_to(nose_world()) < 0.06 * _scale():
				boop()
				continue
			for name: String in REGIONS:
				if at.distance_to(_world(REGIONS[name][0])) < float(REGIONS[name][1]) * _scale() + 0.03:
					region = name
					break
	if region == "" and _desktop_left > 0.0:
		_desktop_left -= delta
		region = _desktop_region
	if region != "":
		_last_contact = now
		_contact_time += delta
		if not petting and _contact_time >= PET_DELAY:
			petting = true
			pets += 1
			wake_tick()
			spike.physical_reaction.emit("pet")
		pet_region = region
	elif now - _last_contact > PET_HOLD:
		_contact_time = 0.0
		if petting:
			petting = false
			pet_region = ""
	if spike.expressions != null:
		if petting:
			var smile := 0.9 if pet_region in ["belly", "chin"] else 0.75
			spike.expressions.touch("pet", smile, 0.55 if pet_region == "belly" else 0.35)
		else:
			spike.expressions.release_touch("pet")
