extends Node
## AnonPony (docs/ANONPONY_DESIGN_2026_10_01.md, sections 4 and 12.2): the player as a pony on
## the desktop and in seated VR. This node sits under the rig (game.player, the desktop or seated
## rig) and drives a real pony body, "PlayerPony", a sibling of the rig under game:
## - the pony walks, trots and gallops with the same locomotion as every other pony; the rig
##   calls drive() once per physics tick with the keyboard input and is copied onto the pony;
## - anything else that moves the rig (saves, story, seats, sleep, title, balloon, head guard)
##   keeps doing so: a jump of more than 5 cm resets the pony there, a smaller nudge moves it;
## - the view sits at the pony's eyes (head skeleton), smoothed, with rotation from the mouse or
##   the headset only; the head and mane are hidden from the player camera, and shadow-only twins
##   keep their shadow, because Godot culls shadow casters by the camera's visible layers.
## Room-scale VR always plays human: attach() returns null there. In seated VR the controllers
## are magic wisps that grip and lift things (player/magic_hands/magic_hands.gd).

const GROUP := "player_pony_form"
## Render layer 18: the player's own head, mane and horn glow. The player camera leaves it out;
## spectators and other cameras still see it.
const FIRST_PERSON_HIDDEN_LAYER := 1 << 17
## Loaded on attach, never preloaded: callers preload this file, and a human player never needs
## the pony scripts.
const PLAYER_PONY_PATH := "res://world/characters/player_pony/player_pony.gd"
const IDENTITY_PATH := "res://world/characters/player_pony/anon_pony_identity.gd"
const BODY_SCENE_PATH := "res://world/characters/hybrid_mare/body.glb"
## Tight navigator steering (1.8 rad/s); false is the wider arc steering. dev reviews the feel.
const PLAYER_STEERING := true
const HEAD_SHADOW_TWINS := true
## Standing eye height before the first measurement: canon adult, times the pony size setting;
## young ponies are 0.62 of that.
const EYE_HEIGHT := 0.82
const YOUNG_EYE_SCALE := 0.62
## Rig displacement between two drive() calls: above this a teleport, above NUDGE a nudge.
const TELEPORT_DISTANCE := 0.05
const NUDGE_DISTANCE := 0.001
const MOVE_DEADZONE := 0.15
## The key trot: 40 % up the trot band (about 2.56 m/s at canon size), clear of the poor-contact
## walk band 0.36-0.6 m/s.
const TROT_FRACTION := 0.4
## Sharp turns ease to a walk, as pony_navigator.gd does for NPCs.
const TURN_EASE_FROM_DEGREES := 35.0
const TURN_EASE_TO_DEGREES := 90.0
## Standing still with the view this far from the body, the pony steps round until it is
## within FACE_DONE.
const FACE_START_DEGREES := 50.0
const FACE_DONE_DEGREES := 10.0
const FACE_STILL_SPEED := 0.05
## Looking back over the body before a stepping turn catches up, the view sat right above the
## croup and tail. Past BACK_HIDE_DEGREES the body leaves the player camera; below
## BACK_SHOW_DEGREES it returns.
const BACK_HIDE_DEGREES := 100.0
const BACK_SHOW_DEGREES := 80.0
const SEAT_LIFT := 0.02
const POSTURE_TRIES := 90
## A buck (player_knockdown.gd): a short stagger, down on the ground, up again after a moment.
## Pegasus flight: F takes off/lands; Space flaps, release glides, S brakes,
## Shift powers stronger strokes, Ctrl folds the wings for a dive.
## Space on her hooves: a hop of about 0.46 m (pony_locomotion._recover_support re-seats a body
## more than 0.6 m above the ground, so the apex stays under that at every size).
const JUMP_SPEED := 3.0
## Where the head can turn while the body is held still (dev 2026-10-01: "lock my view so i cant
## move my head in impossible directions if my body is locked to an axis"): yaw either side of
## the body's heading and pitch, radians. Lying is the narrowest.
const LIE_YAW := 1.22         # 70 degrees
const SIT_YAW := 1.92         # 110 degrees
const LIE_PITCH := Vector2(-0.5, 0.9)
const SIT_PITCH := Vector2(-1.1, 1.1)
const KNOCK_MAX_SPEED := 3.0
const KNOCK_LUNGE_SECONDS := 0.3
const KNOCK_STAND_AFTER := 2.0
const KNOCK_LOCK_SECONDS := 2.5
## Eye smoothing time constants (seconds). The headset removes the gait bob and limits how fast
## the eye may rise or sink. dev reviews comfort.
const DESKTOP_TAU_H := 0.06
const DESKTOP_TAU_V := 0.12
const REDUCED_TAU_V := 0.35
const HEADSET_TAU := 0.5
const HEADSET_MAX_VERTICAL_SPEED := 0.3
## The measured eye height follows the head only while she stands settled and looks roughly level.
const EYE_HEIGHT_BLEND := 0.05
## Standing and walking, the view rides the body, not the animated head (dev 2026-10-01: the
## pony "shouldnt throw my camera around"): the root's position (height eased over stairs and
## bumps), the standing eye height, and the eye's standing lead along the view's heading. Head
## bob, neck swing and body turns no longer move it. Sitting, lying, seats and knockdowns use
## the head again; STEADY_BLEND_RATE crossfades between the two.
const EYE_FORWARD := 0.2
const STEADY_TAU_V := 0.1
const STEADY_BLEND_RATE := 4.0
const EYE_LEVEL_PITCH := 0.35
const LOOK_DISTANCE := 3.0
## Mouth relative to the eye when the head has no InnerMouth mesh (times body_scale).
const MOUTH_FALLBACK := Vector3(0.0, -0.09, -0.17)
const HOLD_AHEAD := 0.05
const CAPSULE_RADIUS := 0.25
const CAPSULE_HEADROOM := 0.1

signal avatar_ready(avatar: CharacterBody3D)

## A copy of the applied form (world/life/player_form.gd).
var form: Dictionary = {}
## game.player: the desktop or seated rig.
var rig: CharacterBody3D
## The pony body, node "PlayerPony" under game (world/characters/player_pony/player_pony.gd).
var avatar: CharacterBody3D

