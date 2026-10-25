extends Node3D
## Bounded world audio. Catalogue registration is cold; playback never loads/synthesizes.
const MIX := preload("res://world/audio/audio_mix.gd")
const VIEW := preload("res://world/player_view.gd")
const ONE_SHOT_LIMIT := 12
const LOOP_LIMIT := 8
const SOURCE_TTL := 2.0
const CATALOGUE_LIMIT := 256
const VARIANT_LIMIT := 16
const EVENTS := {
	"select": [.055, -25.0, 2.5, .09, "tap"],
	"stow": [.14, -20.0, 4.0, .12, "cloth"],
	"page": [.28, -22.0, 3.0, .20, "paper"],
	"cover": [.14, -21.0, 3.0, .15, "wood"],
	"impact": [.12, -22.0, 5.0, .22, "wood"],
	"tree": [.20, -15.0, 9.0, .30, "wood"],
	"splash": [.32, -18.0, 12.0, .40, "water"],
	"reel": [.07, -25.0, 4.0, .14, "tap"],
	"serve": [.14, -21.0, 5.0, .18, "wood"],
	"grill": [1.1, -27.0, 5.0, .95, "sizzle"],
	"burner": [.65, -24.0, 10.0, .55, "flame"],
	"rope": [.16, -26.0, 4.0, .25, "cloth"],
}
const LEGACY_STREAMS := {
	"select": preload("res://assets/audio/legacy_foley/select.tres"),
	"stow": preload("res://assets/audio/legacy_foley/stow.tres"),
	"page": preload("res://assets/audio/legacy_foley/page.tres"),
	"cover": preload("res://assets/audio/legacy_foley/cover.tres"),
	"impact": preload("res://assets/audio/legacy_foley/impact.tres"),
	"tree": preload("res://assets/audio/legacy_foley/tree.tres"),
	"splash": preload("res://assets/audio/legacy_foley/splash.tres"),
	"reel": preload("res://assets/audio/legacy_foley/reel.tres"),
	"serve": preload("res://assets/audio/legacy_foley/serve.tres"),
	"grill": preload("res://assets/audio/legacy_foley/grill.tres"),
	"burner": preload("res://assets/audio/legacy_foley/burner.tres"),
	"rope": preload("res://assets/audio/legacy_foley/rope.tres"),
}
## One coin jingle for every purchase anywhere (dev 2026-10-14: "a coin jingle sfx when you buy
## stuff worldwide"). Kenney RPG Audio handleCoins (CC0), already packed as foley/coin_01. Flat
## and clear, unlike the quiet positional prop_coins; shops call play_purchase after the payment
## is saved.
const PURCHASE_CUE := "purchase_jingle"
const PURCHASE_SPEC := {"streams": [preload("res://world/audio/designed/foley/coin_01.res")], "volume_db": -13.0,
	"distance": 60.0, "cooldown": 0.2, "priority": 2, "concurrency": 2, "spatial": false, "world_audio": false, "pitch_min": 1.02, "pitch_max": 1.08}
var _catalogue: Dictionary = {}
var _loaded_families: Dictionary = {}
var _voices: Array[Node] = []
var _voice_state: Array[Dictionary] = []
var _active_shots: Array[int] = []
var _loop_players: Array[Node] = []
var _spatial_shots: Array[Node] = []
var _flat_shots: Array[Node] = []
var _spatial_loops: Array[Node] = []
var _flat_loops: Array[Node] = []
var _loops: Dictionary = {}
var _cooldowns: Dictionary = {}
var _last_variants: Dictionary = {}
var _next_handle := 1
var _mix: RefCounted
var _context_owner: WeakRef
var _context_time := 0.0
var _indoor := 0.0
var _underwater := 0.0
var _foreground: Dictionary = {}
var _scope: WeakRef
var _rng := RandomNumberGenerator.new()
var _metrics := {"played": 0, "distance_drops": 0, "cooldown_drops": 0, "capacity_drops": 0, "invalid_drops": 0, "steals": 0, "stale_loops": 0}

static var _cached_mixer: WeakRef

