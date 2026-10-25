extends Node3D
const BLUE=Color("35b7ff")
var owner_ui:Node
var store:Node
var panel:Node3D
var pointer:Node3D
var active:=false
var target:Node3D
var selected:Node3D
var _overlays:Dictionary={}
var _material:ShaderMaterial
var _pressed:=false
var _armed:=false
var _old_mouse:int
var _lock_owned:=false
var _hand_overlays:Dictionary={}
var _hand_material:ShaderMaterial
var _aura:MeshInstance3D
var _refresh:=0.
var _excluded:Array[RID]=[]
func setup(ui:Node,context:Node):
	owner_ui=ui;store=context
	var body:Variant=owner_ui.player_body
	if is_instance_valid(body):
		var rig:Node=body.get_parent() if body.name=="Body" else body
		for node in rig.find_children("*","CollisionObject3D",true,false):_excluded.append(node.get_rid())
		if rig is CollisionObject3D:_excluded.append(rig.get_rid())
	panel=preload("res://world/ui/profile/pony_profile_view.gd").new();add_child(panel)
	panel.closed.connect(close);panel.back.connect(back)
	pointer=preload("res://world/ui/controller_pointer.gd").new();add_child(pointer);pointer.set_color(BLUE)
	_material=ShaderMaterial.new();_material.shader=load("res://addons/cel-shader/outline-tinted.gdshader");_material.set_shader_parameter("outline_color",BLUE);_material.set_shader_parameter("outline_width",.006)
	_hand_material=ShaderMaterial.new();_hand_material.shader=load("res://world/ui/profile/hand_glow.gdshader");_hand_material.set_shader_parameter("outline_color",BLUE);_hand_material.set_shader_parameter("outline_width",.003)
	_aura=MeshInstance3D.new();var sphere:=SphereMesh.new();sphere.radius=.055;sphere.height=.11;sphere.radial_segments=16;sphere.rings=8;_aura.mesh=sphere
	var mat:=StandardMaterial3D.new();mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;mat.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA;mat.albedo_color=Color(BLUE,.16);mat.emission_enabled=true;mat.emission=BLUE;_aura.material_override=mat;_aura.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;add_child(_aura);_aura.hide()
	if is_instance_valid(store) and is_instance_valid(store.impressions):store.impressions.changed.connect(_changed)
func toggle():
	if active:close();return
	if owner_ui.hand_busy("right"):return
	if owner_ui.customizer.opened:return # Preserve an unsaved outfit.
	if owner_ui._desktop:
		var focus:Control=get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit:return
		if owner_ui.has_method("_release_desktop_activity"):
			if not owner_ui._release_desktop_activity():return
		elif owner_ui.has_meta("desktop_activity_owner") and is_instance_valid(owner_ui.get_meta("desktop_activity_owner")):return
		# The wrist belongs to this inventory and can release its own lock. A
		# title, pause, case or another panel's lock must remain with that owner.
		if "_desktop_wrist" in owner_ui and owner_ui._desktop_wrist:owner_ui._toggle_desktop_wrist(false)
		if is_instance_valid(owner_ui.player_body) and "controls_locked" in owner_ui.player_body and owner_ui.player_body.controls_locked:return
	owner_ui._release_case();owner_ui.case.close();owner_ui._close_map();owner_ui.wrist.hide()
	active=true;_armed=false;_pressed=false;owner_ui._claim("right",true)
	var hand:Variant=owner_ui.hands.get("right")
	if is_instance_valid(hand):hand.set_meta("pony_inspection",true)
	if owner_ui._desktop:
		_old_mouse=Input.mouse_mode;Input.mouse_mode=Input.MOUSE_MODE_VISIBLE
		if is_instance_valid(owner_ui.player_body) and "controls_locked" in owner_ui.player_body:
			_lock_owned=not owner_ui.player_body.controls_locked;owner_ui.player_body.controls_locked=true
