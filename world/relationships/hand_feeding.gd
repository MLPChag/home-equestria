extends Node
## Feeding a pony from the hand (dev 2026-09-29: "feeding mares food like oats from hand"). Hold
## any food at a pony's mouth for a moment: if she welcomes it she takes it, a crunch, a happy
## fluster, and she remembers that Anon fed her (a gift in her bond with him, a world event). A
## pony who is cross with him, or asked for space, turns her head away instead.
## Drinks and meals work too; a container (the oat pouch) stays in the hand, empty.
const SFX := preload("res://world/audio/interaction_sounds.gd")
const FOLEY := preload("res://world/audio/props_catalogue.gd")
const FOOD := preload("res://world/food/food_interaction.gd")
const CATALOG := preload("res://world/food/food_catalog.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const REACH := 0.2
const HOLD_SECONDS := 0.8
var game: Node
var _held_at: Dictionary = {}   # side -> [pony, seconds]
var _refused: Dictionary = {}   # pony id -> time of last refusal
var _tick := 0.0

func setup(host: Node) -> void:
	game = host
	add_to_group("hand_feeding")
	add_to_group("interaction_hint_sources")

## Desktop: holding food or a gift and looking at a pony's face within arm's reach. Kept tight
## so eating across a table from her (click) still eats instead of feeding her.
func desktop_target() -> Node3D:
	var inventory: Node = game.inventory
	if not inventory._desktop or not inventory.held.has("desktop"): return null
	var item: Node = inventory.held.desktop
	if not is_instance_valid(item) or not _offerable(str(item.get_meta("item_id", ""))): return null
	var camera: Camera3D = inventory.camera
	var best: Node3D = null; var best_gap := 0.3
	for pony: Variant in game.mares:
		if not is_instance_valid(pony) or not pony.is_inside_tree() or not pony.is_visible_in_tree() or bool(pony.get("sleeping")): continue
		var affection: Node = (pony as Node).get_node_or_null("Affection")
		if affection == null: continue
		var mouth: Vector3 = affection.mouth_point()
		var to := mouth - camera.global_position
		if to.length() > 1.6 or to.length() < 0.1: continue
		var off := (to - (-camera.global_basis.z) * to.dot(-camera.global_basis.z)).length()
		if off >= best_gap or to.dot(-camera.global_basis.z) <= 0.0: continue
		var excluded:Array[RID]=[]
		if item is CollisionObject3D:excluded.append(item.get_rid())
		if "player_body" in inventory and inventory.player_body is CollisionObject3D:excluded.append(inventory.player_body.get_rid())
		var query:=PhysicsRayQueryParameters3D.create(camera.global_position,mouth,1,excluded)
		if not camera.get_world_3d().direct_space_state.intersect_ray(query).is_empty():continue
		best = pony; best_gap = off
	return best

func _offerable(id: String) -> bool:
	return id.begins_with("wear:") or id in ["apple", "carrot"] or (CATALOG.has(id) and CATALOG.can_consume(id))

## Desktop click while looking at her: offer what is in hand (briefcase_inventory.gd).
func desktop_offer() -> bool:
	var pony := desktop_target()
	if pony == null: return false
	var item: RigidBody3D = game.inventory.held.desktop
	_offer("desktop", item, pony, str(item.get_meta("item_id", "")))
	return true

func interaction_hint() -> Dictionary:
	var pony := desktop_target()
	if pony == null: return {}
	var id := str(game.inventory.held.desktop.get_meta("item_id", ""))
	return {"target": pony, "text": "Click · " + ("Give" if id.begins_with("wear:") else "Feed"), "point": pony.get_node("Affection").mouth_point(), "outline": null}

func _physics_process(delta: float) -> void:
	if game == null or not is_instance_valid(game.get("inventory")): return
	_tick += delta
	if _tick < 0.1: return
	var dt := _tick; _tick = 0.0
	var inventory: Node = game.inventory
	for side: String in inventory.held.keys():
		# Desktop hands follow the view; proximity alone is not an intentional offer.
		# The click adapter owns desktop feeding/gifts. VR keeps the physical hold gesture.
		if side == "desktop": _held_at.erase(side); continue
		var item: Variant = inventory.held[side]
		if not is_instance_valid(item): _held_at.erase(side); continue
		var id := str((item as Node).get_meta("item_id", ""))
		var gift := id.begins_with("wear:")
		if not gift and not (CATALOG.has(id) and CATALOG.can_consume(id)) and id not in ["apple", "carrot"]: _held_at.erase(side); continue
		var pony := _pony_at((item as Node3D).global_position)
		if pony == null: _held_at.erase(side); continue
		var row: Array = _held_at.get(side, [null, 0.0])
		row = [pony, float(row[1]) + dt if row[0] == pony else 0.0]
		_held_at[side] = row
		if pony.has_method("set_action_gaze"): pony.set_action_gaze(item)
		if float(row[1]) >= HOLD_SECONDS:
			_held_at.erase(side)
			_offer(side, item, pony, id)

## The awake pony whose mouth is within REACH of the food.
func _pony_at(point: Vector3) -> Node3D:
	for pony: Variant in game.mares:
		if not is_instance_valid(pony) or not (pony as Node3D).is_inside_tree() or bool(pony.get("sleeping")): continue
		if (pony as Node3D).global_position.distance_to(point) > 2.5: continue
		var affection: Node = (pony as Node).get_node_or_null("Affection")
		if affection == null or not affection.has_method("mouth_point"): continue
		if affection.mouth_point().distance_to(point) < REACH * 1.5: return pony
	return null

func _offer(side: String, item: RigidBody3D, pony: Node3D, id: String) -> void:
	if id.begins_with("wear:"):
		_give_wear(side, item, pony, id); return
	var pony_id := str(pony.get_meta("relationship_id", ""))
	var bonds: Node = game.world_context.get("player_bonds") if game.world_context != null else null
	var identity: Resource = pony.get("identity")
	var filly: bool = identity != null and bool(identity.get("filly"))
	var willing := true
	if bonds != null and pony_id != "" and not filly:
		var record: Dictionary = bonds.record_for(pony_id)
		willing = bonds.anger(pony_id) < 35.0 and Time.get_unix_time_from_system() >= float(record.get("cooldowns", {}).get("boundary", 0.0))
	if not willing:
		_refused[pony_id] = Time.get_ticks_msec()
		if pony.has_method("set_action_gaze"): pony.set_action_gaze(null)
		print("[feeding] %s turns away" % pony_id)
		return
	var inventory: Node = game.inventory
	var token := str(item.get_meta("token", ""))
	var store: RefCounted = inventory.inventory
	if not store.loans.has(token): return
	var empty := CATALOG.empty_id(id) if CATALOG.has(id) else ""
	if empty.is_empty():
		if not store.consume(token): return
		inventory.held.erase(side); inventory.loose.erase(token); inventory._track.erase(side); inventory._claim(side, false)
		item.queue_free(); inventory._refresh_holding()
	else:
		if not store.replace_held(token, empty): return
		item.set_meta("item_id", empty)
		var visual: Node3D = item.get_meta("food_visual")
		visual.food_id = empty; visual.show_empty()
		FOOD.configure(item, visual, item.get_child(0) as CollisionShape3D)
		inventory._refresh_holding()
	SFX.play_event(pony, FOLEY.food_cue_for_item(id), {"intensity": .7}, pony.get_node("Affection").mouth_point())
	inventory._haptic(side)
	var expressions: Variant = pony.get("expressions")
	if expressions != null and expressions.has_method("fluster"): expressions.fluster(0.8)
	# Spike chomps it (his mouth opens for the bite).
	if pony.has_method("mouth_hold"): pony.mouth_hold(0.4, 0.8)
	if pony.has_method("set_action_gaze"): pony.set_action_gaze(game._find_camera(game.player))
	var name: String = str(CATALOG.definition(id).get("name", id)) if CATALOG.has(id) else id
	if bonds != null and pony_id != "":
		bonds.experience(pony_id, "gift", "fed_%d" % Time.get_ticks_usec())
		# AnonPony has no hand to feed from (world/life/player_form.gd).
		var memory := "Anon offered you %s." if PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree())) else "Anon fed you %s from his hand."
		game.world_context.record("gift", memory % name.to_lower(), [pony_id, "player"], [pony_id, "player"])
	print("[feeding] %s ate %s from Anon's hand" % [pony_id, id])

