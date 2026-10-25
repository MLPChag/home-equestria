extends Node3D
signal dismissed
signal changed
const MODEL := preload("res://world/inventory/assets/briefcase.tscn")
const VIEW := preload("res://world/inventory/inventory_view.gd")
var model: Node3D
var lid: Node3D
var panel: Node3D
var viewport: SubViewport
var ui: Control
var sound: AudioStreamPlayer3D
var opened := false
var amount := 0.
var _closing := false
func setup(store: RefCounted):
	model=MODEL.instantiate();add_child(model)
	lid=model.get_node("Lid");panel=lid.get_node("Panel")
	viewport=SubViewport.new();viewport.size=Vector2i(1200,712);viewport.disable_3d=true
	viewport.transparent_bg=false;viewport.gui_disable_input=true
	viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED;add_child(viewport)
	ui=VIEW.new();viewport.add_child(ui);ui.dirty.connect(refresh);ui.bind(store)
	var screen:=Sprite3D.new();screen.texture=viewport.get_texture();screen.pixel_size=.0005
	screen.shaded=false;screen.double_sided=false;screen.texture_filter=BaseMaterial3D.TEXTURE_FILTER_LINEAR
	screen.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;panel.add_child(screen)
	sound=AudioStreamPlayer3D.new();
	sound.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	sound.stream=load("res://world/inventory/assets/clasp.wav")
	sound.volume_db=-13;sound.unit_size=1.;sound.max_distance=6;add_child(sound)
	hide();set_process(false)
func summon(at: Transform3D, open_immediately: bool = true):
	global_transform=at;amount=0;opened=false;_closing=false;lid.rotation.x=0
	show();refresh()
	if open_immediately:set_open(true)
func set_open(value: bool):
	if not visible:return
	opened=value;_closing=not value
	set_process(true);sound.play();changed.emit();refresh()
func close():
	if not _closing:set_open(false)
func refresh():
	if is_instance_valid(viewport):viewport.render_target_update_mode=SubViewport.UPDATE_ONCE if visible else SubViewport.UPDATE_DISABLED
func _process(delta: float):
	amount=move_toward(amount,1. if opened else 0.,delta*3.2)
	lid.rotation.x=deg_to_rad(-105.)*smoothstep(0.,1.,amount)
	if amount==0. and _closing:
		hide();_closing=false;viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED;dismissed.emit()
	if amount==0. or amount==1.:set_process(false)
func handle_world() -> Vector3:return model.get_node("Handle").global_position
func clasp_world() -> Vector3:return model.get_node("Clasp").global_position
func panel_point(world: Vector3) -> Vector3:
	var local:=panel.to_local(world)
	return Vector3(local.x/.0005+600.,356.-local.y/.0005,local.z)
func world_point(pixel: Vector2, depth: float = .0) -> Vector3:
	return panel.to_global(Vector3((pixel.x-600)*.0005,(356-pixel.y)*.0005,depth))
func ray_point(origin: Vector3, direction: Vector3) -> Vector3:
	var normal:=panel.global_basis.z.normalized()
	var denominator:=normal.dot(direction)
	if denominator>=-.0001:return Vector3.INF
	var t:=normal.dot(panel.global_position-origin)/denominator
	if t<0 or t>3.:return Vector3.INF
	var point:=panel_point(origin+direction*t)
	return point if Rect2(Vector2.ZERO,VIEW.SIZE).has_point(Vector2(point.x,point.y)) else Vector3.INF
func _exit_tree():
	if sound!=null:sound.stop()