func close():
	if not active:return
	active=false;_clear_hand();_highlight(null);selected=null;panel.press(false);panel.hide();pointer.hide();_aura.hide();owner_ui._claim("right",false);_clear_claim()
	if owner_ui._desktop:
		var other_ui:bool=owner_ui._map_open() or owner_ui.customizer.opened or owner_ui.case.visible
		Input.mouse_mode=Input.MOUSE_MODE_VISIBLE if other_ui else _old_mouse
		if _lock_owned and is_instance_valid(owner_ui.player_body):owner_ui.player_body.controls_locked=other_ui
	_lock_owned=false
func back():
	panel.press(false);panel.hide();selected=null;_armed=false
func _changed(id:String):
	if is_instance_valid(selected) and selected.identity.id==id:_populate()
func _populate():
	if not is_instance_valid(selected) or not is_instance_valid(store) or not is_instance_valid(store.impressions):return
	panel.show_profile(selected.identity.id,selected.identity,_facts(selected.identity.id))

## Only gather player-facing relationship facts used by the summary.
func _facts(id: String) -> Dictionary:
	var identity: Resource = selected.identity
	var bonds: Node = store.player_bonds
	var now := Time.get_unix_time_from_system()
	var record: Dictionary = bonds.record_for(id)
	var impression: Dictionary = store.impressions.profile(id)
	var note: Dictionary = store.impressions.notes.get(id, {})
	var info := {"bond":record, "impression":impression, "thought":str(note.get("thought", "")),
		"romance_available":not identity.filly and not bonds._young_player()}
	info.space = float(record.cooldowns.get("boundary", 0.0)) > now
	var welcome := PackedStringArray()
	if bonds.welcomes(id, "hug"): welcome.append("hugs")
	if identity.filly: welcome.append("forehead kisses only")
	elif bonds.welcomes(id, "kiss"): welcome.append("kisses")
	info.welcome = " and ".join(welcome)
	var offer: Dictionary = bonds.pending(id)
	info.invitation = ""
	if not offer.is_empty():
		var requests := {"dating":"start dating", "move_in":"share a home", "engagement":"get engaged", "marriage":"get married", "kiss":"share a kiss", "hug":"have a hug", "break_up":"end the relationship"}
		var activity: String = requests.get(str(offer.kind), "spend time together")
		if offer.kind in ["outing", "date"]:
			activity = "go on a date" if offer.kind == "date" else "spend time together"
			var detail := str(offer.get("activity", "")).replace("_", " ")
			if not detail.is_empty(): activity += " (" + detail + ")"
		info.invitation = ("You asked to " if offer.by == "player" else "They would like to ") + activity + "."
	var plan: Dictionary = record.plan
	info.plan = ""
	if not plan.is_empty():
		info.plan = str(plan.get("activity", "time together")).replace("_", " ").capitalize()
		if bool(plan.get("date", false)): info.plan += " — a date"
	var memories: Array[String] = []
	for event: Dictionary in store.events_for(id, 64):
		if "player" in event.get("subjects", []): memories.append(str(event.text).left(160))
	info.memories = memories.slice(maxi(0, memories.size() - 3))
	return info

func _highlight(pony:Node3D):
	if target==pony:return
	for mesh in _overlays:
		if is_instance_valid(mesh) and mesh.material_overlay==_material:mesh.material_overlay=_overlays[mesh]
	_overlays.clear();target=pony
	if not is_instance_valid(pony):return
	for mesh in pony.find_children("*","MeshInstance3D",true,false):
		if mesh.mesh!=null:
			_overlays[mesh]=mesh.material_overlay;mesh.material_overlay=_material
func pick(origin:Vector3,direction:Vector3)->Dictionary:
	var query:=PhysicsRayQueryParameters3D.create(origin,origin+direction*25.,7)
	query.exclude=_excluded
	query.collide_with_areas=true
	var hit:=get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():return {"pony":null,"point":origin+direction*25.}
	var actor:Node=hit.collider
	while is_instance_valid(actor) and not actor.is_in_group("sim_ponies"):actor=actor.get_parent()
	return {"pony":actor if is_instance_valid(actor) and "identity" in actor and actor.identity!=null else null,"point":hit.position}
