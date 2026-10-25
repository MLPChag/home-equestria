extends Node3D
## Saved games panel (F6, the pause menu's Save/Load, the VR map). Every save is shown with its
## screenshot, what kind of save it is (manual, autosave, quit save), the in-game day and time,
## where the player was and as whom, when it was saved and how long the world has been played
## (dev 2026-10-15: "its really unclear what save games are what"). This world's saves come first,
## newest first, then its archive, then the other worlds' saves grouped by world.
## Data: world/saves/save_catalogue.gd (headers only); loading validates (world/game_saves.gd).
const CURRENCY := preload("res://world/ui/currency.gd")
const DESKTOP_OWNER := preload("res://player/desktop_action_owner.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const VIEW := preload("res://world/player_view.gd")
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const PREVIEW := preload("res://world/saves/save_preview.gd")
const DESKTOP_SIZE := Vector2(980, 700)
const ROW_HEIGHT := 112.0
const HEADER_HEIGHT := 36.0
const THUMB := Vector2(176, 99)
const DIM := Color(1, 1, 1, 0.68)
const ACCENT := Color("edd6a2")
var saves:Node
var ui:Node
var panel:Node3D
var pointer:Node3D
var content:Control
var canvas:CanvasLayer
var opened:=false
var _armed:=false
var _mouse_mode:int
var _old_lock:=false
var _input_states:Dictionary={}
var _old_physics:=true
var _buttons:Dictionary={}
var _pages:Array=[]
var _page:=0
var _textures:Dictionary={}   # preview path -> [modified time, texture]

func setup(store:Node,inventory_ui:Node)->void:
	saves=store;ui=inventory_ui
	if ui._desktop:
		canvas=CanvasLayer.new();canvas.layer=150;add_child(canvas)
		content=PanelContainer.new();content.custom_minimum_size=DESKTOP_SIZE;canvas.add_child(content);canvas.hide()
	else:
		panel=preload("res://world/ui/spatial_menu_panel.gd").new();add_child(panel);panel.hide();content=panel.content
		pointer=preload("res://world/ui/controller_pointer.gd").new();add_child(pointer)
	content.theme = preload("res://world/ui/readable_text_theme.gd").make()
	if content is PanelContainer:content.add_theme_stylebox_override("panel",_card())
	saves.changed.connect(func():
		if opened:_rebuild.call_deferred())
	_rebuild()

## This world's id: its saves folder is <root>/<world>/saves.
func _world_id()->String:
	return str(saves.directory).get_base_dir().get_file() if str(saves.directory)!="" else ""

func _list_height()->float:
	return 430.0 if ui._desktop else 520.0

## Pages of display items: {"header": text} or {"entry": entry, "here": bool}.
func _build_pages()->Array[Dictionary]:
	var here:=CATALOGUE.world_entries(str(saves.directory))
	var items:Array=[]
	var current:Array=here.filter(func(e:Dictionary)->bool:return not bool(e.archived))
	var archived:Array=here.filter(func(e:Dictionary)->bool:return bool(e.archived))
	if current.is_empty():items.append({"header":"No saves in this world yet. Save into a slot above; autosaves happen every minute."})
	for entry in current:items.append({"entry":entry,"here":true})
	if not archived.is_empty():
		items.append({"header":"Archived"})
		for entry in archived:items.append({"entry":entry,"here":true})
	var world:=_world_id()
	# Other worlds beside this one (the same root: user://worlds in play, a fixture's own root in tests).
	var others:Array[Dictionary]=[]
	if world!="":
		for entry:Dictionary in CATALOGUE.catalogue(str(saves.directory).get_base_dir().get_base_dir()):
			if str(entry.world_id)!=world:others.append(entry)
	for group:Dictionary in CATALOGUE.groups(others):
		var details:Array[String]=[str(group.form)]
		if str(group.world_started)!="":details.append("started "+str(group.world_started))
		items.append({"header":"Other world: %s · %s"%[group.world_name," · ".join(details)]})
		for entry in group.entries:items.append({"entry":entry,"here":false})
	_pages.clear()
	var page:Array=[];var used:=0.0
	for item:Dictionary in items:
		var height:=HEADER_HEIGHT if item.has("header") else ROW_HEIGHT
		# Never end a page on a header.
		var need:=height+(ROW_HEIGHT if item.has("header") else 0.0)
		if used+need>_list_height() and not page.is_empty():_pages.append(page);page=[];used=0.0
		page.append(item);used+=height
	if not page.is_empty():_pages.append(page)
	_page=clampi(_page,0,maxi(0,_pages.size()-1))
	return here

func _rebuild()->void:
	for child in content.get_children():child.free()
	_buttons.clear()
	# Reuse this rebuild's discovery for the slot captions; refresh again on the next rebuild.
	var here:=_build_pages()
	if not ui._desktop:
		var backdrop:=Panel.new();backdrop.size=content.size;backdrop.add_theme_stylebox_override("panel",_card());content.add_child(backdrop)
	var box:=VBoxContainer.new();box.add_theme_constant_override("separation",10);content.add_child(box)
	if not ui._desktop:box.position=Vector2(25,22);box.size=Vector2(850,796)
	var top:=HBoxContainer.new();box.add_child(top)
	var title:=Label.new();title.text="Saved games";title.add_theme_font_size_override("font_size",30);title.size_flags_horizontal=Control.SIZE_EXPAND_FILL;top.add_child(title)
	button(top,"Close",close,"close").custom_minimum_size.x=140
	var world:=_world_id()
	var heading:=Label.new();heading.add_theme_color_override("font_color",ACCENT)
	heading.text="This world: "+CATALOGUE.world_name(world)+(" · started "+CATALOGUE.world_started(world) if CATALOGUE.world_started(world)!="" else "")
	box.add_child(heading)
	var slots:=HBoxContainer.new();slots.add_theme_constant_override("separation",8);box.add_child(slots)
	var hint:=Label.new();hint.text="Save now into:";slots.add_child(hint)
	var by_path:Dictionary={}
	for entry:Dictionary in here:by_path[entry.path]=entry
	for i in 3:
		var path:String=saves.slot_path(i)
		var used:Dictionary=by_path.get(path,{})
		var text:="Slot %d · %s"%[i+1,"empty" if used.is_empty() else CATALOGUE.when_text(float(used.saved_at))]
		var b:=button(slots,text,func():saves.save_slot(i),"save_"+str(i))
		b.size_flags_horizontal=Control.SIZE_EXPAND_FILL;b.disabled=saves.busy or path==""
		b.tooltip_text="Overwrites this slot." if not used.is_empty() else "Saves into this empty slot."
	var list:=VBoxContainer.new();list.add_theme_constant_override("separation",4);list.custom_minimum_size.y=_list_height();box.add_child(list)
	var items:Array=_pages[_page] if _page<_pages.size() else []
	for item:Dictionary in items:
		if item.has("header"):
			var header:=Label.new();header.text=str(item.header);header.add_theme_color_override("font_color",ACCENT)
			header.custom_minimum_size.y=HEADER_HEIGHT-4;header.vertical_alignment=VERTICAL_ALIGNMENT_BOTTOM
			header.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS;list.add_child(header)
		else:_row(list,item.entry,bool(item.here))
	var pager:=HBoxContainer.new();pager.add_theme_constant_override("separation",8);box.add_child(pager)
	button(pager,"Newer",_turn.bind(-1),"newer").disabled=_page<=0
	var where:=Label.new();where.size_flags_horizontal=Control.SIZE_EXPAND_FILL;where.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	where.text="Page %d of %d"%[_page+1,maxi(1,_pages.size())];pager.add_child(where)
	button(pager,"Older",_turn.bind(1),"older").disabled=_page>=_pages.size()-1
	var status:=Label.new();status.text=CURRENCY.text(saves.message);box.add_child(status);CURRENCY.apply(status)
	if panel!=null:panel.refresh()

## An opaque card, so the world and HUD do not show through the text.
func _card()->StyleBoxFlat:
	var style:=StyleBoxFlat.new();style.bg_color=Color(0.06,0.07,0.11,0.96);style.border_color=Color(ACCENT,0.55)
	style.set_border_width_all(2);style.set_corner_radius_all(14);style.set_content_margin_all(18)
	return style

func _turn(step:int)->void:
	_page=clampi(_page+step,0,maxi(0,_pages.size()-1));_rebuild()

func button(parent:Node,text:String,callback:Callable,key:String)->Button:
	var b:=Button.new();b.text=text;b.custom_minimum_size.y=42;b.pressed.connect(callback);parent.add_child(b);_buttons[key]=b
	return b

func _texture(path:String)->Texture2D:
	if path=="":return null
	var stamp:=FileAccess.get_modified_time(path)
	var cached:Array=_textures.get(path,[])
	if not cached.is_empty() and int(cached[0])==stamp:return cached[1]
	var texture:=PREVIEW.texture(path)
	_textures[path]=[stamp,texture]
	return texture

## One save: screenshot | kind and game time / place and form / saved when, play time | actions.
func _row(parent:Node,entry:Dictionary,here:bool)->void:
	var row:=HBoxContainer.new();row.add_theme_constant_override("separation",12);row.custom_minimum_size.y=ROW_HEIGHT-4;parent.add_child(row)
	var frame:=PanelContainer.new();frame.custom_minimum_size=THUMB;row.add_child(frame)
	var texture:=_texture(str(entry.get("preview","")))
	if texture!=null:
		var picture:=TextureRect.new();picture.texture=texture;picture.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_COVERED;picture.custom_minimum_size=THUMB;picture.clip_contents=true
		frame.add_child(picture)
	else:
		var none:=Label.new();none.text="No picture";none.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER;none.vertical_alignment=VERTICAL_ALIGNMENT_CENTER
		none.add_theme_color_override("font_color",DIM);frame.add_child(none)
	var text:=VBoxContainer.new();text.size_flags_horizontal=Control.SIZE_EXPAND_FILL;text.add_theme_constant_override("separation",2);row.add_child(text)
	var first:=Label.new();first.text=CATALOGUE.kind_text(entry)+" · "+CATALOGUE.game_time_text(entry)
	first.add_theme_font_size_override("font_size",23);text.add_child(first)
	var second:=Label.new()
	second.text=" · ".join(([str(entry.place)] if str(entry.place)!="" else [])+[str(entry.form)]);text.add_child(second)
	var third:=Label.new();third.add_theme_color_override("font_color",DIM)
	third.text="Saved "+CATALOGUE.when_text(float(entry.saved_at))+" · "+CATALOGUE.play_text(float(entry.play_seconds));text.add_child(third)
	for label:Label in [first,second,third]:label.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS;label.clip_text=true
	var actions:=VBoxContainer.new();actions.add_theme_constant_override("separation",2);row.add_child(actions)
	var path:=str(entry.path)
	var key:=path.get_file().get_basename()
	var load_button:=button(actions,"Load",_load.bind(entry,here),"load_"+key)
	load_button.custom_minimum_size=Vector2(120,34);load_button.disabled=saves.busy or bool(entry.newer)
	if here:
		if not bool(entry.archived):
			var archive:=button(actions,"Archive",_archive_confirmed.bind(path),"archive_"+key);archive.custom_minimum_size=Vector2(120,34);archive.disabled=saves.busy
		var delete:=button(actions,"Delete",_delete_confirmed.bind(path),"delete_"+key);delete.custom_minimum_size=Vector2(120,34)
		delete.disabled=saves.busy or not (FileAccess.file_exists(path) or FileAccess.file_exists(path+".previous"))

func _load(entry:Dictionary,here:bool)->void:
	if here or not saves.has_method("load_world_save"):saves.load_save(str(entry.path))
	else:saves.load_world_save(entry)
func _archive_confirmed(path:String)->void:
	if saves.archive(path):_menu_sound("prop_ui_confirm")
func _delete_confirmed(path:String)->void:
	if saves.delete(path):_menu_sound("prop_ui_confirm")
func toggle()->void:
	if opened:close();return
	if ui.customizer.opened:return
	if ui.hand_busy("right") or ui.hand_busy("left"):return
	# Before this panel draws: saves made from it show the world under it.
	if saves.has_method("remember_view"):saves.remember_view(self)
	if ui._desktop:DESKTOP_OWNER.cancel_current(ui)
	if is_instance_valid(ui.inspector):ui.inspector.close()
	ui._close_map();ui._release_case();ui.case.close();ui.wrist.hide()
	opened=true;_armed=false;_page=0;_old_lock=ui.player_body.controls_locked;ui.player_body.controls_locked=true
	_old_physics=ui.is_physics_processing()
	for node in [ui,ui.inspector,ui.map_menu]:
		if not is_instance_valid(node):continue
		_input_states[node]=node.is_processing_input();node.set_process_input(false)
		if node==ui.map_menu:node.set_meta("save_menu_open",true)
	ui._claim("right",true);ui._claim("left",true);ui.set_physics_process(false)
	if ui._desktop:
		_mouse_mode=Input.mouse_mode;Input.mouse_mode=Input.MOUSE_MODE_VISIBLE
		var screen:=Vector2(get_viewport().get_visible_rect().size)
		content.custom_minimum_size=DESKTOP_SIZE.min(screen-Vector2(24,24))
		content.size=content.custom_minimum_size
		content.position=(screen-content.size)*.5;canvas.show()
	else:
		panel.global_position=ui.camera.global_position-ui.camera.global_basis.z*1.4
		panel.look_at(ui.camera.global_position,Vector3.UP,true);panel.show();panel.refresh()
	_rebuild()
	_menu_sound("prop_ui_confirm")
func close()->void:
	if not opened:return
	_menu_sound("prop_ui_back")
	opened=false
	ui._claim("right",false);ui._claim("left",false);ui.set_physics_process(_old_physics);ui.player_body.controls_locked=_old_lock
	for node in _input_states:
		if is_instance_valid(node):node.set_process_input(_input_states[node]);node.remove_meta("save_menu_open")
	_input_states.clear()
	if ui._desktop:canvas.hide();Input.mouse_mode=_mouse_mode
	else:panel.press(false);panel.hide();pointer.hide()
	if saves.has_method("release_view"):saves.release_view(self)
	_textures.clear()
func _menu_sound(event:String)->void:
	var camera:Camera3D=VIEW.camera(self)
	if camera!=null:SOUNDS.play_at(camera,event,camera.global_position)
func _process(_delta:float)->void:
	if not opened or ui._desktop:return
	var sample:Dictionary=ui.hand_sample("right")
	if not sample.get("active",false):_armed=false;panel.press(false);pointer.hide();return
	var pose:Transform3D=sample.aim
	if not pose.is_finite():_armed=false;panel.press(false);pointer.hide();return
	var pressed:bool=sample.trigger>.6
	if not pressed:_armed=true
	var pixel:Vector2=panel.ray_to_pixel(pose.origin,-pose.basis.z)
	panel.point_at(pixel);panel.press(pressed and _armed and pixel.x>=0)
	pointer.aim(pose.origin,panel.pixel_to_world(pixel) if pixel.x>=0 else pose.origin-pose.basis.z*2.)
func _input(event:InputEvent)->void:
	if event is InputEventKey and event.pressed and not event.echo:
		if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit:return
		match event.physical_keycode:
			KEY_F6:toggle();get_viewport().set_input_as_handled()
			KEY_F5:saves.save_slot(0);get_viewport().set_input_as_handled()
			KEY_F8:get_viewport().set_input_as_handled();saves.load_save(saves.slot_path(0))   # handled first: the reload frees this viewport
			KEY_ESCAPE:
				if opened:close();get_viewport().set_input_as_handled()
	elif opened and ui._desktop and event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
		_turn(1 if event.button_index==MOUSE_BUTTON_WHEEL_DOWN else -1);get_viewport().set_input_as_handled()