var _game: Node
var _head_skeleton: Skeleton3D
var _head_bone := -1
var _eye_center := Vector3.ZERO
var _mouth_head := Vector3.ZERO
var _has_mouth := false
var _look_target: Node3D
## [original, twin] MeshInstance3D pairs.
var _twins: Array = []
## [MareBody, its first-person copy] (player/pony_neck_cap.gd first_person_body), or empty.
var _first_person_body: Array = []
var _eye_height := EYE_HEIGHT
## Eye in the pony's root frame: the last two physics samples and the smoothed value.
var _prev_local := Vector3.ZERO
var _cur_local := Vector3.ZERO
var _smoothed := Vector3.ZERO
var _sampled := false
var _last_eye := Vector3.ZERO
var _reduced_motion := false
## Where drive() last left the rig.
var _synced := Vector3.ZERO
## Parked and hidden while the rig's physics is held (loading cover, title); the first drive()
## clears it.
var _hold_parked := false
## Parked and hidden on request (the wake poses); only set_avatar_shown(true) clears it.
var _hide_requested := false
## Parked and hidden while the rig flies (debug F).
var _fly_parked := false
var _turning := false
var _seated := false
var _seat: Node3D
var _seat_uppers: Array = []
var _posture_pending := ""
var _posture_tries := 0
var _on_balloon := false
var _balloon: Node3D
var _floor_layers_before := 0
var _knock_stand_left := 0.0
var _knock_lock_left := 0.0
var _knock_prev_locked := false
var _magic_hidden := false
var _back_hidden: Array = []
var _landing := false
var _eye_forward := EYE_FORWARD
var _root_y := NAN
var _steady := 1.0   # [mesh, layers before] while the view looks back over the body
## The desktop eye leads the torso capsule. Give that eye its own small physical
## clearance so walking into a leaf stops before the near plane passes through it.
var _eye_collision: CollisionShape3D
var _rig_eye_collision: CollisionShape3D
var _eye_frustum := Vector3.ZERO


## The pony form for `game`'s rig, or null for a human form or room-scale VR. Idempotent: the
## form never changes within a session.
static func attach(game: Node, chosen: Dictionary) -> Node:
	if game == null or not is_instance_valid(game): return null
	if game.get("xr_active") == true: return null
	if str(chosen.get("kind", "")) != "pony": return null
	var player := game.get("player") as CharacterBody3D
	if player == null: return null
	var existing := player.get_node_or_null("PonyForm")
	if existing != null: return existing
	# A script cannot preload itself.
	var own_script := load("res://player/pony_form.gd") as GDScript
	if own_script == null: return null
	var driver: Node = own_script.new()
	driver.name = "PonyForm"
	driver.process_physics_priority = 900
	# Before XROrigin3D reads the origin in its internal process, and before the HUD reads the camera.
	driver.process_priority = -10
	driver.add_to_group(GROUP)
	player.add_child(driver)
	var built: Variant = driver.call("_setup", game, player, chosen)
	if built != true:
		driver.remove_from_group(GROUP)
		driver.name = "PonyFormFailed"
		driver.queue_free()
		return null
	var inventory:Node=game.get("inventory")
	if is_instance_valid(inventory) and is_instance_valid(inventory.get("customizer")):
		inventory.customizer.use_pony(driver.avatar)
	return driver


static func find(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group(GROUP) if tree != null else null


static func estimate_eye_height(chosen: Dictionary) -> float:
	var height := EYE_HEIGHT * _pony_scale()
	if str(chosen.get("age", "")) == "young": height *= YOUNG_EYE_SCALE
	return height


static func _settings() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null: return null
	return tree.root.get_node_or_null("Settings")


static func _pony_scale() -> float:
	var settings := _settings()
	if settings == null or not settings.has_method("pony_scale"): return 1.0
	return float(settings.call("pony_scale"))


func _setup(game: Node, player: CharacterBody3D, chosen: Dictionary) -> bool:
	_game = game
	rig = player
	form = chosen.duplicate(true)
	_eye_height = estimate_eye_height(form)
	var pony_script := load(PLAYER_PONY_PATH) as GDScript
	var identity_script := load(IDENTITY_PATH) as GDScript
	var body := load(BODY_SCENE_PATH) as PackedScene
	if pony_script == null or identity_script == null or body == null:
		push_error("PonyForm: the player pony scripts or body did not load")
		return false
	var identity: Resource = identity_script.call("build", form)
	if identity == null:
		push_error("PonyForm: could not build the AnonPony identity")
		return false
	var pony: CharacterBody3D = pony_script.new()
	if pony == null:
		push_error("PonyForm: could not create the player pony")
		return false
	pony.name = "PlayerPony"   # never "AnonBody": several lookups treat that name as the human body
	pony.model_scene = body
	pony.preserve_model_materials = true
	pony.eyes_enabled = false
	pony.head_width = 1.0
	pony.identity = identity
	pony.ai_profile = ""
	pony.near_mesh_enabled = false
	pony.far_mesh_enabled = false
	pony.rig = player
	# Before add_child: Jolt keeps the scale a body entered with.
	pony.transform = Transform3D(Basis(Vector3.UP, player.rotation.y), player.global_position)
	pony.process_physics_priority = 1   # after the rig, which calls drive()
	game.add_child(pony)
	avatar = pony
	pony.sync_view_clearance = _place_eye_clearance
	# No AI: out of the crowd tiers (PonyCrowd.MEMBERS) and the AI character list.
	for group: StringName in [&"sim_ponies", &"ai_characters"]:
		if pony.is_in_group(group): pony.remove_from_group(group)
	# Socks before the size: the pivot scale then carries them.
	pony.add_socks()
	pony.navigation_steering = PLAYER_STEERING
	pony.set_body_scale(_pony_scale())
	_strip_contacts()
	_measure_head()
	_hide_head_from_player()
	_cap_neck()
	if is_unicorn():
		var telekinesis: Node = (load("res://player/unicorn_telekinesis.gd") as GDScript).new()
		telekinesis.name = "UnicornTelekinesis"
		telekinesis.set("form", self)
		telekinesis.set("rig", player)
		add_child(telekinesis)
	# Seated VR: the controllers are small magic wisps that lift what they grip, for every race
	# (player/magic_hands/magic_hands.gd). Desktop has no headset view and gets none.
	if player.get("headset_view") == true:
		var magic_hands := load("res://player/magic_hands/magic_hands.gd") as GDScript
		if magic_hands != null: magic_hands.call("attach", self, player)
	var ambience := game.get_node_or_null("Ambience")
	if ambience != null and ambience.has_method("connect_player_pony"):
		ambience.call("connect_player_pony", pony)
	_look_target = Node3D.new()
	_look_target.name = "PlayerLookTarget"
	_look_target.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_look_target)
	_look_target.global_position = player.global_position + Vector3.UP * _eye_height + _view_basis() * Vector3.FORWARD * LOOK_DISTANCE
	pony.look_target = _look_target
	_synced = player.global_position
	_smoothed = Vector3(0.0, _eye_height, 0.0)
	_last_eye = player.global_position + Vector3.UP * _eye_height
	var settings := _settings()
	if settings != null:
		_reduced_motion = settings.call("get_value", "access/reduced_motion") == true
		if settings.has_signal("changed"): settings.connect("changed", _on_setting_changed)
	if player.has_method("set_form_driver"): player.call("set_form_driver", self)
	_resize_rig_capsule()
	# Attached under the loading cover or the title: held still and hidden until the rig moves.
	if not player.is_physics_processing(): _hold_parked = true
	_refresh_park()
	avatar_ready.emit(pony)
	return true


