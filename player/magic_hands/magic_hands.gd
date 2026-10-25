extends Node
## AnonPony's hands in a headset (dev 2026-10-15: "any pony can have 'hands' in the magic sense
## while also being in vr"). In seated VR the player pony (player/pony_form.gd) is walked with the
## keyboard as on the desktop; this adds the two motion controllers, each shown as a small magic
## wisp in her magic colour that grips and lifts things in her magic (magic_hand.gd). Earth
## ponies, pegasi and unicorns all have them; a unicorn's horn lights while one holds.
##
## The controllers are this rig's own ("MagicControllerLeft/Right" under the seated XROrigin),
## named apart from the room-scale rig's XRControllerLeft/Right so the systems that look those up
## by name (inventory, pony grabber, kisser, boops) keep their seated keyboard behaviour. The
## wisps run every physics tick, like the human hands. Room-scale VR plays human Anon with
## physics hands; desktop has no controllers: attach() returns null for both.
## No class_name: pony_form.gd loads this file.
const HAND := preload("res://player/magic_hands/magic_hand.gd")
const CONTROLLER := preload("res://player/xr_grounded_controller.gd")
const UNICORN_MAGIC := preload("res://world/characters/magic/unicorn_magic.gd")
const SIDES := ["left", "right"]
## The controllers' pose: the palm, as the room-scale rig's hands use.
const POSE := &"palm_pose"

## player/pony_form.gd and its rig (desktop_player.gd in seated_player.tscn).
var form: Node
var rig: Node3D
## The wisps' magic colour: UnicornMagic.color_for(her identity), for every race.
var color := Color.MEDIUM_PURPLE
## side -> magic_hand.gd, and side -> its XRController3D.
var hands: Dictionary = {}
var controllers: Dictionary = {}


## The magic hands for `pony_form` on `player_rig`, or null when the rig has no headset view.
## Idempotent.
static func attach(pony_form: Node, player_rig: Node3D) -> Node:
	if not is_instance_valid(pony_form) or not is_instance_valid(player_rig): return null
	if player_rig.get("headset_view") != true: return null
	var origin := player_rig.find_child("XROrigin", true, false) as XROrigin3D
	if origin == null: return null
	var existing := pony_form.get_node_or_null("MagicHands")
	if existing != null: return existing
	var script := load("res://player/magic_hands/magic_hands.gd") as GDScript
	if script == null: return null
	var node: Node = script.new()
	node.name = "MagicHands"
	node.set("form", pony_form)
	node.set("rig", player_rig)
	pony_form.add_child(node)
	node.call("_build", origin)
	return node


func _build(origin: XROrigin3D) -> void:
	add_to_group("magic_grab_sources")
	var identity: Variant = avatar().get("identity") if is_instance_valid(avatar()) else null
	if identity is Resource: color = UNICORN_MAGIC.color_for(identity)
	for side: String in SIDES:
		var controller: XRController3D = CONTROLLER.new()
		controller.name = "MagicController" + side.capitalize()
		controller.tracker = StringName(side + "_hand")
		controller.pose = POSE
		origin.add_child(controller)
		# The same wiring as xr_player_physics.tscn: grip and grip_click become grab(bool).
		controller.button_pressed.connect(Callable(controller, "_on_button_pressed"))
		controller.button_released.connect(Callable(controller, "_on_button_released"))
		controller.input_float_changed.connect(Callable(controller, "_on_input_float_changed"))
		var hand: Node3D = HAND.new()
		hand.name = "MagicHand" + side.capitalize()
		hand.set("side", side)
		hand.set("hands", self)
		hand.set("controller", controller)
		controller.add_child(hand)
		controller.connect("grab", Callable(hand, "_on_grab"))
		hands[side] = hand
		controllers[side] = controller
	print("[magic hands] ready: grip with either controller to lift things in magic")


func _exit_tree() -> void:
	# The controllers live under the rig's XROrigin, not under this node.
	for side: String in controllers:
		var controller: Node = controllers[side]
		if is_instance_valid(controller): controller.queue_free()
	controllers.clear(); hands.clear()


# ------------------------------------------------------------------ used by magic_hand.gd

func avatar() -> Node3D:
	return form.get("avatar") as Node3D if is_instance_valid(form) else null


## The wisps are live: the rig runs and the player pony is shown (not parked under the title,
## the loading cover, a wake pose or debug flight).
func active() -> bool:
	if not is_instance_valid(rig) or not is_instance_valid(avatar()) or not rig.is_physics_processing(): return false
	return not (form.has_method("avatar_hidden") and form.call("avatar_hidden") == true)


## A new grab may start: active, no menu holding the controls, the game not paused.
func can_grab() -> bool:
	return active() and rig.get("controls_locked") != true and not get_tree().paused


func head() -> Vector3:
	var camera := rig.get("camera") as Node3D if is_instance_valid(rig) else null
	return camera.global_position if camera != null else (rig.global_position if is_instance_valid(rig) else Vector3.ZERO)


## The unicorn's horn magic (its glow on what she lifts, the horn lit), else null.
func magic() -> Node:
	if not is_instance_valid(form) or not form.has_method("is_unicorn") or form.call("is_unicorn") != true: return null
	return form.call("magic")


func inventory() -> Node:
	var game: Variant = form.get("_game") if is_instance_valid(form) else null
	if not game is Node or not is_instance_valid(game): return null
	var found: Variant = (game as Node).get("inventory")
	return found as Node if found is Node and is_instance_valid(found) else null


## Bodies the wisps never catch: the rig and the player pony.
func excluded() -> Array:
	var rids: Array = []
	for body: Variant in [rig, avatar()]:
		if body is CollisionObject3D and is_instance_valid(body): rids.append((body as CollisionObject3D).get_rid())
	return rids


## `thing` is already held: by the other wisp, the horn's G telekinesis, or the inventory (her
## mouth-held item floating before her eyes).
func taken(thing: Node, by: Node) -> bool:
	for side: String in hands:
		var hand: Node = hands[side]
		if hand != by and is_instance_valid(hand) and hand.get("held") == thing: return true
	var telekinesis: Node = form.get_node_or_null("UnicornTelekinesis") if is_instance_valid(form) else null
	if telekinesis != null and telekinesis.get("target") == thing: return true
	var bag := inventory()
	if bag != null and "held" in bag:
		var held: Variant = bag.get("held")
		if held is Dictionary and thing in (held as Dictionary).values(): return true
	return false


## The horn stays lit while either wisp holds something (each release turns it off first).
func sync_horn() -> void:
	var magic_node := magic()
	if not is_instance_valid(magic_node) or not magic_node.has_method("hold"): return
	var any := false
	for side: String in hands:
		var hand: Node = hands[side]
		if is_instance_valid(hand) and hand.get("held") != null: any = true
	if any: magic_node.call("hold", true)


## Test and debug hook: the wisp for `side`.
func hand(side: String) -> Node3D:
	return hands.get(side) as Node3D


## Read by the existing outline owner, including in seated keyboard inventory mode.
func grab_offers() -> Array[Dictionary]:
	var offers: Array[Dictionary] = []
	for side: String in SIDES:
		var wisp: Node = hands.get(side)
		if not is_instance_valid(wisp): continue
		var offer: Dictionary = wisp.call("grab_offer")
		if not offer.is_empty(): offers.append(offer)
	return offers