## A scarf, hat or socks held up to her: she takes it and wears it from then on
## (world/characters/accessories/pony_wardrobe.gd gifts), and remembers who gave it.
func _give_wear(side: String, item: RigidBody3D, pony: Node3D, id: String) -> void:
	var wardrobe: Node = get_tree().get_first_node_in_group("pony_wardrobe")
	var identity: Resource = pony.get("identity")
	if wardrobe == null or identity == null: return
	var pony_id := str(identity.id)
	var inventory: Node = game.inventory
	var token := str(item.get_meta("token", ""))
	if not inventory.inventory.loans.has(token) or not wardrobe.can_give(pony_id, id, pony): return
	if not inventory.inventory.consume(token): return
	wardrobe.give(pony_id, id, pony)
	inventory.held.erase(side); inventory.loose.erase(token); inventory._track.erase(side); inventory._claim(side, false)
	item.queue_free(); inventory._refresh_holding(); inventory._haptic(side)
	wardrobe.dress(pony, pony_id, wardrobe._season())
	var expressions: Variant = pony.get("expressions")
	if expressions != null and expressions.has_method("fluster"): expressions.fluster(1.2)
	var name: String = str(preload("res://world/shop/shop_items.gd").definition(id).get("name", "gift")).to_lower()
	var bonds: Node = game.world_context.get("player_bonds")
	if bonds != null: bonds.experience(pony_id, "gift", "wear_%d" % Time.get_ticks_usec())
	game.world_context.record("gift", "Anon gave you a %s, and you are wearing it." % name, [pony_id, "player"], [pony_id, "player"])
	print("[gift] %s now wears %s" % [pony_id, id])