func _exit_tree() -> void:
	if is_instance_valid(_eye_collision): _eye_collision.queue_free()
	if is_instance_valid(_rig_eye_collision): _rig_eye_collision.queue_free()
	if _knock_lock_left > 0.0 and is_instance_valid(rig) and rig.get("controls_locked") == true:
		rig.controls_locked = _knock_prev_locked
	_knock_lock_left = 0.0


# --------------------------------------------------------------------------- public API

## Called by the rig once per physics tick, after its knockdown, seat and flight handling; the
## input is zero while controls are locked, seated, flying or kiss-held.
func drive(delta: float, move: Vector2, sprint: bool, slow: bool) -> void:
	_update_eye_clearance()
	if not _alive(): return
	if _hide_requested:
		# The wake owns the rig: never write it from the pony.
		_synced = rig.global_position
		return
	if _hold_parked:
		_hold_parked = false
		_reset_at_rig()
		_refresh_park()
	if rig.get("flying") == true:
		if not _fly_parked:
			_fly_parked = true
			_end_balloon_support()
			_refresh_park()
		_synced = rig.global_position
		return
	if _fly_parked:
		# She falls from where the flight ended, under gravity (player_pony._recover_support).
		_fly_parked = false
		_reset_at_rig()
		_refresh_park()
	if rig.wing_flight.resume_pending:
		if is_pegasus():
			# Loading can replace an already-piloted flight and move the rig. Reset
			# its avatar first: reset_motion cancels flight, including shared state.
			var saved: Dictionary = rig.wing_flight.snapshot()
			_reset_at_rig()
			rig.wing_flight.restore(saved)
			avatar._ensure_flight()
			avatar.flight.pilot(rig.wing_flight, true)
			_landing = rig.wing_flight.landing
		else: rig.wing_flight.resume_pending = false
	elif _piloting() and not rig.wing_flight.active:
		avatar.flight.cancel()
	if _piloting():
		_pilot(move, sprint, slow)
		_follow_rig()
		return
	_landing = false
	_update_knockdown(delta)
	_sync_seat()
	_try_posture()
	if _seated:
		# The rig holds itself on the seat; the pony sits there and is not copied back.
		avatar.stop()
		_turning = false
		_synced = rig.global_position
		return
	_follow_rig()
	_steer(move, sprint, slow, delta)
	# Swimming (pony_water_escape.gd owns her body then): she paddles where the player pushes,
	# and pushing into a steep bank climbs out. Also read on the dry strip below the water
	# level beside a river, so pushing there without progress still climbs out or rescues.
	var escape: Variant = avatar.get("water_escape")
	if escape is RefCounted and move.length() > MOVE_DEADZONE and not _knocked():
		escape.set("steer", Basis(Vector3.UP, rig.rotation.y) * Vector3(move.x, 0.0, move.y))


func eye_height() -> float:
	return _eye_height


## Where food and kisses meet the muzzle: the InnerMouth centre carried by the head bone, placed
## relative to the view's eye so a held item does not bob against the smoothed view.
func mouth_world() -> Vector3:
	if not is_instance_valid(avatar): return _last_eye
	if _has_mouth and is_instance_valid(_head_skeleton):
		var head := _head_skeleton.global_transform * _head_skeleton.get_bone_global_pose(_head_bone)
		var mouth := head * _mouth_head
		if _sampled and not _hidden():
			return _last_eye + (mouth - head * _eye_center)
		return mouth
	return _last_eye + avatar.global_basis * MOUTH_FALLBACK * float(avatar.get("body_scale"))


## An item carried in the mouth, oriented to the view.
func hold_transform() -> Transform3D:
	var view := _view_basis()
	return Transform3D(view, mouth_world() + view * Vector3.FORWARD * HOLD_AHEAD)


## The unicorn's horn magic (UnicornMagic), or null. The first call builds it and hides the horn
## aura from the player camera; the horn's light remains as the cue.
func magic() -> Node:
	if not is_instance_valid(avatar): return null
	var value: Variant = avatar.get("magic")
	if not is_instance_valid(value): return null
	var node := value as Node
	if node == null: return null
	if not _magic_hidden:
		_magic_hidden = true
		if node.has_method("_build"): node.call("_build")
		if node.has_method("set_visual_layer"): node.call("set_visual_layer", FIRST_PERSON_HIDDEN_LAYER)
	return node


func is_pegasus() -> bool:
	if is_instance_valid(avatar):
		var identity: Variant = avatar.get("identity")
		if identity != null and (identity as Object).has_method("has_wings"):
			return identity.has_wings() == true
	return str(form.get("race", "")) == "pegasus"


## F as a pegasus: take off, or land when flying (glide straight down until a hoof touches).
## False when it is not hers to use (not a pegasus, seated, waking, knocked down).
func toggle_flight() -> bool:
	if not _alive() or not is_pegasus(): return false
	if _piloting():
		_landing = true
		return true
	if _seated or _hidden() or _knocked(): return false
	if avatar.has_method("_ensure_flight"): avatar.call("_ensure_flight")
	var flight: Variant = avatar.get("flight")
	if flight == null: return false
	_landing = false
	_turning = false
	if flight.pilot(rig.wing_flight) == true:
		print("[pony form] flying")
		return true
	print("[pony form] cannot fly: ", flight.get("reason"))
	return false


