extends CanvasLayer
## Optional controls on the ACTUAL game. Uses its player, scenery, residents,
## collision and streamed terrain. No parallel demo floor or review-only terrain.
var game: Node3D
var material: Object
var _view := 0
const VIEWS := [
	{"name":"Ponyville", "at":Vector2(137,-227), "lift":2.0, "target":Vector3(900,320,-2200)},
	{"name":"Town overlook", "at":Vector2(-550,120), "lift":160.0, "target":Vector3(200,0,-250)},
	{"name":"Foal Mountain", "at":Vector2(2750,-450), "lift":180.0, "target":Vector3(3737,490,-1027)},
	{"name":"Northern range", "at":Vector2(4000,-3000), "lift":1100.0, "target":Vector3(4857,1500,-5747)}
]

func _ready() -> void:
	game=get_parent();material=WorldTerrain.instance.terrain.material
	if game.xr_active:queue_free();return
	var panel:=PanelContainer.new();panel.position=Vector2(18,18);add_child(panel)
	var box:=VBoxContainer.new();panel.add_child(box)
	var title:=Label.new();title.text="EQUESTRIA · TERRAIN REVIEW · Esc for buttons / F6 next view";box.add_child(title)
	var row:=HBoxContainer.new();box.add_child(row)
	for i in VIEWS.size():
		var button:=Button.new();button.text=VIEWS[i].name;button.focus_mode=Control.FOCUS_NONE
		button.pressed.connect(choose_view.bind(i));row.add_child(button)
	var original:=CheckButton.new();original.text="Original ground palette";original.focus_mode=Control.FOCUS_NONE;box.add_child(original)
	original.toggled.connect(func(on):material.set_shader_param("gaea_enabled",not on))
	var hint:=Label.new();hint.text="Real world / current residents · F fly/walk · WASD · Space up / Ctrl down";box.add_child(hint)
	if "--gaea-cost" in OS.get_cmdline_user_args():cost.call_deferred()
	print("EQUESTRIA TERRAIN REVIEW READY")

func _notification(what: int) -> void:
	if what==NOTIFICATION_WM_WINDOW_FOCUS_OUT and "--terrain-review" in OS.get_cmdline_user_args():
		Input.mouse_mode=Input.MOUSE_MODE_VISIBLE

func _physics_process(_delta: float) -> void:
	if is_instance_valid(game) and is_instance_valid(game.player):
		game.player.controls_locked=not get_window().has_focus()

func choose_view(index: int) -> void:
	_view=index
	var entry: Dictionary=VIEWS[index];var xz: Vector2=entry.at
	var y:=WorldTerrain.instance.height_at(Vector3(xz.x,0,xz.y))
	if not is_finite(y):return
	var player: CharacterBody3D=game.player
	player.position=Vector3(xz.x,y+float(entry.lift),xz.y);player.velocity=Vector3.ZERO
	player.flying=true
	var camera: Camera3D=player.get_node("Camera3D")
	player.rotation=Vector3.ZERO;camera.rotation=Vector3.ZERO;camera.look_at(entry.target)
	var angle:=camera.rotation;player.rotation.y=angle.y;camera.rotation=Vector3(angle.x,0,0);player._pitch=angle.x
	# Streamed zone collision may still be arriving after a large teleport; stay in fly mode.
	print("[terrain-review] ",entry.name," at ",player.position)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode==KEY_F6:
		choose_view((_view+1)%VIEWS.size());get_viewport().set_input_as_handled()

func cost() -> void:
	# Paired palette measurements in one live game, after cold loading. No screenshots.
	Engine.max_fps=0;DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var rid:=get_viewport().get_viewport_rid();RenderingServer.viewport_set_measure_render_time(rid,true)
	await get_tree().create_timer(12).timeout
	var rows:=[]
	for mode in [0,1,0,1]:
		material.set_shader_param("gaea_enabled",mode!=0)
		for i in 60:await RenderingServer.frame_post_draw
		var times: Array[float]=[];var wall: Array[float]=[];var previous:=Time.get_ticks_usec()
		for i in 120:
			await RenderingServer.frame_post_draw
			times.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
			var now:=Time.get_ticks_usec();wall.append((now-previous)/1000.0);previous=now
		times.sort();wall.sort();rows.append({"mode":["original","new_palette"][mode],"gpu_p50_ms":times[60],"gpu_p95_ms":times[114],"wall_p50_ms":wall[60],"wall_p95_ms":wall[114]})
	material.set_shader_param("gaea_enabled",true)
	var f:=FileAccess.open("res://captures/gaea/world-paired-cost.json",FileAccess.WRITE);f.store_string(JSON.stringify(rows,"\t"));f.close()
	print("GAEA WORLD PAIRED COST ",JSON.stringify(rows));get_tree().quit()