static func _get_mixer(source: Node) -> Node3D:
	if not is_instance_valid(source) or not source.is_inside_tree(): return null
	var tree: SceneTree = source.get_tree()
	var mixer: Node3D = _cached_mixer.get_ref() if _cached_mixer != null else null
	if is_instance_valid(mixer) and mixer.get_parent() == tree.root and mixer.name == &"InteractionSounds":
		return mixer
	mixer = tree.root.get_node_or_null("InteractionSounds")
	if mixer == null:
		mixer = (load("res://world/audio/interaction_sounds.gd") as Script).new()
		mixer.name = "InteractionSounds"; tree.root.add_child(mixer)
	_cached_mixer = weakref(mixer)
	return mixer

## Optional composition-root scope clears voices/context on Game exit.
static func setup(scene: Node) -> void:
	var mixer: Node3D = _get_mixer(scene)
	if mixer == null: return
	mixer._assign_scope(scene)

func _assign_scope(scene: Node) -> void:
	var previous: Node = _scope.get_ref() if _scope != null else null
	if previous != scene: reset_world()
	_scope = weakref(scene); _load_catalogues()
	var release: Callable = _release_scope.bind(scene.get_instance_id())
	if not scene.tree_exiting.is_connected(release): scene.tree_exiting.connect(release)

func _release_scope(scope_id: int) -> void:
	var scene: Node = _scope.get_ref() if _scope != null else null
	if not is_instance_valid(scene) or scene.get_instance_id() != scope_id: return
	reset_world(); _scope = null

static func register_catalogue(source: Node, events: Dictionary) -> void:
	var mixer: Node3D = _get_mixer(source)
	if mixer != null: mixer.add_catalogue(events)

## The purchase jingle, heard wherever the buyer looks (see PURCHASE_SPEC).
static func play_purchase(source: Node3D) -> bool:
	return is_instance_valid(source) and play_event(source, PURCHASE_CUE)

static func play_at(source: Node3D, event: String, at: Vector3 = Vector3.INF) -> void:
	play_event(source, event, {}, at)

static func play_event(source: Node3D, event: String, parameters: Dictionary = {}, at: Vector3 = Vector3.INF) -> bool:
	var mixer: Node3D = _get_mixer(source)
	if mixer == null: return false
	var played: bool = mixer.emit_event(event, source.global_position if at == Vector3.INF else at, source.get_instance_id(), parameters)
	if played: mixer._watch_source(source)
	return played

static func start_loop(source: Node3D, event: String, parameters: Dictionary = {}) -> int:
	var mixer: Node3D = _get_mixer(source)
	return mixer.begin_loop(source, event, parameters) if mixer != null else 0

static func update_loop(source: Node3D, handle: int, parameters: Dictionary = {}, at: Vector3 = Vector3.INF) -> bool:
	var mixer: Node3D = _get_mixer(source)
	if mixer == null: return false
	return mixer.change_loop(source, handle, parameters, at)

static func stop_loop(source: Node, handle: int, fade_seconds: float = .2) -> void:
	if not is_instance_valid(source) or not source.is_inside_tree(): return
	var mixer: Node3D = source.get_tree().root.get_node_or_null("InteractionSounds")
	if mixer != null: mixer.end_loop(source, handle, fade_seconds)

static func release_source(source: Node) -> void:
	if not is_instance_valid(source) or not source.is_inside_tree(): return
	var mixer: Node3D = source.get_tree().root.get_node_or_null("InteractionSounds")
	if mixer != null: mixer._release_id(source.get_instance_id())

static func set_listener_context(source: Node, indoor: float, underwater: float) -> void:
	if not is_finite(indoor) or not is_finite(underwater): return
	var mixer: Node3D = _get_mixer(source)
	if mixer == null: return
	mixer._context_owner = weakref(source); mixer._context_time = Time.get_ticks_msec() * .001
	mixer._indoor = clampf(indoor, 0.0, 1.0); mixer._underwater = clampf(underwater, 0.0, 1.0)

