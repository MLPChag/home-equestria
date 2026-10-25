extends RefCounted
## Magic supplies motion; the briefcase still owns every item transaction. Separate side names
## prevent seated keyboard presentation and human VR pose updates from moving a wisp's item.
var hand: Node3D
var bag: Node
var item: RigidBody3D
var token := ""
var store: RefCounted
var _id := ""


func _init(owner_hand: Node3D) -> void:
	hand = owner_hand


func side() -> String:
	return "magic_" + str(hand.get("side"))


func managed() -> bool:
	return not token.is_empty()


## Exact live owner, node and loan identity: a restored save may reuse a token for another node.
func current() -> bool:
	if not is_instance_valid(bag) or not bag.is_inside_tree() or not is_instance_valid(item) or item.is_queued_for_deletion(): return false
	if not is_instance_valid(hand.hands) or hand.hands.inventory() != bag: return false
	return bag.inventory == store and bag.held.get(side()) == item and bag.loose.get(token) == item \
		and bag.inventory.loans.has(token) and str(bag.inventory.loans[token].id) == str(item.get_meta("item_id", ""))


func forget() -> void:
	bag = null; item = null; token = ""; store = null; _id = ""


## Unexpected node deletion returns its exact outstanding unit; failed writes leave the loan
## recoverable on reload. Save restoration already cleared these references and is untouched.
func reconcile() -> void:
	if is_instance_valid(bag) and bag.is_inside_tree() and bag.inventory == store \
			and bag.held.get(side()) == item and bag.loose.get(token) == item:
		if store.loans.has(token) and str(store.loans[token].id) == _id:
			store.put(token)
		bag.held.erase(side()); bag.loose.erase(token)
		bag._track.erase(side()); bag._eat_time.erase(side()); bag._claim(side(), false)
		bag._refresh_holding()
	forget()


## Raw physics props/ponies stay raw. Catalogued world items must use their real acquisition.
func take(pick: Dictionary, pose: Transform3D) -> Node3D:
	var target: Node3D = pick.get("target") as Node3D
	if not is_instance_valid(target): return null
	if not pick.has("kind"): return target
	var owner: Node = hand.hands.inventory()
	if not is_instance_valid(owner) or not owner._take_pick(side(), pick, pose): return null
	var claimed: RigidBody3D = owner.held.get(side()) as RigidBody3D
	if not is_instance_valid(claimed): return null
	bag = owner; item = claimed; token = str(item.get_meta("token", ""))
	store = bag.inventory; _id = str(item.get_meta("item_id", ""))
	return item


## Physical mouth contact, completed bites and empty containers use the same production owner.
func tick(delta: float, can_eat: bool) -> bool:
	if not current(): return false
	bag._track_item(side(), item)
	bag._eat_tick(side(), item, delta, can_eat)
	if is_instance_valid(item): _id = str(item.get_meta("item_id", ""))
	return current()


## Deploy through the existing durable owner before relinquishing the magic hold.
## A refused surface or save keeps both owners on the exact held blanket.
func lay_out_blanket() -> bool:
	if not current() or str(item.get_meta("item_id", "")) != "goods:folded-blanket": return false
	if not bag._lay_out_blanket(side()): return false
	forget()
	return true


## A refused deposit stays held. No fall-through from a full/failed destination to dropping.
func release(deposit: bool) -> bool:
	if not current(): forget(); return true
	if deposit and is_instance_valid(bag.case) and bag.case.visible and bag.case.opened and bag._over_tray(item.global_position):
		if not bag._store_held(side()): return false
	elif deposit and bag.shelf_offer(side()) != null:
		if not bag._shelve_held(side()): return false
	elif item.has_meta("world_pick"):
		bag._release_to_world(side())
	else:
		bag._drop(side())
	if bag.held.get(side()) == item: return false
	forget()
	return true