## Space on her hooves (dev 2026-10-01: "ponies should jump on space"). Flying, Space climbs.
func jump() -> bool:
	if not _alive() or _piloting() or _seated or _hidden() or _knocked(): return false
	var posture: Variant = avatar.get("posture")
	if posture != null and posture.active() == true:
		# Sitting or lying on the ground: Space no longer gets up (dev 2026-10-22: "space should
		# not dismount"); Q does (stand_from_ground), as do Z / X again.
		return false
	return avatar.call("jump", JUMP_SPEED) == true


## Q (dev 2026-10-22): get up from sitting or lying on the ground.
func stand_from_ground() -> bool:
	if not _alive() or ground_posture().is_empty(): return false
	_request("stand")
	return true


## Z sits down on the ground (or stands), X lies down (or stands) (dev 2026-10-01: "add a button
## for sitting and laying as a pony"). On a seat, Ctrl still lies down along it (toggle_rest).
func toggle_ground_posture(kind: String) -> bool:
	if not _alive() or _hidden() or _knocked() or _piloting() or _seated: return false
	var current := str(avatar.posture_status().get("kind", "stand"))
	_request("stand" if current == kind else kind)
	return true


## "sit" or "lie_down" while she sits or lies on the ground (not on a seat), else "".
func ground_posture() -> String:
	if not _alive() or _seated or _hidden(): return ""
	var kind := str(avatar.posture_status().get("kind", "stand"))
	return kind if kind in ["sit", "lie_down"] else ""


## Keeps the view where a held body can look (see LIE_YAW). Called after mouse look and every frame.
func clamp_view() -> void:
	if not _alive() or _hidden() or _piloting(): return
	var kind := str(avatar.posture_status().get("kind", "stand"))
	var lying := kind == "lie_down"
	if not (_seated or lying or kind == "sit"): return
	var forward := -avatar.global_basis.z
	forward.y = 0.0
	if forward.length_squared() < 1e-6: return
	var body_yaw := atan2(-forward.x, -forward.z)
	var limit := LIE_YAW if lying else SIT_YAW
	var offset := angle_difference(body_yaw, rig.rotation.y)
	if absf(offset) > limit: rig.rotation.y = body_yaw + clampf(offset, -limit, limit)
	var pitches := LIE_PITCH if lying else SIT_PITCH
	rig.set("_pitch", clampf(float(rig.get("_pitch")), pitches.x, pitches.y))


func _piloting() -> bool:
	var flight: Variant = avatar.get("flight") if is_instance_valid(avatar) else null
	return flight != null and str(flight.get("state")) == "piloted"


## Input only. The pony's established flight owner integrates and collides once.
func _pilot(move: Vector2, sprint: bool, slow: bool) -> void:
	var flight: Variant = avatar.get("flight")
	if _landing: flight.pilot_model.landing = true
	flight.pilot_view = _view_basis()
	if rig.headset_view and rig.camera.global_basis.is_finite(): flight.pilot_view = rig.camera.global_basis
	flight.pilot_input = move
	flight.pilot_model.bank_input = flight.pilot_model.bank_buttons(rig)
	flight.pilot_flap = not bool(rig.get("controls_locked")) and Input.is_action_pressed("move_jump")
	flight.pilot_boost = sprint
	flight.pilot_retract = slow


func is_unicorn() -> bool:
	if is_instance_valid(avatar):
		var identity: Variant = avatar.get("identity")
		if identity != null and (identity as Object).has_method("has_horn"):
			return identity.has_horn() == true
	return str(form.get("race", "")) == "unicorn"


## false: hide and park the pony until set_avatar_shown(true) (the wake poses); drive() keeps it
## hidden and never writes the rig. true: show it again where the rig now stands.
func set_avatar_shown(shown: bool) -> void:
	if shown:
		if not _hide_requested: return
		_hide_requested = false
		_reset_at_rig()
	else:
		_hide_requested = true
	_refresh_park()


## Ctrl while seated: lie down (on a couch, along it) or sit up again. False when not seated.
func toggle_rest() -> bool:
	if not _alive(): return false
	_sync_seat()
	if not _seated or not is_instance_valid(_seat): return false
	if is_lying():
		if rig.has_meta("couch_sleeping"): rig.remove_meta("couch_sleeping")
		_request("sit")
		return true
	var couch: Variant = _seat.get_meta("couch") if _seat.has_meta("couch") else null
	if is_instance_valid(couch) and (couch as Object).has_method("pony_transform"):
		var rest: Transform3D = couch.pony_transform(_seat)
		avatar.reset_motion(rest)
		avatar.reset_physics_interpolation()
	_request("lie_down")
	rig.set_meta("couch_sleeping", true)
	return true


func is_lying() -> bool:
	if not is_instance_valid(avatar): return false
	var status: Dictionary = avatar.posture_status()
	return str(status.get("kind", "")) == "lie_down"


## A buck: a short stagger with the hit, down on the ground, up again after KNOCK_STAND_AFTER;
## the controls stay locked meanwhile. The camera simply follows the eye.
func knockdown(impulse: Vector3) -> void:
	if not _alive() or _hidden(): return
	# player_knockdown stands the rig up first: leave the seat now so the lunge still happens.
	_sync_seat()
	if not _seated:
		avatar.lunge(Vector3(impulse.x, 0.0, impulse.z).limit_length(KNOCK_MAX_SPEED), KNOCK_LUNGE_SECONDS)
	_request("lie_down")
	_knock_stand_left = KNOCK_STAND_AFTER
	if _knock_lock_left <= 0.0: _knock_prev_locked = rig.get("controls_locked") == true
	_knock_lock_left = KNOCK_LOCK_SECONDS
	rig.controls_locked = true


# --------------------------------------------------------------------------- per frame

func _physics_process(_delta: float) -> void:
	if not _alive(): return
	if not rig.is_physics_processing() and not _hold_parked:
		_hold_parked = true
		_refresh_park()
	_keep_twins()
	if _hidden(): return
	# After the pony moved and the native solve batch (priority 800). The mHead pose is the one
	# HybridNeckLink wrote at the last skeleton update, one tick old: far below the smoothing.
	# Samples are in the pony's root frame, so a reset (teleport) does not invalidate them.
	var sample := _eye_sample()
	if not _sampled:
		_prev_local = sample
		_cur_local = sample
		_sampled = true
	else:
		_prev_local = _cur_local
		_cur_local = sample
	_measure_eye_height()


