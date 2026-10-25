extends RefCounted
## Desktop hands: quick slots, stash and swap, placing, the look target with its forgiving cone, and mouse picks.
## Split out of briefcase_inventory.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning briefcase_inventory node; shared state stays there.

const SFX := preload("res://world/audio/interaction_sounds.gd")
const ITEM_FOLEY := preload("res://world/audio/props_catalogue.gd")
const FURNISHING := preload("res://world/housing/home_furnishing.gd")
const COOKING := preload("res://world/cooking/cooking_input.gd")
const BANANAS := preload("res://world/food/banana_boxes.gd")
## The view missed: the takeable thing nearest the aim within FORGIVE_DEGREES and FORGIVE_REACH,
## in plain sight (dev 2026-10-01: picking up "shouldnt be reliant on literally facing the thing
## and looking at it"). Shelf books still need the exact aim: they stand packed together.
const FORGIVE_DEGREES := 35.0
const FORGIVE_REACH := 2.5

const BOOK_HOLD := preload("res://world/books/book_hold.gd")

var host: Node3D
var _reading_helper_owned := false


func _init(owner_node: Node3D) -> void:
	host = owner_node


## Keys 1-5 select the quick slots; the rest of the briefcase is taken from the open case.
## Selecting an empty slot frees the hand.
func _quick_slot(slot: int) -> void:
	host._desktop_eating = false
	host._select_slot("desktop", slot, host.camera.global_transform)


## Desktop E on a thing in view: it goes straight into the briefcase (dev 2026-09-30: "picking up
## a thing with e should put it in my inventory"). What was in hand stays in hand: a hotbar item
## is put back in hand afterwards. With no room in the bag, the thing stays in hand.
func stash_take() -> bool:
	var look:=desktop_look_target()
	if look.is_empty() or not is_instance_valid(look.get("target")): return false
	if host.held.has("desktop") and look.target==host.held.desktop: return false
	if host.has_meta("desktop_activity_owner") and is_instance_valid(host.get_meta("desktop_activity_owner")): return false
	if host.holding_case=="desktop": return false
	var reselect:=-1
	if host.held.has("desktop"):
		if host._book_open(host.held.desktop): return false
		if host.equipped_only("desktop"): reselect=int(host._selected_slots.desktop)
		if not host._store_held("desktop"): return false
	if host.hand_busy("desktop") or not _desktop_look_pick():
		if reselect>=0:host._select_slot("desktop",reselect,host.camera.global_transform)
		return false
	# Wardrobe purchases unlock directly and leave nothing in the hand to stow.
	if host.held.has("desktop") and not host._store_held("desktop"):
		if host.hotbar!=null:host.hotbar.set_message("No room in the briefcase: it stays in your hand.")
		return true
	if reselect>=0:host._select_slot("desktop",reselect,host.camera.global_transform)
	return true


## Desktop: holding one thing and looking at another to take, E puts the held one in the bag
## first (dev 2026-09-30: the pickup must be "WAY more functional"; before this, E did nothing
## until the hand was emptied with a number key).
func can_swap_take(look: Dictionary) -> bool:
	if not host._desktop or not host.held.has("desktop") or host.holding_case=="desktop": return false
	if look.is_empty() or not is_instance_valid(look.get("target")) or look.target==host.held.desktop: return false
	if host.has_meta("desktop_activity_owner") and is_instance_valid(host.get_meta("desktop_activity_owner")): return false
	return not host._book_open(host.held.desktop)


func swap_take() -> bool:
	var look:=desktop_look_target()
	if not can_swap_take(look) or not host._store_held("desktop"): return false
	return _desktop_look_pick()


## E on a dropped item in view picks it up.
func _desktop_look_pick(look: Dictionary = {})->bool:
	if host.hand_busy("desktop"):return false
	if look.is_empty():look=desktop_look_target()
	if not is_instance_valid(look.get("target")):return false
	if str(look.get("kind","")) == "banana_box":
		return BANANAS.take(host,"desktop",look.target,host.camera.global_transform,look.point)
	# Commit the actual offered item. A fresh nearest query could take another loose
	# item beside it, disagreeing with the blue outline.
	return host._take_pick("desktop",look,host.camera.global_transform)