static func set_foreground(source: Node, active: bool) -> void:
	var mixer: Node3D = _get_mixer(source)
	if mixer == null: return
	if active: mixer._foreground[source.get_instance_id()] = weakref(source)
	else: mixer._foreground.erase(source.get_instance_id())

func _ready() -> void:
	_mix = MIX.new(); _mix.setup(); _rng.randomize()
	for i in ONE_SHOT_LIMIT:
		_spatial_shots.append(_new_voice()); _flat_shots.append(_new_flat_voice())
		_voices.append(_spatial_shots[i]); _voice_state.append({"cue": "", "priority": -1, "source_id": 0})
		_spatial_shots[i].finished.connect(_clear_shot.bind(i, _spatial_shots[i]))
		_flat_shots[i].finished.connect(_clear_shot.bind(i, _flat_shots[i]))
	for i in LOOP_LIMIT:
		_spatial_loops.append(_new_voice()); _flat_loops.append(_new_flat_voice())
		_loop_players.append(_spatial_loops[i])
	for cue: String in EVENTS:
		var old: Array = EVENTS[cue]
		_catalogue[cue] = _clean_spec({"streams": [LEGACY_STREAMS[cue]], "volume_db": old[1], "distance": old[2], "cooldown": old[3], "pitch_min": .96, "pitch_max": 1.04})
		_catalogue[cue]["cue"] = cue
	_catalogue[PURCHASE_CUE] = _clean_spec(PURCHASE_SPEC)
	_catalogue[PURCHASE_CUE]["cue"] = PURCHASE_CUE

	_load_catalogues()

func _load_catalogues() -> void:
	# Known families only, at cold setup. Missing files are never cached as loaded.
	for path: String in ["res://world/audio/flight_catalogue.gd", "res://world/audio/environment_catalogue.gd", "res://world/audio/props_catalogue.gd"]:
		_load_catalogue(path)

func _load_catalogue(path: String) -> bool:
	if _loaded_families.has(path): return true
	if not ResourceLoader.exists(path): return false
	var family: Script = load(path)
	if family == null: return false
	var constants: Dictionary = family.get_script_constant_map()
	if not constants.get("EVENTS", null) is Dictionary: return false
	add_catalogue(constants["EVENTS"]); _loaded_families[path] = true
	return true

func _new_flat_voice() -> AudioStreamPlayer:
	var voice := AudioStreamPlayer.new()
	voice.max_polyphony = 1; voice.bus = "Wind"; add_child(voice)
	return voice

func _new_voice() -> AudioStreamPlayer3D:
	var voice := AudioStreamPlayer3D.new()
	voice.unit_size = .7; voice.max_polyphony = 1
	voice.bus = "WorldSFX"; add_child(voice)
	return voice

## A caller's streams are held once; no per-frame/file discovery or sample generation.
func add_catalogue(events: Dictionary) -> void:
	for cue: Variant in events:
		if not cue is String or not events[cue] is Dictionary: continue
		if not _catalogue.has(cue) and _catalogue.size() >= CATALOGUE_LIMIT: continue
		var spec: Dictionary = _clean_spec(events[cue])
		if not spec.is_empty():
			spec["cue"] = cue
			if str(cue).begins_with("prop_ui_"): spec["world_audio"] = false
			_catalogue[cue] = spec
	for legacy: String in EVENTS:
		var candidate: String = ("env_" if legacy == "splash" else "prop_") + legacy
		if _catalogue.has(candidate): _catalogue[legacy] = _catalogue[candidate]