func ray_input(origin:Vector3,direction:Vector3,pressed:bool):
	if not active:return
	if not origin.is_finite() or not direction.is_finite() or direction.length_squared()<.5:
		tracking_lost();return
	if not pressed:_armed=true
	if panel.visible:
		var pixel:Vector2=panel.ray_to_pixel(origin,direction);panel.point_at(pixel)
		pointer.aim(origin,panel.pixel_to_world(pixel) if pixel.x>=0 else origin+direction*3.)
		panel.press(pressed and _armed and pixel.x>=0)
	else:
		var hit:=pick(origin,direction);_highlight(hit.pony);pointer.aim(origin,hit.point)
		if pressed and not _pressed and _armed and is_instance_valid(target):
			selected=target;_populate();_highlight(null)
			var head:Camera3D=owner_ui.camera
			panel.global_position=head.global_position-head.global_basis.z*1.15
			panel.look_at(head.global_position,Vector3.UP,true);panel.show();_armed=false
	_pressed=pressed
func tracking_lost():
	_clear_hand()
	_armed=false;_pressed=false;_highlight(null);pointer.hide();_aura.hide();panel.press(false)
func update_hand(sample:Dictionary):
	if not sample.get("active",false):tracking_lost();return
	var controller:Variant=owner_ui.controllers.get("right")
	var pose:Transform3D=controller.global_transform if is_instance_valid(controller) else sample.pose
	if not pose.is_finite():tracking_lost();return
	_hand_material.set_shader_parameter("hand_center",pose.origin)
	if _hand_overlays.is_empty():
		for parent in [owner_ui.avatar,owner_ui.hands.get("right")]:
			if not is_instance_valid(parent):continue
			var meshes:Array=parent.find_children("*","MeshInstance3D",true,false)
			if parent is MeshInstance3D:meshes.append(parent)
			for mesh in meshes:
				if mesh.is_visible_in_tree() and not _hand_overlays.has(mesh):
					_hand_overlays[mesh]=mesh.material_overlay;mesh.material_overlay=_hand_material
	_aura.global_position=pose.origin;_aura.show()
	ray_input(pose.origin,-pose.basis.z.normalized(),float(sample.trigger)>.6)
func _process(delta:float):
	if not active:return
	if owner_ui._map_open() or owner_ui.customizer.opened or owner_ui.case.visible:close();return
	if selected!=null and (not is_instance_valid(selected) or selected.is_queued_for_deletion()):back()
	_refresh+=delta
	if _refresh>=1.:
		_refresh=0.;_populate()
func _input(event:InputEvent):
	if not owner_ui._desktop:return
	if event is InputEventKey and event.pressed and not event.echo:
		if not active and (event.ctrl_pressed or event.alt_pressed or event.meta_pressed or get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit):return
		if event.physical_keycode==KEY_J:toggle();get_viewport().set_input_as_handled();return
		if active and event.physical_keycode==KEY_ESCAPE:close();get_viewport().set_input_as_handled();return
		if active and panel.visible and panel.scroll_key(event.physical_keycode):get_viewport().set_input_as_handled();return
	if not active:return
	if event is InputEventMouse:
		var pressed:bool=_pressed
		if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:pressed=event.pressed
		ray_input(owner_ui.camera.project_ray_origin(event.position),owner_ui.camera.project_ray_normal(event.position),pressed)
		if panel.visible and event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var pixel: Vector2 = panel.ray_to_pixel(owner_ui.camera.project_ray_origin(event.position), owner_ui.camera.project_ray_normal(event.position))
			panel.scroll_wheel(event, pixel)
		get_viewport().set_input_as_handled()
func _clear_claim():
	var hand:Variant=owner_ui.hands.get("right")
	if is_instance_valid(hand):hand.remove_meta("pony_inspection")
func _clear_hand():
	for mesh in _hand_overlays:
		if is_instance_valid(mesh) and mesh.material_overlay==_hand_material:mesh.material_overlay=_hand_overlays[mesh]
	_hand_overlays.clear()
func _exit_tree():
	if active and is_instance_valid(owner_ui):
		close()
		return
	_clear_hand()
	_highlight(null)
	if is_instance_valid(owner_ui):owner_ui._claim("right",false);_clear_claim()