func _process(delta: float) -> void:
	if not _alive(): return
	if rig.has_method("view_is_held") and rig.call("view_is_held") == true: return
	var eye: Vector3
	if _hidden():
		eye = rig.get_global_transform_interpolated().origin + Vector3.UP * _eye_height
		# Shown again, the pony stands at the rig: the view then glides from here to her eyes.
		_smoothed = Vector3(0.0, _eye_height, 0.0)
	else:
		if _sampled:
			_smooth_toward(_prev_local.lerp(_cur_local, Engine.get_physics_interpolation_fraction()), delta)
		var head_eye: Vector3 = avatar.get_global_transform_interpolated() * _smoothed
		var root: Vector3 = avatar.get_global_transform_interpolated().origin
		_root_y = root.y if is_nan(_root_y) else lerpf(_root_y, root.y, 1.0 - exp(-delta / STEADY_TAU_V))
		var size := float(avatar.get("body_scale"))
		var steady_eye := Vector3(root.x, _root_y + _eye_height, root.z) + Basis(Vector3.UP, rig.rotation.y) * Vector3(0.0, 0.0, -_eye_forward * size)
		_steady = move_toward(_steady, 1.0 if _steady_view() else 0.0, STEADY_BLEND_RATE * delta)
		eye = head_eye.lerp(steady_eye, smoothstep(0.0, 1.0, _steady))
	_last_eye = eye
	clamp_view()
	if rig.has_method("place_view"): rig.call("place_view", eye)
	_hide_body_behind_view()
	if is_instance_valid(_look_target):
		_look_target.global_position = eye + _view_basis() * Vector3.FORWARD * LOOK_DISTANCE


## Reapply camera hiding after a wardrobe mesh is replaced while looking back.
func refresh_body_visibility() -> void:
	for pair:Array in _back_hidden:
		if is_instance_valid(pair[0]):(pair[0] as GeometryInstance3D).layers=int(pair[1])
	_back_hidden.clear()
	_hide_body_behind_view()


## The hidden head exposes the actual skinned body rim. The player camera draws a copy of the
## body whose neck top closes into a rounded end (no cut edge in view); the original, which
## meets the head for shadows and every other camera, moves to the hidden layer. The small
## remaining rim is still capped with its own vertex weights.
func _cap_neck() -> void:
	var neck_cap := preload("res://player/pony_neck_cap.gd")
	var body := avatar.find_child("MareBody",true,false) as MeshInstance3D
	var seen := neck_cap.first_person_body(body)
	if seen != null:
		body.layers = FIRST_PERSON_HIDDEN_LAYER
		_first_person_body = [body, seen]
	else:
		push_warning("Player neck closure could not be built; capping the open rim")
		seen = body
	if neck_cap.attach(seen) == null:
		push_warning("Player neck rim could not be closed")


func _hide_body_behind_view() -> void:
	var forward := -avatar.global_basis.z
	forward.y = 0.0
	var view := -Basis(Vector3.UP, rig.rotation.y).z
	# Only on her hooves: lying, sitting or flying, the view follows her head and her body stays
	# in sight from every angle (dev 2026-10-01).
	var error := rad_to_deg(forward.angle_to(view)) if forward.length_squared() > 1e-6 and not _hidden() and _steady_view() else 0.0
	if _back_hidden.is_empty() and error > BACK_HIDE_DEGREES:
		for node in avatar.find_children("*", "GeometryInstance3D", true, false):
			var mesh := node as GeometryInstance3D
			if mesh.layers & FIRST_PERSON_HIDDEN_LAYER or String(mesh.name).ends_with("_ShadowTwin"): continue
			_back_hidden.append([mesh, mesh.layers])
			mesh.layers = FIRST_PERSON_HIDDEN_LAYER
	elif not _back_hidden.is_empty() and error < BACK_SHOW_DEGREES:
		for pair: Array in _back_hidden:
			if is_instance_valid(pair[0]): (pair[0] as GeometryInstance3D).layers = int(pair[1])
		_back_hidden.clear()


func _smooth_toward(local: Vector3, delta: float) -> void:
	var headset: bool = rig.get("headset_view") == true
	var tau_h := HEADSET_TAU if headset else DESKTOP_TAU_H
	var tau_v := HEADSET_TAU if headset else (REDUCED_TAU_V if _reduced_motion else DESKTOP_TAU_V)
	var kh := 1.0 - exp(-delta / tau_h)
	var kv := 1.0 - exp(-delta / tau_v)
	_smoothed.x = lerpf(_smoothed.x, local.x, kh)
	_smoothed.z = lerpf(_smoothed.z, local.z, kh)
	var y := lerpf(_smoothed.y, local.y, kv)
	if headset:
		var limit := HEADSET_MAX_VERTICAL_SPEED * delta
		y = _smoothed.y + clampf(y - _smoothed.y, -limit, limit)
	_smoothed.y = y


## The eye midpoint (mHead times the eye centre OpenPonyEyeMotion measured) in the pony's root frame.
func _eye_sample() -> Vector3:
	if not is_instance_valid(_head_skeleton) or _head_bone < 0:
		return Vector3(0.0, _eye_height, 0.0)
	var world := _head_skeleton.global_transform * _head_skeleton.get_bone_global_pose(_head_bone) * _eye_center
	return avatar.global_transform.affine_inverse() * world


func _measure_eye_height() -> void:
	if not avatar.is_on_floor() or float(avatar.get("actual_speed")) > FACE_STILL_SPEED: return
	var status: Dictionary = avatar.posture_status()
	if str(status.get("kind", "")) != "stand" or status.get("settled") != true: return
	# Looking down pitches the head down; that is not her standing eye height.
	if absf(_view_pitch()) > EYE_LEVEL_PITCH: return
	if _cur_local.y > 0.05:
		_eye_height = lerpf(_eye_height, _cur_local.y, EYE_HEIGHT_BLEND)
		var size := maxf(float(avatar.get("body_scale")), 0.01)
		_eye_forward = lerpf(_eye_forward, clampf(-_cur_local.z / size, 0.0, 0.5), EYE_HEIGHT_BLEND)