func _clean_spec(raw: Dictionary) -> Dictionary:
	var streams: Array[AudioStream] = []
	for stream: Variant in raw.get("streams", []):
		if stream is AudioStream and streams.size() < VARIANT_LIMIT: streams.append(stream)
	if streams.is_empty(): return {}
	var spec: Dictionary = raw.duplicate()
	spec["streams"] = streams
	for pair: Array in [["volume_db", -22.0, -60.0, 0.0], ["distance", 12.0, .5, 400.0], ["cooldown", .15, 0.0, 10.0], ["pitch_min", .98, .5, 2.0], ["pitch_max", 1.02, .5, 2.0]]:
		var value: Variant = raw.get(pair[0], pair[1])
		if not (value is float or value is int) or not is_finite(float(value)): return {}
		spec[pair[0]] = clampf(float(value), float(pair[2]), float(pair[3]))
	for key: String in ["priority", "concurrency"]:
		var value: Variant = raw.get(key, 1 if key == "priority" else 2)
		if not (value is int or value is float) or not is_finite(float(value)): return {}
		spec[key] = clampi(int(value), 0 if key == "priority" else 1, 3 if key == "priority" else 6)
	spec["loop"] = bool(raw.get("loop", false))
	spec["spatial"] = bool(raw.get("spatial", true))
	spec["world_audio"] = bool(raw.get("world_audio", true))
	spec["bus"] = str(raw.get("bus", "SFX"))
	if not spec.bus in ["SFX", "Ambience", "Wind"]: spec["bus"] = "SFX"
	var materials: Dictionary = raw.get("materials", {}) if raw.get("materials", {}) is Dictionary else {}
	var clean_materials := {}
	for material: Variant in materials:
		if not material is String or not materials[material] is Array or clean_materials.size() >= 32: continue
		var variants: Array[AudioStream] = []
		for stream: Variant in materials[material]:
			if stream is AudioStream and variants.size() < VARIANT_LIMIT: variants.append(stream)
		if not variants.is_empty(): clean_materials[material] = variants
	spec["materials"] = clean_materials
	if bool(spec.loop):
		var looped: Array[AudioStream] = []
		for stream: AudioStream in streams:
			var copy: AudioStream = stream.duplicate()
			if copy is AudioStreamWAV:
				copy.loop_mode = AudioStreamWAV.LOOP_FORWARD; copy.loop_begin = 0
				copy.loop_end = roundi(copy.get_length() * copy.mix_rate)
			elif copy is AudioStreamOggVorbis: copy.loop = true
			elif copy is AudioStreamMP3: copy.loop = true
			else: continue
			looped.append(copy)
		if looped.is_empty(): return {}
		spec["streams"] = looped
	return spec

func _parameters(raw: Dictionary) -> Dictionary:
	var clean := {"intensity": 1.0, "pitch": 1.0, "occlusion": 0.0, "volume_db": 0.0, "material": str(raw.get("material", ""))}
	for key: String in ["intensity", "pitch", "occlusion", "volume_db"]:
		var value: Variant = raw.get(key, clean[key])
		if not (value is float or value is int) or not is_finite(float(value)): return {}
		clean[key] = float(value)
	clean.intensity = clampf(clean.intensity, 0.0, 1.0)
	clean.pitch = clampf(clean.pitch, .5, 2.0)
	clean.occlusion = clampf(clean.occlusion, 0.0, 1.0)
	clean.volume_db = clampf(clean.volume_db, -30.0, 6.0)
	return clean

func _audible(at: Vector3, distance: float) -> bool:
	var camera: Camera3D = VIEW.camera(self)
	return camera == null or camera.global_position.distance_squared_to(at) <= distance * distance

func _stream(cue: String, spec: Dictionary, material: String) -> AudioStream:
	var variants: Array = spec.streams
	var materials: Dictionary = spec.materials
	if materials.has(material) and materials[material] is Array and not materials[material].is_empty(): variants = materials[material]
	var key: String = cue + ":" + (material if materials.has(material) else "")
	var index: int = _rng.randi_range(0, variants.size() - 1)
	if variants.size() > 1 and index == int(_last_variants.get(key, -1)): index = (index + 1) % variants.size()
	_last_variants[key] = index
	return variants[index] as AudioStream

func _configure(voice: Node, spec: Dictionary, params: Dictionary) -> void:
	voice.bus = {"SFX": "WorldSFX", "Ambience": "WorldAmbience", "Wind": "Wind"}[spec.bus] if bool(spec.world_audio) else str(spec.bus)
	if voice is AudioStreamPlayer3D: voice.max_distance = float(spec.distance)
	voice.pitch_scale = clampf(_rng.randf_range(minf(spec.pitch_min, spec.pitch_max), maxf(spec.pitch_min, spec.pitch_max)) * float(params.pitch), .5, 2.0)
	if voice is AudioStreamPlayer3D: voice.attenuation_filter_cutoff_hz = lerpf(18000.0, 2200.0, params.occlusion)
	voice.volume_db = _gain(spec, params)

