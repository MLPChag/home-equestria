extends Node
## Nearby grip-only handles. Claims the hand through the existing inventory gates.
var inventory: Node
var holding: Dictionary={}
var pressed: Dictionary={"left":true,"right":true}
## Release once after tracking/menu recovery; then squeezing before contact can still latch.
## Normal release/separation does not consume it: returning to a handle may latch again.
var armed: Dictionary={"left":false,"right":false}
const GRIP_PRESS := 0.45
const GRIP_RELEASE := 0.25
var hovered: Dictionary={} # side -> door whose handle that free hand can grip (blue glow)
func _ready() -> void:
	process_physics_priority=-50
	add_to_group("grab_providers")
func grab_offer(side: String, sample: Dictionary) -> Dictionary:
	if holding.has(side): return {}
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	var point: Vector3 = sample.get("grip_position", pose.origin)
	var door: Node3D = reachable(point)
	if door == null: return {}
	return {"target":door,"point":door.grip_point(point),"outline":null,"text":"Grip · Open","distance":point.distance_to(door.grip_point(point))}
func grab_take(side: String, offer: Dictionary, sample: Dictionary) -> bool:
	var hand: Node = inventory.hands.get(side)
	var pose: Transform3D = sample.get("pose",Transform3D.IDENTITY)
	var point: Vector3 = sample.get("grip_position",pose.origin)
	if not is_instance_valid(hand) or not offer.target.begin_offered_grip(hand,point): return false
	holding[side]=offer.target; hand.set_meta("door_grip",self); hand.set_meta("inventory_busy",true)
	_hover(side,null); inventory._haptic(side); return true
func _physics_process(_delta: float) -> void:
	if not is_instance_valid(inventory):return
	for side: String in ["left","right"]:
		var sample: Dictionary=inventory.hand_sample(side)
		var hand: Node=inventory.hands.get(side)
		var aim:Transform3D=sample.get("aim",Transform3D.IDENTITY)
		var pose: Transform3D = sample.get("pose", aim)
		# Aim is the ray/controller frame; skinning and physical-hand collision can put the
		# visible palm elsewhere. Touch, push and drag the pull with the palm the player sees.
		var point: Vector3 = sample.get("grip_position", pose.origin)
		var active:bool=sample.get("active",false) and is_instance_valid(hand) and sample.has("aim") and aim.is_finite() and pose.is_finite() and point.is_finite()
		var down:bool=active and float(sample.get("grip",0))>(GRIP_RELEASE if pressed[side] else GRIP_PRESS)
		var locked:bool=inventory.player_body.controls_locked if is_instance_valid(inventory.player_body) and "controls_locked" in inventory.player_body else false
		if not active or locked:
			armed[side]=false
		elif not down:
			armed[side]=true
		if holding.has(side):
			_hover(side,null)
			var held_door:Variant=holding[side]
			var door:Node=held_door if is_instance_valid(held_door) else null
			if not is_instance_valid(door) or not active or not down or locked:
				release(side)
			else:
				if point.distance_to(door.grip_point(point))>.8:release(side)
				else:door.drag(point)
		else:
			var router: Node = inventory.get("grab_router")
			if router != null:
				var offer: Dictionary = router.offer(side)
				_hover(side, offer.get("target") if offer.get("provider") == self else null)
				if active and not locked and not down and not inventory.hand_busy(side): _palm(side,point)
				pressed[side]=down
				continue
			# An equipped hotbar item goes back to its slot when the hand takes a handle.
			var free:bool=not inventory.hand_busy(side) or inventory.equipped_only(side)
			var nearest:Node=reachable(point) if active and not locked and free and armed[side] else null
			_hover(side,nearest)
			if nearest!=null and down and armed[side] and inventory.equipped_only(side):inventory._store_held(side)
			if nearest!=null and down and armed[side] and not inventory.hand_busy(side) and nearest.begin_grip(hand,point):
				_hover(side,null)
				holding[side]=nearest;hand.set_meta("door_grip",self);hand.set_meta("inventory_busy",true);inventory._haptic(side)
			elif active and not locked and not down and not inventory.hand_busy(side):
				_palm(side,point)
		# A released grip is required after lost tracking/menu closure before relatching.
		pressed[side]=down if active and not locked else true
		# Releasing a held door also counts; do not demand a second open-hand frame.
		if active and not locked and not down:armed[side]=true
## Authoritative displayed offer. Hints must not independently promise an unarmed grip.
func grip_offer(side: String) -> Node3D:
	var door: Variant = hovered.get(side)
	return door as Node3D if is_instance_valid(door) else null
## Nearest free handle within grip reach of a hand point, not behind a jamb or wall.
func reachable(point: Vector3) -> Node:
	return reachable_in(get_tree(), point)
## The same test for any hand without a DoorGrip of its own (the VR magic hands,
## player/magic_hands/magic_hand.gd).
static func reachable_in(tree: SceneTree, point: Vector3) -> Node:
	if tree == null or not point.is_finite():return null
	var nearest:Node=null;var distance:float=INF
	for door:Node in tree.get_nodes_in_group("house_doors"):
		# A handle a metre from the hand cannot be gripped: no face/occlusion work for it
		# (the Quest profile had can_grip at 223 ms a frame over every door in town, 2026-09-29).
		# Measured from the handle, not the hinge: wide leaves put the handle up to 2.4 m from
		# their hinge origin, and the old hinge test made Golden Oak's door ungrippable.
		if not (door is Node3D) or door.handle_world().distance_to(point)>1.0:continue
		var d:float=point.distance_to(door.grip_point(point))
		# Test each candidate's own face and occlusion before choosing the nearest.
		# A hidden handle must not mask another reachable door beside it.
		if d<distance and door.can_grip(point):nearest=door;distance=d
	return nearest
## An open, empty hand against a leaf pushes it (hinged_door.palm_push); a light tick each time
## it starts moving a door.
var _pushing: Dictionary = {}
func _palm(side: String, point: Vector3) -> void:
	var pushed: Node = null
	for door: Node in get_tree().get_nodes_in_group("house_doors"):
		if not (door is Node3D) or not door.has_method("palm_push") or door.global_position.distance_to(point) > 3.0: continue
		if door.palm_push(side, point): pushed = door; break
	if pushed != null and _pushing.get(side) != pushed: inventory._haptic(side)
	_pushing[side] = pushed
func _hover(side: String, door: Node) -> void:
	var previous:Variant=hovered.get(side)
	var old:Node=previous if is_instance_valid(previous) else null
	if not is_instance_valid(previous):hovered.erase(side)
	if old==door:return
	hovered[side]=door
	for changed:Node in [old,door]:
		if is_instance_valid(changed):changed.set_hovered(hovered.values().has(changed))
func release(side: String) -> void:
	var held_door:Variant=holding.get(side)
	var door:Node=held_door if is_instance_valid(held_door) else null
	if is_instance_valid(door):door.end_grip()
	holding.erase(side)
	var hand:Node=inventory.hands.get(side)
	if is_instance_valid(hand) and hand.get_meta("door_grip",null)==self:
		hand.remove_meta("door_grip");hand.remove_meta("inventory_busy")
func _exit_tree() -> void:
	for side: String in hovered.keys():_hover(side,null)
	if is_instance_valid(inventory):
		for side: String in holding.keys():release(side)