## On her hooves (standing, walking, flying): the steady body view. Postures, seats and
## knockdowns follow the head.
func _steady_view() -> bool:
	# Flying, her pose tips her body: the view rides her head so it never leaves her (dev
	# 2026-10-01: looking up or down while flying showed her from above or below).
	if _seated or _knocked() or _piloting(): return false
	var posture: Variant = avatar.get("posture")
	return posture == null or posture.active() != true


# --------------------------------------------------------------------------- driving

func _update_eye_clearance() -> void:
	if not _alive() or rig.headset_view: return
	if _eye_collision == null:
		var sphere := SphereShape3D.new()
		_eye_collision = CollisionShape3D.new(); _eye_collision.name = "DesktopEyeClearance"
		_eye_collision.shape = sphere; avatar.add_child(_eye_collision)
		# The avatar moves against scenery; moving leaves query the rig's player
		# layer. Both must see the same eye, without changing either torso capsule.
		_rig_eye_collision = CollisionShape3D.new(); _rig_eye_collision.name = "PonyEyeClearance"
		_rig_eye_collision.shape = sphere; rig.add_child(_rig_eye_collision)
	var disabled: bool = _hidden() or not _steady_view() or rig.view_is_held()
	_eye_collision.disabled = disabled; _rig_eye_collision.disabled = disabled
	if disabled: return
	var camera := rig.camera as Camera3D
	var viewport := camera.get_viewport().get_visible_rect().size
	var aspect: float = viewport.x / maxf(viewport.y, 1.0)
	var frustum := Vector3(camera.fov, camera.near, aspect)
	if frustum != _eye_frustum:
		_eye_frustum = frustum
		var extent: float = camera.near * tan(deg_to_rad(camera.fov) * .5)
		var other: float = extent * aspect if camera.keep_aspect == Camera3D.KEEP_HEIGHT else extent / aspect
		(_eye_collision.shape as SphereShape3D).radius = sqrt(camera.near * camera.near + extent * extent + other * other) + .012
	_place_eye_clearance()


func _place_eye_clearance() -> void:
	if not is_instance_valid(_eye_collision) or _eye_collision.disabled: return
	# Also called by the player motor after yaw, before move_and_slide/step. A
	# body turn must not rotate the guard away from the independent view heading.
	var eye: Vector3 = avatar.global_position + Vector3.UP * _eye_height + Basis(Vector3.UP, rig.rotation.y) * Vector3(0.0, 0.0, -_eye_forward * float(avatar.get("body_scale")))
	_eye_collision.global_position = eye
	_rig_eye_collision.position = rig.global_basis.inverse() * (eye - avatar.global_position)


func _follow_rig() -> void:
	var balloon: Variant = _game.get("balloon") if is_instance_valid(_game) else null
	var aboard: bool = is_instance_valid(balloon) and (balloon as Object).get("_player") == rig
	if aboard and not _on_balloon:
		# As balloon.gd carries NPC passengers: the basket is her moving support.
		_on_balloon = true
		_balloon = balloon as Node3D
		_floor_layers_before = avatar.platform_floor_layers
		avatar.set_moving_support(_balloon)
	elif not aboard and _on_balloon:
		_end_balloon_support()
	if not aboard:
		# In pony mode the rig never moves itself on foot: any displacement came from other code.
		var moved := rig.global_position - _synced
		if moved.length() > TELEPORT_DISTANCE:
			_reset_at_rig()
		elif moved.length() > NUDGE_DISTANCE:
			avatar.global_position += moved
	rig.global_position = avatar.global_position
	rig.velocity = avatar.velocity
	_synced = rig.global_position


func _steer(move: Vector2, sprint: bool, slow: bool, delta: float) -> void:
	var look := Basis(Vector3.UP, rig.rotation.y)
	var forward := -avatar.global_basis.z
	forward.y = 0.0
	var has_forward := forward.length_squared() > 1e-6
	if move.length() > MOVE_DEADZONE and not _knocked():
		# Sitting or lying on the ground: only Q (or Z / X again) gets her up, never walking
		# (dev 2026-10-02: no standing up by accident or from stick drift).
		if not ground_posture().is_empty():
			avatar.stop()
			return
		var profile: Variant = avatar.get("profile")
		if profile == null: return
		# Read every tick: set_body_scale rescales the profile.
		var walk: Vector2 = profile.get("walk_speed")
		var trot: Vector2 = profile.get("trot_speed")
		var gallop: float = profile.get("max_travel_speed")
		# Input that would turn her past BACK_HIDE_DEGREES backs her up instead, as a horse backs
		# (pony_locomotion.back_up): turned round, her body left the player camera until a
		# later turn caught up (tester: "the pony's body disappears when moving backwards").
		# Facing well off the view, she first steps round to it.
		if move.y > 0.0 and absf(Vector2.DOWN.angle_to(move)) < deg_to_rad(180.0 - BACK_HIDE_DEGREES) and has_forward:
			var off := forward.angle_to(-look.z)
			if off > deg_to_rad(FACE_START_DEGREES) or (_turning and off > deg_to_rad(FACE_DONE_DEGREES)):
				avatar.face_direction(-look.z)
				_turning = true
			else:
				avatar.back_up(walk.y)
				_turning = false
			return
		var direction := (look * Vector3(move.x, 0.0, move.y)).normalized()
		var speed: float = walk.y if slow else (gallop if sprint else lerpf(trot.x, trot.y, TROT_FRACTION))
		var companion: Variant = rig.get("companion_pace")
		if companion != null and companion.enabled and not slow:
			speed = minf(gallop, companion.speed(avatar, delta))
		# Steering multiplies forward speed by cos(error), so a trot asked for behind her would
		# trot on the spot while she pivots: ease toward the walk on sharp turns instead.
		var turn := forward.angle_to(direction) if has_forward else 0.0
		speed = minf(speed, lerpf(speed, walk.y, smoothstep(deg_to_rad(TURN_EASE_FROM_DEGREES), deg_to_rad(TURN_EASE_TO_DEGREES), turn)))
		var drift: Variant = rig.get("drunk_drift")
		var sway: Vector3 = drift * 0.5 if drift is Vector3 else Vector3.ZERO
		avatar.set_desired_velocity(direction * speed + sway)
		_turning = false
		return
	# Standing: the body follows the view only when it is far off (a stepping turn).
	var view := -look.z
	var error := forward.angle_to(view) if has_forward else 0.0
	var still := float(avatar.get("actual_speed")) < FACE_STILL_SPEED
	var posture: Variant = avatar.get("posture")
	var resting: bool = posture != null and posture.active() == true
	if _turning and error < deg_to_rad(FACE_DONE_DEGREES):
		avatar.stop()
		_turning = false
	elif not resting and not _knocked() and _posture_pending.is_empty() \
			and (_turning or (error > deg_to_rad(FACE_START_DEGREES) and still)):
		avatar.face_direction(view)
		_turning = true
	else:
		avatar.stop()
		_turning = false