func _gain(spec: Dictionary, params: Dictionary) -> float:
	return maxf(-80.0, float(spec.volume_db) + float(params.volume_db) + linear_to_db(maxf(float(params.intensity), .0001)) - float(params.occlusion) * 8.0)

func emit_event(event: String, at: Vector3, source_id: int, parameters: Dictionary = {}) -> bool:
	if not at.is_finite() or not _catalogue.has(event): _metrics.invalid_drops += 1; return false
	var spec: Dictionary = _catalogue[event]
	var cue: String = str(spec.cue)
	var params: Dictionary = _parameters(parameters)
	if params.is_empty() or bool(spec.loop) or float(params.intensity) <= .001: _metrics.invalid_drops += 1; return false
	if not _audible(at, float(spec.distance)): _metrics.distance_drops += 1; return false
	var now: float = Time.get_ticks_msec() * .001
	var key: String = "%s:%s" % [source_id, cue]
	if now < float(_cooldowns.get(key, 0.0)): _metrics.cooldown_drops += 1; return false
	var index := -1
	var steal := -1
	var count := 0
	for i in _voices.size():
		if not _voices[i].playing:
			if index < 0: index = i
		elif str(_voice_state[i].cue) == cue: count += 1
		if _voices[i].playing and int(_voice_state[i].priority) < int(spec.priority):
			if steal < 0 or int(_voice_state[i].priority) < int(_voice_state[steal].priority): steal = i
	if count >= int(spec.concurrency):
		# Opt-in per cue ("replace_farthest"): a nearer sound takes the farthest voice of its cue.
		var far := _farthest_voice(cue, at) if bool(spec.get("replace_farthest", false)) else -1
		if far < 0: _metrics.capacity_drops += 1; return false
		_clear_shot(far, _voices[far]); _metrics.steals += 1
		index = far
	if index < 0:
		index = steal
		if index < 0: _metrics.capacity_drops += 1; return false
		_clear_shot(index, _voices[index]); _metrics.steals += 1
	if _cooldowns.size() >= 512:
		for old: String in _cooldowns.keys():
			if float(_cooldowns[old]) <= now: _cooldowns.erase(old)
		if _cooldowns.size() >= 512: _cooldowns.erase(_cooldowns.keys()[0])
	_voices[index] = _spatial_shots[index] if bool(spec.spatial) else _flat_shots[index]
	var voice: Node = _voices[index]
	voice.stream = _stream(cue, spec, str(params.material))
	if voice.stream == null: _metrics.invalid_drops += 1; return false
	_configure(voice, spec, params)
	if voice is Node3D: voice.global_position = at
	_voice_state[index] = {"cue": cue, "priority": int(spec.priority), "source_id": source_id}
	_cooldowns[key] = now + float(spec.cooldown)
	voice.play(); _metrics.played += 1
	if index not in _active_shots: _active_shots.append(index)
	return true

## The playing voice of `cue` farthest from the listener, when it is farther than `at`; else -1.
func _farthest_voice(cue: String, at: Vector3) -> int:
	var camera: Camera3D = VIEW.camera(self)
	if camera == null: return -1
	var ear := camera.global_position
	var best := ear.distance_squared_to(at)
	var found := -1
	for i in _voices.size():
		var voice: Node = _voices[i]
		if not voice is Node3D or not voice.playing or str(_voice_state[i].cue) != cue: continue
		var d := ear.distance_squared_to((voice as Node3D).global_position)
		if d > best: best = d; found = i
	return found

