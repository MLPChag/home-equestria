extends Node
## Playtest bridge (dev, 2026-09-23): lets an AI playtester play the running desktop game.
## Enabled only with `-- --playtest-bridge [--playtest-port N]`; game.gd adds it.
## One JSON object per line over TCP 127.0.0.1:8795 (tools/playtest/pt.py is the client).
## Actions go through the real input path (InputEventAction / InputEventKey / mouse events)
## wherever the game reads input; only look direction, teleport and time are set directly.
## Every error and warning the engine logs, falls through the world, non-finite positions
## and long frames are recorded as incidents and returned by "incidents".
const PORT := 8795
const LOG_LINES := 400

class Tap extends Logger:
	var mutex := Mutex.new()
	var lines: Array[String] = []
	var total := 0   # lines ever logged, so callers can ask for "everything since"
	var errors: Array[Dictionary] = []
	func _log_message(message: String, error: bool) -> void:
		mutex.lock()
		for line in message.strip_edges().split("\n"):
			if line.strip_edges() != "": lines.append(line); total += 1
		while lines.size() > 400: lines.pop_front()
		mutex.unlock()
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _notify: bool, type: int, backtraces: Array[ScriptBacktrace]) -> void:
		mutex.lock()
		var text := rationale if rationale != "" else code
		var where := "%s:%d %s" % [file, line, function]
		# The GDScript caller says far more than the engine file that raised it.
		for bt in backtraces:
			if bt.get_frame_count() > 0: where = "%s:%d %s" % [bt.get_frame_file(0), bt.get_frame_line(0), bt.get_frame_function(0)]; break
		errors.append({"type": ["error", "warning", "script", "shader"][clampi(type, 0, 3)], "text": text, "where": where})
		lines.append("ERROR: " + text); total += 1
		mutex.unlock()

var game: Node
var server := TCPServer.new()
var peers: Array[StreamPeerTCP] = []
var buffers: Array[String] = []
var busy := false
var queue: Array = []   # [peer, request]
var tap := Tap.new()
var incidents: Array[Dictionary] = []
var _incident_counts := {}
var _frame_ms := 0.0
var _last_usec := 0

func _ready() -> void:
	OS.add_logger(tap)
	var args := OS.get_cmdline_user_args()
	var port := PORT
	var at := args.find("--playtest-port")
	if at >= 0 and at + 1 < args.size(): port = int(args[at + 1])
	var err := server.listen(port, "127.0.0.1")
	print("[playtest] bridge ", "listening on 127.0.0.1:%d" % port if err == OK else "FAILED to listen: %s" % error_string(err))
	process_mode = Node.PROCESS_MODE_ALWAYS

func _exit_tree() -> void:
	OS.remove_logger(tap)
	server.stop()

func player() -> Node3D: return game.player if is_instance_valid(game) else null

# ------------------------------------------------------------------ network
func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_usec > 0:
		_frame_ms = (now - _last_usec) / 1000.0
		if _frame_ms > 250.0: _incident("long_frame", "frame took %.0f ms" % _frame_ms)
	_last_usec = now
	while server.is_connection_available():
		peers.append(server.take_connection()); buffers.append("")
	for i in range(peers.size() - 1, -1, -1):
		var peer := peers[i]; peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			peers.remove_at(i); buffers.remove_at(i); continue
		var n := peer.get_available_bytes()
		if n > 0: buffers[i] += peer.get_utf8_string(n)
		while "\n" in buffers[i]:
			var cut := buffers[i].find("\n")
			var line := buffers[i].substr(0, cut).strip_edges(); buffers[i] = buffers[i].substr(cut + 1)
			if line != "": queue.append([peer, line])
	if not busy and not queue.is_empty():
		var job: Array = queue.pop_front()
		_run(job[0], job[1])