func _knocked() -> bool:
	return _knock_stand_left > 0.0 or _knock_lock_left > 0.0


func _update_knockdown(delta: float) -> void:
	if _knock_stand_left > 0.0:
		_knock_stand_left -= delta
		if _knock_stand_left <= 0.0:
			_posture_pending = ""
			avatar.request_posture("stand")
	if _knock_lock_left > 0.0:
		_knock_lock_left -= delta
		if _knock_lock_left <= 0.0 and rig.get("controls_locked") == true:
			rig.controls_locked = _knock_prev_locked


func _reset_at_rig() -> void:
	if not _alive(): return
	avatar.reset_motion(Transform3D(Basis(Vector3.UP, rig.rotation.y), rig.global_position))
	# reset_motion does not reset interpolation: without this the eye streaks for a frame.
	avatar.reset_physics_interpolation()
	_root_y = NAN
	_synced = rig.global_position
	_turning = false
	if _seated: _request("sit")


func _end_balloon_support() -> void:
	if not _on_balloon: return
	_on_balloon = false
	if is_instance_valid(avatar):
		var support: Variant = avatar.get("moving_support")
		if not is_instance_valid(_balloon) or not is_instance_valid(support) or support == _balloon:
			avatar.set_moving_support(null)
			avatar.platform_floor_layers = _floor_layers_before
	_balloon = null


# --------------------------------------------------------------------------- seats and postures

## Seats follow the NPC seating pattern (world/life/seating.gd): on the seat, the seat's upper
## bodies excepted, no drifting into a lie-down, and "sit" asked until she can.
func _sync_seat() -> void:
	var value: Variant = rig.get("seat")
	var seat: Node3D = value as Node3D if is_instance_valid(value) else null
	if _seated and is_instance_valid(_seat) and seat == _seat: return
	if not _seated and seat == null: return
	if _seated: _leave_seat()
	if seat != null: _enter_seat(seat)


func _enter_seat(seat: Node3D) -> void:
	_seated = true
	_seat = seat
	_end_balloon_support()
	avatar.reset_motion(Transform3D(Basis(Vector3.UP, rig.rotation.y), seat.global_position + Vector3.UP * SEAT_LIFT))
	avatar.reset_physics_interpolation()
	_synced = rig.global_position
	_turning = false
	var parent := seat.get_parent()
	if parent != null:
		for upper in parent.find_children("SeatUpper", "StaticBody3D", false, false):
			avatar.add_collision_exception_with(upper)
			_seat_uppers.append(upper)
	avatar.set_meta(&"seated", true)
	_request("sit")


## The rig has already moved to the exit point.
func _leave_seat() -> void:
	if rig.has_meta("couch_sleeping"): rig.remove_meta("couch_sleeping")
	for upper: Variant in _seat_uppers:
		if is_instance_valid(upper) and is_instance_valid(avatar):
			avatar.remove_collision_exception_with(upper as Node)
	_seat_uppers.clear()
	if is_instance_valid(avatar) and avatar.has_meta(&"seated"): avatar.remove_meta(&"seated")
	_seated = false
	_seat = null
	_posture_pending = ""
	_reset_at_rig()


func _request(kind: String) -> void:
	_posture_pending = kind
	_posture_tries = 0
	_try_posture()


## A posture request is refused while she is still moving or not yet supported (a seat landing
## takes a tick or two): ask again every tick, up to POSTURE_TRIES.
func _try_posture() -> void:
	if _posture_pending.is_empty() or not is_instance_valid(avatar): return
	var accepted: bool = avatar.request_posture(_posture_pending)
	if accepted:
		_posture_pending = ""
		return
	_posture_tries += 1
	if _posture_tries > POSTURE_TRIES:
		var status: Dictionary = avatar.posture_status()
		print("[pony_form] could not %s: %s" % [_posture_pending, str(status.get("refusal", ""))])
		_posture_pending = ""


# --------------------------------------------------------------------------- setup helpers

## Nothing may hit the player's own pony: the interactor ray, the hint rays, the kisser's head
## contact queries and the head guard. The body itself leaves the pony layer (player_pony.gd).
func _strip_contacts() -> void:
	for node in avatar.find_children("*", "CollisionObject3D", true, false):
		var body := node as CollisionObject3D
		if body == null or body == avatar: continue
		body.collision_layer = 0
		body.collision_mask = 0
		if body is Area3D:
			(body as Area3D).monitoring = false
			(body as Area3D).monitorable = false
	# The hand-contact hulls are PhysicsServer bodies; off, they are never created awake.
	var touch: Variant = avatar.get("touch_body")
	if is_instance_valid(touch): (touch as Object).set("enabled", false)


func _measure_head() -> void:
	var head := avatar.get("head") as Node3D
	if head == null: return
	_head_skeleton = head.get("skeleton") as Skeleton3D
	if _head_skeleton != null: _head_bone = _head_skeleton.find_bone("mHead")
	var eye_motion: Variant = avatar.get("eye_motion")
	if is_instance_valid(eye_motion):
		var center: Variant = (eye_motion as Object).get("_eye_center_head")
		if center is Vector3: _eye_center = center
	# The mouth: the InnerMouth mesh's centre at rest, in mHead's frame.
	var model := head.get("model") as Node
	if model == null or _head_skeleton == null or _head_bone < 0: return
	var inner := model.find_child("InnerMouth", true, false) as MeshInstance3D
	if inner == null or inner.mesh == null: return
	var at_rest := _head_skeleton.global_transform.affine_inverse() * (inner.global_transform * inner.get_aabb().get_center())
	_mouth_head = _head_skeleton.get_bone_global_rest(_head_bone).affine_inverse() * at_rest
	_has_mouth = true