## Shift+Q places on the visible support under the aim. Item accounting commits
## before its pose changes; a blocked/full/failed write keeps the item in hand.
func desktop_place_offer() -> Dictionary:
	if not host.held.has("desktop") or not is_instance_valid(host.camera):return {}
	var item:RigidBody3D=host.held.desktop
	if FURNISHING.eligible(item):
		var furnishing_offer: Dictionary = FURNISHING.offer(host, "desktop")
		if not furnishing_offer.is_empty(): return furnishing_offer
	var excluded:Array[RID]=[item.get_rid()]
	if host.player_body is CollisionObject3D:excluded.append(host.player_body.get_rid())
	var ray:=PhysicsRayQueryParameters3D.create(host.camera.global_position,host.camera.global_position-host.camera.global_basis.z*2.5,1,excluded)
	var hit:Dictionary=host.get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty() or Vector3(hit.normal).y < .75:return {}
	var collision:CollisionShape3D
	for child:Node in item.get_children():
		if child is CollisionShape3D and child.shape != null and not child.disabled:
			collision=child;break
	if collision==null:return {}
	var basis:Basis=Basis(Vector3.UP,host.camera.global_basis.get_euler().y)
	var bounds:AABB=Transform3D(basis,Vector3.ZERO)*collision.transform*collision.shape.get_debug_mesh().get_aabb()
	var pose:=Transform3D(basis,Vector3(hit.position)+Vector3.UP*(-bounds.position.y+.008))
	var query:=PhysicsShapeQueryParameters3D.new()
	query.shape=collision.shape;query.transform=pose*collision.transform
	query.collision_mask=1;query.exclude=excluded
	if not host.get_world_3d().direct_space_state.intersect_shape(query,1).is_empty():return {}
	return {"target":hit.collider,"point":hit.position,"normal":hit.normal,"pose":pose}


func desktop_place() -> bool:
	if not host.held.has("desktop"):return false
	if not COOKING.offer(host,"desktop").is_empty():
		COOKING.activate(host,"desktop");return true
	if host._shelve_held("desktop"):return true
	if FURNISHING.place(host, "desktop"): return true
	var offer:=desktop_place_offer()
	if offer.is_empty():return false
	var item:RigidBody3D=host.held.desktop
	var token:=str(item.get_meta("token",""))
	if not host.inventory.set_dropped(token,offer.pose):host._error();return true
	if host._book_open(item):item.get_node("BookItem").close_book()
	item.global_transform=offer.pose
	host._unglow(item);item.freeze=false;item.linear_velocity=Vector3.ZERO;item.angular_velocity=Vector3.ZERO
	host._settle(item)
	SFX.play_event(item,"prop_place",{"material":ITEM_FOLEY.material_for_item(str(item.get_meta("item_id","")))})
	for key:String in ["hold_offset","hold_blend","hold_from"]:
		if item.has_meta(key):item.remove_meta(key)
	host.held.erase("desktop");host._track.erase("desktop");host._eat_time.erase("desktop");host._claim("desktop",false);host._refresh_holding()
	return true


func _present_desktop_item(item:Node3D) -> void:
	if not is_instance_valid(host.desktop_presentation) or not host.desktop_presentation.has_method("set_hold_target"):return
	# With the case open the item rides the mouse pointer between case and eye; a hand gripping
	# it hid the item and the slots it moved over (playtest 2026-10-20). Arms rest at the sides
	# until the lid shuts, then take the item again.
	if host.case!=null and host.case.visible:
		_clear_desktop_item_pose();return
	var kind:="read" if host._book_open(item) else "eat" if host._desktop_eating else "hold"
	var grip:Transform3D=item.global_transform
	if host._book_open(item):
		# Both hands behind the lower outer corners, palms on the back boards, never over the
		# printed pages (dev 2026-10-15). The left hand is an explicit target, not the helper.
		host.desktop_presentation.set_hold_target("right",BOOK_HOLD.reader_hand(grip,"right"),kind)
		host.desktop_presentation.set_hold_target("left",BOOK_HOLD.reader_hand(grip,"left"),kind)
		host._desktop_pose_owned=true;_reading_helper_owned=true
		return
	if _reading_helper_owned:host.desktop_presentation.clear_hold_target("left");_reading_helper_owned=false
	grip=grip*host.hold_local(str(item.get_meta("item_id",""))).affine_inverse()
	host.desktop_presentation.set_hold_target("right",grip,kind)
	host._desktop_pose_owned=true


func _clear_desktop_item_pose() -> void:
	if host._desktop_pose_owned and is_instance_valid(host.desktop_presentation):host.desktop_presentation.clear_hold_target("right")
	if _reading_helper_owned and is_instance_valid(host.desktop_presentation):host.desktop_presentation.clear_hold_target("left")
	host._desktop_pose_owned=false;_reading_helper_owned=false


func item_presentation() -> Dictionary:
	var item:Node3D=host.held.get("desktop")
	if not is_instance_valid(item):return {}
	var reading:bool=host._book_open(item)
	return {"action":"read" if reading else "eat" if host._desktop_eating else "hold","target":item,"point":item.global_position,"held":item,"helper":reading,"progress":float(item.get_meta("food_raise",0.0))}