func begin_loop(source: Node3D, event: String, parameters: Dictionary) -> int:
	if not _catalogue.has(event) or not bool(_catalogue[event].loop): return 0
	var params: Dictionary = _parameters(parameters)
	if params.is_empty() or not source.global_position.is_finite(): return 0
	var source_id: int = source.get_instance_id()
	var spec: Dictionary = _catalogue[event]
	var cue: String = str(spec.cue)
	for handle: int in _loops:
		var loop: Dictionary = _loops[handle]
		if int(loop.source_id) == source_id and str(loop.cue) == cue:
			change_loop(source, handle, parameters); return handle
	var count := 0
	for loop: Dictionary in _loops.values():
		if str(loop.cue) == cue: count += 1
	if count >= int(spec.concurrency): _metrics.capacity_drops += 1; return 0
	var index := -1
	for i in _loop_players.size():
		var used := false
		for loop: Dictionary in _loops.values():
			if int(loop.index) == i: used = true; break
		if not used: index = i; break
	if index < 0:
		for handle: int in _loops:
			var loop: Dictionary = _loops[handle]
			if int(loop.spec.priority) < int(spec.priority):
				index = int(loop.index); _remove_loop(handle); _metrics.steals += 1; break
	if index < 0: _metrics.capacity_drops += 1; return 0
	_loop_players[index] = _spatial_loops[index] if bool(spec.spatial) else _flat_loops[index]
	var voice: Node = _loop_players[index]
	voice.stream = _stream(cue, spec, "")
	_configure(voice, spec, params); voice.volume_db = -80.0
	if voice is Node3D: voice.global_position = source.global_position
	var handle: int = _next_handle; _next_handle += 1
	_loops[handle] = {"position": source.global_position, "index": index, "owner": weakref(source), "source_id": source_id, "cue": cue, "spec": spec, "params": params, "gain": -80.0, "stop": false, "fade": .2, "updated": Time.get_ticks_msec() * .001}
	_watch_source(source)
	return handle

func change_loop(source: Node3D, handle: int, parameters: Dictionary, at: Vector3 = Vector3.INF) -> bool:
	if not _loops.has(handle) or int(_loops[handle].source_id) != source.get_instance_id(): return false
	var params: Dictionary = _parameters(parameters)
	var position: Vector3 = source.global_position if at == Vector3.INF else at
	if params.is_empty() or not position.is_finite(): return false
	var loop: Dictionary = _loops[handle]
	loop.params = params; loop.updated = Time.get_ticks_msec() * .001; loop.stop = false
	var voice: Node = _loop_players[int(loop.index)]
	loop.position = position
	if voice is Node3D: voice.global_position = position
	voice.pitch_scale = float(params.pitch)
	if voice is AudioStreamPlayer3D: voice.attenuation_filter_cutoff_hz = lerpf(18000.0, 2200.0, params.occlusion)
	return true

func end_loop(source: Node, handle: int, fade_seconds: float) -> void:
	if not _loops.has(handle) or int(_loops[handle].source_id) != source.get_instance_id(): return
	if not is_finite(fade_seconds): return
	if fade_seconds <= 0.0: _remove_loop(handle); return
	_loops[handle].stop = true; _loops[handle].fade = clampf(fade_seconds, .01, 2.0)

func _remove_loop(handle: int) -> void:
	var index: int = int(_loops[handle].index)
	_loop_players[index].stop(); _loop_players[index].stream = null
	_loops.erase(handle)

func _watch_source(source: Node) -> void:
	var release: Callable = _release_id.bind(source.get_instance_id())
	if not source.tree_exiting.is_connected(release): source.tree_exiting.connect(release)

func _clear_shot(index: int, voice: Node) -> void:
	if _voices[index] != voice: return
	_active_shots.erase(index)
	voice.stop(); voice.stream = null
	_voice_state[index] = {"cue": "", "priority": -1, "source_id": 0}

func _release_id(source_id: int) -> void:
	for i in _voices.size():
		if int(_voice_state[i].source_id) == source_id: _clear_shot(i, _voices[i])
	for handle: int in _loops.keys():
		if int(_loops[handle].source_id) == source_id: _remove_loop(handle)
	_foreground.erase(source_id)