## Head model meshes (horn included) and the mane go on layer 18, which the player camera does
## not draw. Each gets a shadow-only twin on layer 1, so the player's shadow keeps its head.
func _hide_head_from_player() -> void:
	var hidden: Array[MeshInstance3D] = []
	var head := avatar.get("head") as Node3D
	var model: Variant = head.get("model") if head != null else null
	if model is Node:
		for node in (model as Node).find_children("*", "MeshInstance3D", true, false):
			hidden.append(node as MeshInstance3D)
	var hair: Variant = avatar.get("hair")
	var identity: Variant = avatar.get("identity")
	if hair is Node and identity != null:
		var prefix := str((identity as Object).get("hair_prefix")) + "DevkitMane"
		for node in (hair as Node).find_children("*", "MeshInstance3D", true, false):
			if String(node.name).begins_with(prefix): hidden.append(node as MeshInstance3D)
	# The unicorn horn belongs to the body model, not the head: from the eye it stood up in the
	# middle of the view.
	for node in avatar.find_children("*", "MeshInstance3D", true, false):
		if String(node.name).begins_with("Unicorn Horn") and not hidden.has(node): hidden.append(node as MeshInstance3D)
	for mi in hidden:
		mi.layers = FIRST_PERSON_HIDDEN_LAYER
	var camera := rig.get("camera") as Camera3D
	if camera != null:
		camera.cull_mask &= ~FIRST_PERSON_HIDDEN_LAYER
	if HEAD_SHADOW_TWINS:
		for mi in hidden:
			_add_shadow_twin(mi)


## The HornMagicAura pattern (unicorn_magic.gd): the same mesh on the same skin and skeleton. No
## blend-shape weights, so the shadow's face is neutral.
func _add_shadow_twin(original: MeshInstance3D) -> void:
	if original.mesh == null or not original.visible: return
	if original.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF: return
	var parent := original.get_parent()
	if parent == null: return
	var twin := MeshInstance3D.new()
	twin.name = String(original.name) + "_ShadowTwin"
	twin.mesh = original.mesh
	twin.skin = original.skin
	twin.material_override = original.material_override
	for surface in original.mesh.get_surface_count():
		twin.set_surface_override_material(surface, original.get_surface_override_material(surface))
	twin.custom_aabb = original.custom_aabb
	twin.extra_cull_margin = original.extra_cull_margin
	twin.layers = 1
	twin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	# Shadow-only twin: the outline survives coarser LODs (2026-10-23 GPU pass, ~100k shadow triangles).
	twin.lod_bias = 0.25
	parent.add_child(twin)
	twin.transform = original.transform
	# A hidden rig mesh may have parked its skeleton path (hybrid_mare.gd set_rig_parking).
	var path: NodePath = original.get_meta(&"parked_skeleton") if original.has_meta(&"parked_skeleton") else original.skeleton
	var skeleton := original.get_node_or_null(path)
	if skeleton != null: twin.skeleton = twin.get_path_to(skeleton)
	_twins.append([original, twin])


## hybrid_mare._set_rig_shadows would turn every mesh to SHADOWS_ON (a twin would then draw on
## layer 1); a twin also hides with its original (hair LOD, near/far switches).
func _keep_twins() -> void:
	for pair: Array in _twins:
		if not is_instance_valid(pair[0]) or not is_instance_valid(pair[1]): continue
		var original := pair[0] as MeshInstance3D
		var twin := pair[1] as MeshInstance3D
		if twin.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			twin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		var shown := original.visible and original.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if twin.visible != shown: twin.visible = shown
	# The first-person body follows MareBody's visibility, shadows, materials and parking.
	if _first_person_body.size() == 2 and is_instance_valid(_first_person_body[0]) and is_instance_valid(_first_person_body[1]):
		var body := _first_person_body[0] as MeshInstance3D
		var seen := _first_person_body[1] as MeshInstance3D
		if seen.visible != body.visible: seen.visible = body.visible
		if seen.cast_shadow != body.cast_shadow: seen.cast_shadow = body.cast_shadow
		if seen.skeleton != body.skeleton: seen.skeleton = body.skeleton
		if seen.material_override != body.material_override: seen.material_override = body.material_override
		if seen.material_overlay != body.material_overlay: seen.material_overlay = body.material_overlay
		for surface in body.mesh.get_surface_count():
			if seen.get_surface_override_material(surface) != body.get_surface_override_material(surface):
				seen.set_surface_override_material(surface, body.get_surface_override_material(surface))


func _on_setting_changed(key: String) -> void:
	match key:
		"ponies/size":
			if is_instance_valid(avatar): avatar.set_body_scale(_pony_scale())
			_eye_height = estimate_eye_height(form)
			_resize_rig_capsule()
		"access/reduced_motion":
			var settings := _settings()
			_reduced_motion = settings != null and settings.call("get_value", "access/reduced_motion") == true


## The rig capsule at pony size keeps the hinged doors' layer check and the seat-exit sizes working.
func _resize_rig_capsule() -> void:
	if not _alive() or not rig.has_method("set_body_capsule"): return
	var size := float(avatar.get("body_scale"))
	rig.call("set_body_capsule", CAPSULE_RADIUS * size, _eye_height + CAPSULE_HEADROOM)


# --------------------------------------------------------------------------- state

## Parked and hidden (title, loading cover, wake poses, debug flight): the VR magic hands rest.
func avatar_hidden() -> bool:
	return _hidden()


func _alive() -> bool:
	return is_instance_valid(rig) and is_instance_valid(avatar)


func _hidden() -> bool:
	return _hide_requested or _hold_parked or _fly_parked


## Parked (no physics) and hidden for any of the three reasons; the pivot carries every mesh,
## twins and socks included.
func _refresh_park() -> void:
	if not is_instance_valid(avatar): return
	var hidden := _hidden()
	avatar.parked = hidden
	var pivot := avatar.get("pivot") as Node3D
	if pivot != null: pivot.visible = not hidden


func _view_pitch() -> float:
	if not is_instance_valid(rig) or rig.get("headset_view") == true: return 0.0
	var value: Variant = rig.get("_pitch")
	return float(value) if value is float else 0.0


## Rig yaw and the mouse pitch; seated keeps the pitch at 0, so turning your real head never
## turns the pony's neck under you.
func _view_basis() -> Basis:
	if not is_instance_valid(rig): return Basis.IDENTITY
	return Basis.from_euler(Vector3(_view_pitch(), rig.rotation.y, 0.0))