func _run(peer: StreamPeerTCP, line: String) -> void:
	busy = true
	var reply: Dictionary
	var request: Variant = JSON.parse_string(line)
	if not (request is Dictionary) or not request.has("cmd"):
		reply = {"ok": false, "error": "send one JSON object per line with a \"cmd\""}
	elif not has_method("cmd_" + str(request.cmd)):
		reply = {"ok": false, "error": "unknown cmd %s" % request.cmd, "commands": _commands()}
	else:
		reply = await call("cmd_" + str(request.cmd), request)
		if not reply.has("ok"): reply["ok"] = true
	reply["new_incidents"] = incidents.size()
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(_plain(reply)) + "\n").to_utf8_buffer())
	busy = false

func _commands() -> Array:
	return get_method_list().map(func(m): return str(m.name)).filter(func(n: String): return n.begins_with("cmd_")).map(func(n: String): return n.trim_prefix("cmd_"))

## JSON cannot hold Vector3 & co: round and flatten.
func _plain(v: Variant) -> Variant:
	match typeof(v):
		TYPE_VECTOR3: return [snappedf(v.x, .01), snappedf(v.y, .01), snappedf(v.z, .01)]
		TYPE_VECTOR2: return [snappedf(v.x, .01), snappedf(v.y, .01)]
		TYPE_FLOAT: return snappedf(v, .001) if is_finite(v) else str(v)
		TYPE_DICTIONARY:
			var out := {}
			for k in v: out[str(k)] = _plain(v[k])
			return out
		TYPE_ARRAY:
			return (v as Array).map(_plain)
		TYPE_OBJECT:
			return str(v)
		TYPE_STRING_NAME, TYPE_NODE_PATH: return str(v)
		TYPE_PACKED_STRING_ARRAY: return Array(v)
	return v

# ------------------------------------------------------------------ watchdog
func _physics_process(_delta: float) -> void:
	tap.mutex.lock(); var fresh := tap.errors.duplicate(); tap.errors.clear(); tap.mutex.unlock()
	for e in fresh: _incident("engine_" + str(e.type), str(e.text), {"where": e.where})
	var body := player()
	if body == null: return
	var p := body.global_position
	if not p.is_finite(): _incident("player_nan", "player position is not finite")
	elif _below_ground(p, 1.0): _incident("player_under_ground", "player is under the terrain", {"pos": p})
	for pony: Node3D in get_tree().get_nodes_in_group("sim_ponies"):
		var q := pony.global_position
		if not q.is_finite(): _incident("pony_nan", "%s position is not finite" % _pony_name(pony))
		elif _below_ground(q, 1.5): _incident("pony_under_ground", "%s is under the terrain" % _pony_name(pony), {"pos": q})

func _below_ground(p: Vector3, margin: float) -> bool:
	if not is_instance_valid(WorldTerrain.instance): return p.y < -500.0
	var h: float = WorldTerrain.instance.height_at(p)
	return is_finite(h) and p.y < h - margin

## Same kind and text counted, not repeated: a per-frame error would flood the list.
func _incident(kind: String, text: String, extra := {}) -> void:
	var key := kind + "|" + text
	if _incident_counts.has(key):
		_incident_counts[key].count += 1; return
	var entry := {"kind": kind, "text": text, "count": 1, "time_s": snappedf(Time.get_ticks_msec() / 1000.0, .1)}
	entry.merge(extra)
	if player() != null: entry["player_pos"] = player().global_position
	_incident_counts[key] = entry; incidents.append(entry)

# ------------------------------------------------------------------ helpers
func _pony_name(pony: Node) -> String:
	var identity = pony.get("identity")
	return str(identity.display_name) if identity != null and "display_name" in identity else str(pony.name)

func _find_pony(name: String) -> Node3D:
	var want := name.to_lower()
	for pony: Node3D in get_tree().get_nodes_in_group("sim_ponies"):
		if _pony_name(pony).to_lower().contains(want) or str(pony.name).to_lower().contains(want): return pony
	return null

func _yaw_to(target: Vector3) -> float:
	var body := player(); var d := target - body.global_position
	return atan2(-d.x, -d.z)

func _face(yaw: float) -> void:
	var body := player(); body.rotation.y = yaw