func _process(delta: float) -> void:
	var now: float = Time.get_ticks_msec() * .001
	var context_source: Node = _context_owner.get_ref() if _context_owner != null else null
	if not is_instance_valid(context_source) or not context_source.is_inside_tree() or now - _context_time > SOURCE_TTL:
		_indoor = 0.0; _underwater = 0.0
	for id: int in _foreground.keys():
		var owner: Node = _foreground[id].get_ref()
		if not is_instance_valid(owner) or not owner.is_inside_tree(): _foreground.erase(id)
	var foreground: bool = not _foreground.is_empty()
	# Admission/finish/steal keep this bounded list; idle slots need no frame polling.
	for i: int in _active_shots:
		if _voices[i].playing and int(_voice_state[i].priority) >= 3: foreground = true; break
	_mix.step(delta, _indoor, _underwater, foreground)
	for handle: int in _loops.keys():
		var loop: Dictionary = _loops[handle]
		var owner: Node = loop.owner.get_ref()
		if not is_instance_valid(owner) or not owner.is_inside_tree() or now - float(loop.updated) > SOURCE_TTL:
			_metrics.stale_loops += 1; _remove_loop(handle); continue
		var voice: Node = _loop_players[int(loop.index)]
		var audible: bool = not bool(loop.stop) and float(loop.params.intensity) > .001 and _audible(loop.position, float(loop.spec.distance))
		var target: float = _gain(loop.spec, loop.params) if audible else -80.0
		loop.gain = lerpf(float(loop.gain), target, 1.0 - exp(-delta * (6.67 if not loop.stop else 5.0 / float(loop.fade))))
		voice.volume_db = float(loop.gain)
		if audible and not voice.playing: voice.play()
		elif not audible and float(loop.gain) < -65.0:
			voice.stop()
			if bool(loop.stop): _remove_loop(handle)

func reset_world() -> void:
	for i in _voices.size(): _clear_shot(i, _voices[i])
	for handle: int in _loops.keys(): _remove_loop(handle)
	_cooldowns.clear(); _last_variants.clear(); _foreground.clear()
	_context_owner = null; _context_time = 0.0; _indoor = 0.0; _underwater = 0.0
	if _mix != null: _mix.reset()

func diagnostics() -> Dictionary:
	var result: Dictionary = _metrics.duplicate()
	result["loops"] = _loops.size(); result["cooldowns"] = _cooldowns.size()
	result["catalogue"] = _catalogue.size(); result["one_shot_capacity"] = _voices.size(); result["loop_capacity"] = _loop_players.size()
	return result

func _exit_tree() -> void:
	reset_world()

## Original synthesized foley, not recordings. Smooth attack/release prevents clicks.
static func synthesize(seconds: float, kind: String) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new(); wav.format = AudioStreamWAV.FORMAT_16_BITS; wav.mix_rate = 22050
	var count: int = int(seconds * wav.mix_rate)
	var data := PackedByteArray(); data.resize(count * 2)
	var rng := RandomNumberGenerator.new(); rng.seed = 92826
	var low: float = 0.0
	for i in count:
		var t: float = float(i) / wav.mix_rate
		var p: float = float(i) / count
		var noise: float = rng.randf_range(-1, 1)
		low = lerpf(low, noise, .15)
		var envelope: float = minf(t / .004, 1.0) * pow(1.0 - p, 2.0)
		var value: float = low
		match kind:
			"tap": value = low * .45 + sin(TAU * 430 * t) * exp(-t * 120) * .3
			"wood": value = low * .6 + (sin(TAU * 170 * t) + sin(TAU * 283 * t) * .35) * exp(-t * 38) * .4
			"cloth", "paper":
				envelope = pow(sin(PI * p), 1.5)
				value = (noise - low) * (.19 if kind == "paper" else .12) + low * .3
			"water": value = low * .85 + sin(TAU * (540 * t + 620 * t * t)) * exp(-t * 16) * .10
			"sizzle", "flame":
				envelope = minf(t / .07, 1.0) * minf((seconds - t) / .14, 1.0)
				value = (noise - low) * .20 if kind == "sizzle" else low * 1.1
		data.encode_s16(i * 2, roundi(clampf(value * envelope, -.85, .85) * 32767))
	wav.data = data
	return wav