## What E would pick up: {"target", "kind": "book"|"food"|"loose"} or {}. Shared by the pickup
## and the blue highlight (world/ui/interaction_hints.gd), so what glows is what E takes.
func desktop_look_target()->Dictionary:
	if host.camera==null:return {}
	var origin: Vector3 = host.camera.global_position
	# What is in hand sits in front of the camera: look past it (it hid everything from E).
	var in_hand:Array[RID]=[]
	for item:Variant in host.held.values():
		if is_instance_valid(item) and item is CollisionObject3D:in_hand.append((item as CollisionObject3D).get_rid())
	var query:=PhysicsRayQueryParameters3D.create(origin,origin-host.camera.global_basis.z*2.5,1|8|(1<<17),in_hand)
	var hit:=host.get_world_3d().direct_space_state.intersect_ray(query)
	# Orchard fruit is owned by its activity provider, never a briefcase loan.
	# It still occludes generic pickup/stash selection so E cannot take a hidden item.
	if not hit.is_empty() and hit.collider.has_meta("harvest_apple"):return {}
	# Shelf books stand inside their bookcase's collision box, so the ray above meets the box
	# first (dev 2026-09-26: "grabbing a book isnt working on desktop"). Look for books on the
	# item layer alone; only that bookcase's own box may stand between you and the book.
	var book_hit:=host.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin,origin-host.camera.global_basis.z*2.5,1<<17,in_hand))
	if not book_hit.is_empty() and book_hit.collider.has_meta("shelf_book"):
		var skip:Array[RID]=[]
		var bookcase:Node=book_hit.collider.get_parent().get_parent() if book_hit.collider.get_parent()!=null else null
		if bookcase!=null:
			for body:CollisionObject3D in bookcase.find_children("*","CollisionObject3D",false,false):skip.append(body.get_rid())
		var wall:=host.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin,book_hit.position,1,skip))
		if wall.is_empty():return {"target":book_hit.collider,"kind":"book"}
	if not hit.is_empty() and BANANAS.allowed(host):
		var banana_box := BANANAS.root_for(hit.collider)
		if banana_box != null:
			# Dispense just outside the visible crate surface, on the already checked eye ray.
			return {"target":banana_box,"kind":"banana_box","point":hit.position + (origin - hit.position).normalized() * .08}
	if not hit.is_empty() and hit.collider.is_in_group("world_food"):return {"target":hit.collider,"kind":"food"}
	if not hit.is_empty() and hit.collider.is_in_group("shop_items"):return {"target":hit.collider,"kind":"shop"}
	if hit.is_empty() or hit.collider not in host.loose.values() or hit.collider in host.held.values():
		return _forgiving_look(origin,-host.camera.global_basis.z,in_hand)
	return {"target":hit.collider,"kind":"loose"}


func _forgiving_look(origin:Vector3,forward:Vector3,in_hand:Array[RID])->Dictionary:
	var candidates:Array=[]
	for node:Node in host.get_tree().get_nodes_in_group("world_food"):candidates.append([node,"food"])
	for node:Node in host.get_tree().get_nodes_in_group("shop_items"):candidates.append([node,"shop"])
	for node:Variant in host.loose.values():
		if is_instance_valid(node) and node not in host.held.values():candidates.append([node,"loose"])
	var best:={};var best_score:=INF
	var space:=host.get_world_3d().direct_space_state
	for row:Array in candidates:
		var node:=row[0] as Node3D
		if node==null or not node.is_inside_tree() or not node.is_visible_in_tree():continue
		var to:=node.global_position-origin
		var distance:=to.length()
		if distance>FORGIVE_REACH or distance<.05:continue
		var angle:=rad_to_deg(forward.angle_to(to))
		if angle>FORGIVE_DEGREES:continue
		var score:=angle+distance*4.
		if score>=best_score:continue
		var skip:=in_hand.duplicate()
		if node is CollisionObject3D:skip.append((node as CollisionObject3D).get_rid())
		var sight:=space.intersect_ray(PhysicsRayQueryParameters3D.create(origin,node.global_position,1,skip))
		if not sight.is_empty():continue
		best={"target":node,"kind":row[1]};best_score=score
	return best


func _mouse_panel(pixel: Vector2) -> Vector3:
	if not host.case.visible or host.case.amount<.95:return Vector3.INF
	return host.case.ray_point(host.camera.project_ray_origin(pixel),host.camera.project_ray_normal(pixel))


func _set_hover(index: int):
	if host.case.ui.hovered!=index:host.case.ui.hovered=index;host.case.ui.refresh()


func _desktop_pick(pixel: Vector2) -> bool:
	var origin: Vector3 = host.camera.project_ray_origin(pixel)
	var query:=PhysicsRayQueryParameters3D.create(origin,origin+host.camera.project_ray_normal(pixel)*3.,1|(1<<17))
	var hit:=host.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty() and hit.collider in host.loose.values():
		var panel:=_mouse_panel(pixel)
		if panel.is_finite() and origin.distance_to(hit.position)>origin.distance_to(host.case.world_point(Vector2(panel.x,panel.y)))+.02:return false
		return host._take_nearby("desktop",Transform3D(host.camera.global_basis,hit.collider.global_position))
	return false