func _key(name: String) -> int:
	var code := OS.find_keycode_from_string(name)
	return code

func _send_key(code: int, pressed: bool, shift := false, unicode := 0) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code; ev.keycode = code; ev.pressed = pressed; ev.shift_pressed = shift; ev.unicode = unicode
	Input.parse_input_event(ev)

func _action(action: String, pressed: bool) -> void:
	var ev := InputEventAction.new(); ev.action = action; ev.pressed = pressed; ev.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)

func _ensure_captured() -> void:
	# Gameplay keys (chat, pick up, drop) only act while the mouse is captured.
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _seconds(request: Dictionary, key: String, fallback: float, limit := 120.0) -> float:
	return clampf(float(request.get(key, fallback)), 0.0, limit)

func _wait(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until: await get_tree().physics_frame

# ------------------------------------------------------------------ commands
func cmd_ping(_r: Dictionary) -> Dictionary:
	return {"pong": true, "ready": player() != null, "commands": _commands()}

## Where you are, what you face, who is around, open UI.
func cmd_state(r: Dictionary) -> Dictionary:
	var body := player()
	if body == null: return {"ok": false, "error": "no player yet"}
	var cam: Camera3D = get_viewport().get_camera_3d()
	var out := {"pos": body.global_position, "yaw_deg": rad_to_deg(body.rotation.y), "frame_ms": _frame_ms, "fps": Engine.get_frames_per_second(),
		"mouse_mode": ["visible", "hidden", "captured", "confined"][Input.mouse_mode] if Input.mouse_mode < 4 else Input.mouse_mode}
	for k in ["velocity", "flying", "crouching", "controls_locked"]:
		if k in body: out[k] = body.get(k)
	if body is CharacterBody3D: out["on_floor"] = (body as CharacterBody3D).is_on_floor()
	if cam != null:
		out["pitch_deg"] = rad_to_deg(cam.global_rotation.x)
		var from := cam.global_position; var to := from - cam.global_basis.z * 8.0
		var q := PhysicsRayQueryParameters3D.create(from, to); q.exclude = [body.get_rid()]
		var hit := body.get_world_3d().direct_space_state.intersect_ray(q)
		out["looking_at"] = {"what": _describe(hit.collider), "distance": from.distance_to(hit.position)} if not hit.is_empty() else "nothing within 8 m"
	var tod := get_node_or_null("/root/TimeOfDay")
	if tod != null: out["time"] = {"hours": tod.hours, "day": tod.day, "paused": tod.paused}
	var home: Node3D = preload("res://world/buildings/house_interior.gd").at(get_tree(), body.global_position)
	out["in_house"] = home.label() if home != null else ""
	var radius := float(r.get("radius", 25.0)); var ponies := []
	for pony: Node3D in get_tree().get_nodes_in_group("sim_ponies"):
		var d := pony.global_position.distance_to(body.global_position)
		if d > radius: continue
		var entry := {"name": _pony_name(pony), "dist": d, "pos": pony.global_position,
			"bearing_deg": rad_to_deg(wrapf(_yaw_to(pony.global_position) - body.rotation.y, -PI, PI))}
		if pony.has_method("posture_status"): entry["posture"] = pony.posture_status().get("kind", "")
		for k in ["sleeping", "_held"]:
			if k in pony: entry[k.trim_prefix("_")] = pony.get(k)
		if pony.get("flight") != null: entry["flying"] = pony.flight.active()
		var nav := pony.get_node_or_null("Navigator")
		if nav != null: entry["doing"] = str(nav.get("reason"))
		ponies.append(entry)
	ponies.sort_custom(func(a, b): return a.dist < b.dist)
	out["ponies_near"] = ponies
	var ui := {}
	var chat := game.get_node_or_null("ChatBox")
	if chat != null: ui["chat_open"] = chat.visible
	if is_instance_valid(game.inventory) and game.inventory.get("case") != null: ui["briefcase_open"] = game.inventory.case.visible
	out["ui"] = ui
	return out

func _describe(node: Object) -> String:
	if node == null: return "?"
	var n := node as Node
	while n != null:
		if n.is_in_group("sim_ponies"): return "pony " + _pony_name(n)
		if n.has_method("label") and n.has_method("place_id"): return n.label()
		n = n.get_parent()
	return str((node as Node).get_path()) if node is Node else str(node)

## Hold input actions and/or keys for some seconds: {"actions":["move_forward","move_sprint"], "keys":["Ctrl"], "seconds":2}
## Actions: move_forward move_back move_left move_right move_sprint move_jump (see project input map).
func cmd_hold(r: Dictionary) -> Dictionary:
	_ensure_captured()
	var actions: Array = r.get("actions", []); var keys: Array = r.get("keys", [])
	var before := player().global_position
	for a in actions:
		if not InputMap.has_action(a): return {"ok": false, "error": "no input action %s" % a, "actions": InputMap.get_actions().filter(func(x): return not str(x).begins_with("ui_"))}
		_action(a, true)
	for k in keys: _send_key(_key(k), true)
	await _wait(_seconds(r, "seconds", 1.0, 60.0))
	for a in actions: _action(a, false)
	for k in keys: _send_key(_key(k), false)
	await get_tree().physics_frame
	return {"moved_m": player().global_position.distance_to(before), "pos": player().global_position}

## Press and release a key: {"key":"E", "shift":false, "times":1, "gap":0.15}. Names as Godot's (E, Enter, Escape, F5, 1, Space, Ctrl).
func cmd_tap(r: Dictionary) -> Dictionary:
	_ensure_captured()
	var code := _key(str(r.get("key", "")))
	if code == KEY_NONE: return {"ok": false, "error": "unknown key name %s" % r.get("key")}
	for i in clampi(int(r.get("times", 1)), 0, 500):
		_send_key(code, true, bool(r.get("shift", false))); await get_tree().physics_frame
		_send_key(code, false, bool(r.get("shift", false)))
		await _wait(_seconds(r, "gap", .12, 10.0))
	return {"sent": r.get("key")}

## Mouse button: {"button":"left"|"right", "seconds":0}
func cmd_click(r: Dictionary) -> Dictionary:
	_ensure_captured()
	var ev := InputEventMouseButton.new(); ev.button_index = MOUSE_BUTTON_RIGHT if r.get("button", "left") == "right" else MOUSE_BUTTON_LEFT
	ev.position = get_viewport().get_visible_rect().size * .5; ev.pressed = true; Input.parse_input_event(ev)
	await _wait(_seconds(r, "seconds", 0.05, 30.0))
	var up := ev.duplicate(); up.pressed = false; Input.parse_input_event(up)
	return {}

## Turn: {"yaw":deg, "pitch":deg} relative, or {"face":[x,z]} / {"face_pony":"Twilight"} absolute.
func cmd_look(r: Dictionary) -> Dictionary:
	var body := player()
	if r.has("face"): _face(_yaw_to(Vector3(r.face[0], 0, r.face[1])))
	elif r.has("face_pony"):
		var pony := _find_pony(str(r.face_pony))
		if pony == null: return {"ok": false, "error": "no pony named %s" % r.face_pony}
		_face(_yaw_to(pony.global_position))
	else: body.rotation.y += deg_to_rad(float(r.get("yaw", 0.0)))
	var cam: Camera3D = body.get_node_or_null("Camera3D")
	if cam != null and (r.has("pitch") or r.has("face_pony")):
		# Relative pitch, except facing a pony: then look slightly down at her.
		var target := deg_to_rad(-8.0) if r.has("face_pony") else float(body.get("_pitch")) + deg_to_rad(float(r.pitch))
		target = clampf(target, -1.5, 1.5)
		body.set("_pitch", target); cam.rotation.x = target
	return {"yaw_deg": rad_to_deg(body.rotation.y)}

## Walk with the real move keys toward a point or a pony, steering each frame:
## {"to":[x,z]} or {"pony":"Rarity"}, "run":false, "stop_at":1.2, "timeout":30
func cmd_walk_to(r: Dictionary) -> Dictionary:
	_ensure_captured()
	var body := player(); var run := bool(r.get("run", false))
	var stop_at := float(r.get("stop_at", 1.2)); var timeout := _seconds(r, "timeout", 30.0)
	var start := Time.get_ticks_msec(); var last_progress := body.global_position; var stuck_s := 0.0
	_action("move_forward", true)
	if run: _action("move_sprint", true)
	var result := "timeout"
	while Time.get_ticks_msec() - start < timeout * 1000.0:
		var goal: Vector3
		if r.has("pony"):
			var pony := _find_pony(str(r.pony))
			if pony == null: result = "pony not found"; break
			goal = pony.global_position
		else: goal = Vector3(r.to[0], body.global_position.y, r.to[1])
		var flat := Vector2(goal.x - body.global_position.x, goal.z - body.global_position.z).length()
		if flat <= stop_at: result = "arrived"; break
		_face(_yaw_to(goal))
		await get_tree().physics_frame
		if body.global_position.distance_to(last_progress) > .25: last_progress = body.global_position; stuck_s = 0.0
		else:
			stuck_s += get_physics_process_delta_time()
			if stuck_s > 2.5: result = "stuck"; break
	_action("move_forward", false); _action("move_sprint", false)
	return {"result": result, "pos": body.global_position, "seconds": (Time.get_ticks_msec() - start) / 1000.0}

## Say something through the desktop chat box, like pressing Enter, typing, Enter.
## {"text":"hello", "wait":6} waits for replies and returns the log lines from that time.
func cmd_say(r: Dictionary) -> Dictionary:
	var chat := game.get_node_or_null("ChatBox")
	if chat == null: return {"ok": false, "error": "no chat box (VR or no AI)"}
	_ensure_captured()
	var mark := _log_size()
	_send_key(KEY_ENTER, true); await get_tree().physics_frame; _send_key(KEY_ENTER, false); await get_tree().physics_frame
	if not chat.visible: return {"ok": false, "error": "Enter did not open the chat box (menu open or controls locked?)"}
	var text := str(r.get("text", ""))
	chat.field.text = text
	chat.field.text_submitted.emit(chat.field.text)   # LineEdit clips to max_length like typing would
	await _wait(_seconds(r, "wait", 6.0, 90.0))
	return {"typed_len": text.length(), "kept_len": chat.field.text.length(), "log": _log_since(mark)}

func _log_size() -> int:
	tap.mutex.lock(); var n := tap.total; tap.mutex.unlock(); return n

func _log_since(mark: int) -> Array:
	tap.mutex.lock(); var lines := tap.lines.duplicate(); var total := tap.total; tap.mutex.unlock()
	return lines.slice(maxi(0, lines.size() - (total - mark)))

## Recent game log lines: {"lines":60, "grep":"[ai]"}
func cmd_log(r: Dictionary) -> Dictionary:
	tap.mutex.lock(); var lines := tap.lines.duplicate(); tap.mutex.unlock()
	var needle := str(r.get("grep", ""))
	if needle != "": lines = lines.filter(func(l: String): return l.contains(needle))
	return {"lines": lines.slice(maxi(0, lines.size() - int(r.get("lines", 60))))}

## Put the player somewhere: {"x":..,"z":..} (on the ground) or with "y". A cheat, for reaching test spots.
func cmd_teleport(r: Dictionary) -> Dictionary:
	var body := player()
	var p := Vector3(float(r.get("x", body.global_position.x)), 0.0, float(r.get("z", body.global_position.z)))
	if r.has("y"): p.y = float(r.y)
	elif is_instance_valid(WorldTerrain.instance):
		var h: float = WorldTerrain.instance.height_at(p); p.y = (h if is_finite(h) else body.global_position.y) + .3
	body.global_position = p
	if "velocity" in body: body.velocity = Vector3.ZERO
	await _wait(.3)
	return {"pos": body.global_position}

## Time of day: {"hours":23.5, "paused":false}
func cmd_time(r: Dictionary) -> Dictionary:
	var tod := get_node_or_null("/root/TimeOfDay")
	if tod == null: return {"ok": false, "error": "no TimeOfDay"}
	if r.has("hours"): tod.hours = fposmod(float(r.hours), 24.0)
	if r.has("paused"): tod.paused = bool(r.paused)
	return {"hours": tod.hours, "day": tod.day}

func cmd_wait(r: Dictionary) -> Dictionary:
	await _wait(_seconds(r, "seconds", 1.0))
	return {}

## Save what the game shows: {"name":"bar_door"} -> captures/playtest/shots/<name>.png (needs a display, not --headless).
func cmd_screenshot(r: Dictionary) -> Dictionary:
	if DisplayServer.get_name() == "headless": return {"ok": false, "error": "headless: no pixels"}
	await RenderingServer.frame_post_draw
	var dir := ProjectSettings.globalize_path("res://captures/playtest/shots")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join(str(r.get("name", "shot_%d" % Time.get_ticks_msec())).validate_filename() + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	return {"path": path}

## Incidents since the last call (errors, falls under the ground, NaN, long frames), then cleared.
func cmd_incidents(r: Dictionary) -> Dictionary:
	var out := incidents.duplicate()
	if bool(r.get("clear", true)): incidents.clear(); _incident_counts.clear()
	return {"incidents": out}

## Escape hatch for things with no input binding: {"path":"/root/Main/...", "method":"x", "args":[...]} or {"path":..,"get":"prop"}.
## Paths may be relative to the game root. Use for poking, not for skipping what a player would do.
func cmd_call(r: Dictionary) -> Dictionary:
	var target: Node = game.get_node_or_null(str(r.get("path", "."))) if not str(r.get("path", "")).begins_with("/") else get_node_or_null(str(r.path))
	if r.has("pony"): target = _find_pony(str(r.pony))
	if target == null: return {"ok": false, "error": "no node at %s" % r.get("path", r.get("pony", ""))}
	if r.has("get"): return {"value": _plain(target.get(str(r.get))) }
	if not target.has_method(str(r.get("method", ""))): return {"ok": false, "error": "no method %s on %s" % [r.get("method"), target.name]}
	var value = target.callv(str(r.method), r.get("args", []))
	return {"value": _plain(value)}

## Node names under a path matching text: {"text":"bench", "path":"."}
func cmd_find(r: Dictionary) -> Dictionary:
	var base: Node = game.get_node_or_null(str(r.get("path", ".")))
	var want := str(r.get("text", "")).to_lower(); var hits := []
	for n in base.find_children("*", "", true, false):
		if str(n.name).to_lower().contains(want):
			hits.append({"path": str(game.get_path_to(n)), "class": n.get_class(), "pos": (n as Node3D).global_position if n is Node3D else null})
			if hits.size() >= int(r.get("limit", 30)): break
	return {"hits": hits}

# ------------------------------------------------------------------ pony behaviour
## Everything that competes for one pony, in one place.
func _brain(pony: Node3D) -> Dictionary:
	var b := {"name": _pony_name(pony), "pos": pony.global_position}
	var body := player()
	if body != null: b["dist"] = pony.global_position.distance_to(body.global_position)
	if pony.has_method("grounded"): b["grounded"] = pony.grounded()
	if "sim_tier" in pony: b["tier"] = ["HERO", "NEAR", "FAR"][int(pony.sim_tier)]
	for k in ["_held", "sleeping", "sleep_style", "motion_paused", "body_scale"]:
		if k in pony: b[k.trim_prefix("_")] = pony.get(k)
	if pony.has_method("posture_status"): b["posture"] = pony.posture_status()
	if pony.has_meta("social_group"): b["company"] = pony.get_meta("social_group")
	if pony.has_meta("life_intent"): b["life"] = str(pony.get_meta("life_intent"))
	b["speed"] = snappedf(Vector2(pony.velocity.x, pony.velocity.z).length(), .01) if "velocity" in pony else 0.0
	if pony.get("flight") != null: b["flight"] = str(pony.flight.get("state"))
	var nav := pony.get_node_or_null("Navigator")
	if nav != null:
		var n := {"state": nav.State.keys()[int(nav.state)], "reason": str(nav.reason), "owner": str(nav.command_owner),
			"has_target": nav.get("_has_target"), "target": nav.get("target")}
		var ht = nav.get("house_travel")
		if ht != null and ht.active():
			n["house"] = {"phase": ["APPROACH", "OPEN", "CROSS"][int(ht.phase)], "entering": ht.entering, "home": ht.home.label()}
		b["nav"] = n
	var seating := game.get_node_or_null("Seating")
	if seating != null and seating.has_method("phase"): b["seat"] = seating.phase(pony)
	var rest := game.get_node_or_null("NightRest")
	if rest != null:
		for id in rest._state:
			if rest._state[id].get("actor") == pony: b["night"] = {"id": id, "phase": rest._state[id].phase, "chosen": rest._state[id].chosen}
	var home: Node3D = preload("res://world/buildings/house_interior.gd").at(get_tree(), pony.global_position)
	b["in_house"] = home.label() if home != null else ""
	if is_instance_valid(WorldTerrain.instance):
		var h: float = WorldTerrain.instance.height_at(pony.global_position)
		if is_finite(h): b["above_terrain"] = pony.global_position.y - h
	return b

## Read a dotted field out of a brain dict: "nav.house.phase", "posture.kind", "night.phase".
func _field(b: Dictionary, path: String) -> Variant:
	var v: Variant = b
	for part in path.split("."):
		if not (v is Dictionary) or not v.has(part): return null
		v = v[part]
	return v

func cmd_ponies(_r: Dictionary) -> Dictionary:
	var out := []
	for pony: Node3D in get_tree().get_nodes_in_group("sim_ponies"):
		var b := _brain(pony)
		out.append({"name": b.name, "dist": b.get("dist"), "doing": b.get("nav", {}).get("reason", ""), "owner": b.get("nav", {}).get("owner", ""), "tier": b.get("tier")})
	out.sort_custom(func(a, c): return float(a.dist) < float(c.dist))
	return {"ponies": out}

## Full behaviour state of one pony: {"name":"Trixie"}
func cmd_pony(r: Dictionary) -> Dictionary:
	var pony := _find_pony(str(r.get("name", "")))
	if pony == null: return {"ok": false, "error": "no pony named %s" % r.get("name")}
	return {"pony": _brain(pony)}

## Wait until a pony reaches a state, to strike at the worst moment:
## {"name":"Derpy", "field":"nav.house.phase", "value":"CROSS", "timeout":60}  (value omitted = field just exists)
func cmd_wait_for(r: Dictionary) -> Dictionary:
	var pony := _find_pony(str(r.get("name", "")))
	if pony == null: return {"ok": false, "error": "no pony named %s" % r.get("name")}
	var until := Time.get_ticks_msec() + int(_seconds(r, "timeout", 60.0, 900.0) * 1000.0)
	while Time.get_ticks_msec() < until:
		if not is_instance_valid(pony): return {"ok": false, "error": "pony was freed (streamed out?)"}
		var b := _brain(pony); var v: Variant = _field(b, str(r.get("field", "")))
		if v != null and (not r.has("value") or str(v) == str(r.value) or (r.value is String and str(v).contains(str(r.value)))):
			return {"met": true, "pony": b}
		await get_tree().physics_frame
	return {"met": false, "pony": _brain(pony) if is_instance_valid(pony) else {}}

## Watch one pony for a while and flag what looks wrong: stuck while "moving", state flapping,
## sudden jumps, floating or sinking, owner fights. Returns only the changes, not every sample.
## {"name":"Rarity", "seconds":30, "every":0.25}
func cmd_watch(r: Dictionary) -> Dictionary:
	var pony := _find_pony(str(r.get("name", "")))
	if pony == null: return {"ok": false, "error": "no pony named %s" % r.get("name")}
	var seconds := _seconds(r, "seconds", 20.0, 600.0); var every := maxf(.05, float(r.get("every", .25)))
	var timeline := []; var flags := {}; var last := {}; var start := Time.get_ticks_msec()
	var prev_pos := pony.global_position; var still_moving := 0.0; var airborne := 0.0; var changes := 0
	while Time.get_ticks_msec() - start < seconds * 1000.0:
		await _wait(every)
		if not is_instance_valid(pony): flags["freed"] = "pony left the scene tree (streamed out or freed)"; break
		var b := _brain(pony); var t := snappedf((Time.get_ticks_msec() - start) / 1000.0, .01)
		var key := {"state": _field(b, "nav.state"), "reason": _field(b, "nav.reason"), "owner": _field(b, "nav.owner"),
			"house": _field(b, "nav.house.phase"), "posture": _field(b, "posture.kind"), "night": _field(b, "night.phase"),
			"seat": b.get("seat"), "flight": b.get("flight"), "tier": b.get("tier"), "held": b.get("held"), "sleeping": b.get("sleeping")}
		if key != last:
			var diff := {}
			for k in key:
				if not last.has(k) or last[k] != key[k]: diff[k] = key[k]
			timeline.append({"t": t, "pos": b.pos, "changed": diff}); last = key; changes += 1
		var step := pony.global_position.distance_to(prev_pos)
		var flying := str(b.get("flight", "grounded")) != "grounded"
		if step > 3.0 * every * 4.0 and not flying and not b.get("held", false):
			flags["jump_%d" % timeline.size()] = "moved %.1f m in %.2f s at t=%.1f (teleport?)" % [step, every, t]
		if key.state == "MOVING" and step < .02 * every * 4.0: still_moving += every
		else: still_moving = 0.0
		if still_moving > 5.0: flags["stuck"] = "MOVING but not moving for >5 s at t=%.1f (%s)" % [t, key.reason]
		var above: float = b.get("above_terrain", 0.0)
		if not flying and not b.get("held", false) and b.get("in_house", "") == "" and above > 1.0: airborne += every
		else: airborne = 0.0
		if airborne > 2.0: flags["floating"] = "%.2f m above terrain outdoors, not flying, at t=%.1f" % [above, t]
		if above < -0.5: flags["sunk"] = "%.2f m under terrain at t=%.1f" % [above, t]
		prev_pos = pony.global_position
	if changes > seconds * 1.5: flags["flapping"] = "%d state changes in %.0f s" % [changes, seconds]
	return {"flags": flags, "timeline": timeline.slice(maxi(0, timeline.size() - 80)), "end": _brain(pony) if is_instance_valid(pony) else {}}

func cmd_quit(_r: Dictionary) -> Dictionary:
	# Same path as closing the window: the close request (autosave on quit), then quit.
	(func():
		get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
		get_tree().quit()).call_deferred()
	return {"bye": true}

## What surrounds a point: rays in 8 directions at 0.5 m height, first hit and its node path.
## {"x":..,"z":..} or {"pony":"Name"}; "radius" (default 6 m).
func cmd_ring(r: Dictionary) -> Dictionary:
	var at: Vector3
	if r.has("pony"):
		var p: Node3D = _find_pony(str(r.pony))
		if p == null: return {"ok": false, "error": "no pony"}
		at = p.global_position
	else:
		at = Vector3(float(r.get("x", 0)), float(r.get("y", 0)), float(r.get("z", 0)))
	var space: PhysicsDirectSpaceState3D = (game as Node3D).get_world_3d().direct_space_state
	var out := []
	for k in 8:
		var d := Vector3(cos(TAU * k / 8.0), 0, sin(TAU * k / 8.0))
		var a := at + Vector3.UP * .5
		var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(a, a + d * float(r.get("radius", 6.0)), 1))
		out.append("%d° %s" % [k * 45, "clear" if hit.is_empty() else "%.1fm %s" % [a.distance_to(hit.position), str(game.get_path_to(hit.collider))]])
	return {"at": at, "ring": out}
