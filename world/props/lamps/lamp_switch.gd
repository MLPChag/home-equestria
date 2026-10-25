extends Node
## Point at the actual visible lamp and press E, or touch it and pull the VR trigger.
## Hints and activation use the same occluded ray / physical fingertip selector.
const SFX := preload("res://world/audio/interaction_sounds.gd")
const DESK_REACH := 2.2
const TOUCH_REACH := .055
var inventory:Node
var _trigger:Dictionary={"left":true,"right":true}
var _touch_shape:=SphereShape3D.new()
func _ready()->void:
	add_to_group("interaction_hint_sources")
	process_physics_priority=-45
	_touch_shape.radius=TOUCH_REACH
func _unhandled_input(event:InputEvent)->void:
	if not is_instance_valid(inventory) or not inventory._desktop:return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode==KEY_E and Input.mouse_mode==Input.MOUSE_MODE_CAPTURED:
		var target:=_aimed()
		if not target.is_empty():
			target.target.toggle();SFX.play_at(target.target, "prop_lamp");get_viewport().set_input_as_handled()
func _physics_process(_delta:float)->void:
	if not is_instance_valid(inventory) or inventory._desktop:return
	for side:String in ["left","right"]:
		var sample:Dictionary=inventory.hand_sample(side)
		var pulled:bool=bool(sample.get("active",false)) and float(sample.get("trigger",0.0))>(.45 if _trigger[side] else .75)
		var target:=_hand_target(side,sample)
		var hand:Node=inventory.hands.get(side)
		if is_instance_valid(hand):
			if not target.is_empty():hand.set_meta("lamp_reach",true)
			elif hand.has_meta("lamp_reach"):hand.remove_meta("lamp_reach")
		if pulled and not _trigger[side] and not target.is_empty():
			target.target.toggle();SFX.play_at(target.target, "prop_lamp");inventory._haptic(side)
		_trigger[side]=pulled
func _aimed()->Dictionary:
	var camera:Camera3D=inventory.camera
	if not is_instance_valid(camera):return {}
	var skip:Array[RID]=[]
	if inventory.player_body is CollisionObject3D:skip.append(inventory.player_body.get_rid())
	for item:Variant in inventory.held.values():
		if is_instance_valid(item) and item is CollisionObject3D:skip.append(item.get_rid())
	var from:=camera.global_position
	var ray:=PhysicsRayQueryParameters3D.create(from,from-camera.global_basis.z*DESK_REACH,1|(1<<17),skip)
	var hit:=camera.get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty():return {}
	return _lamp_hit(hit.collider,hit.position)
func _touched(tip:Vector3)->Dictionary:
	if not tip.is_finite() or not is_instance_valid(inventory.camera):return {}
	var query:=PhysicsShapeQueryParameters3D.new();query.shape=_touch_shape
	query.transform.origin=tip;query.collision_mask=1
	for hit:Dictionary in inventory.camera.get_world_3d().direct_space_state.intersect_shape(query,16):
		var result:=_lamp_hit(hit.collider,tip)
		if not result.is_empty():
			var lamp:Node3D=result.target
			var centre:Vector3=lamp.to_global(lamp.get_meta("lamp_touch_center",Vector3.ZERO))
			var ray:=PhysicsRayQueryParameters3D.create(tip,centre,1|(1<<17))
			var blocker:Dictionary=inventory.camera.get_world_3d().direct_space_state.intersect_ray(ray)
			if blocker.is_empty() or blocker.collider==hit.collider:return result
	return {}
func _hand_target(side:String,sample:Dictionary)->Dictionary:
	if not bool(sample.get("active",false)):return {}
	var hand:Node=inventory.hands.get(side)
	if is_instance_valid(hand) and (hand.get_meta("inventory_busy",false) or hand.get_meta("pony_inspection",false) or hand.get("held_object")!=null):return {}
	if is_instance_valid(inventory.held.get(side)):return {}
	return _touched(Vector3(sample.get("tip",Vector3.INF)))
func _exit_tree()->void:
	if not is_instance_valid(inventory):return
	for hand:Node in inventory.hands.values():
		if is_instance_valid(hand) and hand.has_meta("lamp_reach"):hand.remove_meta("lamp_reach")
func _lamp_hit(body:Node,point:Vector3)->Dictionary:
	if not is_instance_valid(body) or not body.has_meta("physical_lamp"):return {}
	var lamp:Node3D=body.get_meta("physical_lamp")
	if not is_instance_valid(lamp) or not lamp.is_in_group("physical_lamps"):return {}
	return {"target":lamp,"collider":body,"point":point}
func interaction_hint()->Dictionary:
	if not is_instance_valid(inventory):return {}
	var target:Dictionary={}
	var control:="[E] "
	if inventory._desktop:
		if Input.mouse_mode!=Input.MOUSE_MODE_CAPTURED:return {}
		target=_aimed()
	else:
		control="Trigger · "
		for side:String in ["right","left"]:
			var sample:Dictionary=inventory.hand_sample(side)
			if not bool(sample.get("active",false)):continue
			target=_hand_target(side,sample)
			if not target.is_empty():break
	if target.is_empty():return {}
	target.text=control+("Switch off" if target.target.lit else "Switch on")+" lamp"
	return target
