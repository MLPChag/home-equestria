extends RefCounted
## Picking a pony up (split from pony_locomotion.gd, 2026-10-13): one-hand and two-hand grabs,
## moving the hands, letting go. The hold state stays on the pony (`_held`, `_hold_target`,
## `_hand_targets`, `_interaction`, ...), where the motor reads it every step; the carry pose is
## pony_carry.gd. Calls back into the pony go through `pony.` so overrides still apply.


static func begin_grab(pony: Node, grip: String, world_target: Vector3, player_head: Vector3) -> void:
	pony.placement_recovery.picked_up(pony)
	# Physically picking her up is a wake event, unlike residual navigation requests.
	if pony.get("sleeping") == true: pony.set("sleeping", false)
	if pony.thrown != null: pony.thrown.cancel()
	if pony.flight != null: pony.flight.cancel()
	pony.hoof_hold.release()
	var hands: Dictionary = pony._hand_targets
	hands.clear()
	pony._held = true
	# Loose, smooth lift (dev 2026-09-28): the 30 cm floor snap pulled a held pony back onto the
	# floor every step until the lift outran it, then she jumped up to the hands at once.
	pony.floor_snap_length = 0.0
	pony._hold_velocity = pony.velocity
	pony._hold_target = world_target
	pony._interaction = "HELD"
	pony._interaction_seconds = 0.0
	pony._touch_force = Vector3.ZERO
	pony.carry.begin(grip, player_head)
	if pony.posture != null: pony.posture.reset(true)


static func begin_two_hand_grab(pony: Node, left_target: Vector3, right_target: Vector3, player_head: Vector3) -> void:
	pony.begin_grab("chest", (left_target + right_target) * 0.5, player_head)
	pony._hand_targets = {"left_chest": left_target, "right_chest": right_target}


static func update_hand_grab(pony: Node, grip: String, world_target: Vector3, player_head: Vector3) -> void:
	var hands: Dictionary = pony._hand_targets
	if not hands.has(grip):
		return
	hands[grip] = world_target
	var hold_target := Vector3.ZERO
	for target: Vector3 in hands.values():
		hold_target += target / hands.size()
	pony._hold_target = hold_target
	pony.carry.look_target = player_head


static func release_hand_grab(pony: Node, grip: String) -> void:
	var hands: Dictionary = pony._hand_targets
	if not hands.has(grip):
		if hands.is_empty() and grip == pony.carry.grip_name:
			pony.end_interaction()
		return
	hands.erase(grip)
	if hands.is_empty():
		pony.end_interaction()
	elif hands.size() == 1:
		pony.carry.grip_name = hands.keys()[0]
		pony._hold_target = hands.values()[0]


static func update_grab(pony: Node, world_target: Vector3, player_head: Vector3) -> void:
	var shift: Vector3 = world_target - pony._hold_target
	var hands: Dictionary = pony._hand_targets
	for grip: String in hands:
		hands[grip] = Vector3(hands[grip]) + shift
	pony._hold_target = world_target
	pony.carry.look_target = player_head


static func end_interaction(pony: Node) -> void:
	if pony._held: pony.floor_snap_length = 0.3 * pony.body_scale
	pony._held = false
	pony._interaction = ""
	pony._interaction_seconds = 0.0
	pony._touch_force = Vector3.ZERO
	var hands: Dictionary = pony._hand_targets
	hands.clear()
	pony._hold_yaw = INF
	pony.carry.end()


static func begin_hold(pony: Node, world_position: Vector3) -> void:
	var root: Vector3 = pony.global_position
	var offset: Vector3 = pony.get_grip_transform().origin - root
	pony._hold_root_offset = offset
	var basis: Basis = pony.global_basis
	pony.begin_grab("chest", world_position + offset, root - basis.z * 1.5 + Vector3.UP * 1.5)
