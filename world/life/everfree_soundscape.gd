extends Node3D
## Quiet forest bed and rare spatial calls with shared silence. Independent of wolves.
const HABITAT := preload("res://world/life/everfree_habitat.gd")
const DIR := "res://world/audio/everfree/"
const MAX_CALLS := 1
const QUIET_MIN := 40.0
const QUIET_MAX := 100.0
var camera_source: Callable
var habitat_source: Callable
var rng := RandomNumberGenerator.new()
var layers: Array[Dictionary] = []
var beds: Array[AudioStreamPlayer] = []
var calls: Array[AudioStreamPlayer3D] = []
var streams: Dictionary = {}
var gain := 0.0
var target_gain := 0.0
var _sample_in := 0.0
var _loaded := false
var _load_index := 0
var _files: Array[String] = []
var _quiet_in := 40.0
var _recent: Array[String] = []

func _ready() -> void:
	rng.randomize()
	_quiet_in = rng.randf_range(25.0,55.0)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DIR + "soundscape.json"))
	for entry: Dictionary in config.layers:
		var rec := entry.duplicate(true)
		rec["remaining"] = rng.randf_range(float(rec.interval[0]),float(rec.interval[1]))
		rec["last"] = ""
		layers.append(rec)
		for file: String in rec.files:
			if not _files.has(file): _files.append(file)
	for i in MAX_CALLS:
		var call := AudioStreamPlayer3D.new()
		call.bus = _bus(); call.unit_size = 24.0; call.max_distance = 125.0
		call.attenuation_filter_cutoff_hz = 6500.0
		add_child(call); calls.append(call)

func _bus() -> StringName:
	return &"Ambience" if AudioServer.get_bus_index("Ambience") >= 0 else &"Master"

func _camera() -> Camera3D:
	if camera_source.is_valid(): return camera_source.call() as Camera3D
	return preload("res://world/player_view.gd").camera(self)

func _process(delta: float) -> void:
	var camera := _camera()
	if camera == null: return
	_sample_in -= delta
	if _sample_in <= 0.0:
		_sample_in = 0.5
		var weight: float = float(habitat_source.call(camera.global_position)) if habitat_source.is_valid() else HABITAT.strength(camera.global_position)
		target_gain = smoothstep(0.15, 0.75, weight)
	gain = move_toward(gain, target_gain, delta / 4.0)
	# One small file per frame, only on the first visit. No whole-map import or spawn hitch.
	if not _loaded and target_gain > 0.0:
		_load_one()
	if not _loaded: return
	for bed in beds:
		bed.volume_db = linear_to_db(maxf(0.0001, gain * float(bed.get_meta("gain")))) - 14.0
		if gain > 0.001 and not bed.playing: bed.play(rng.randf() * bed.stream.get_length())
		elif gain <= 0.001 and bed.playing: bed.stop()
	for call in calls:
		if call.playing:
			call.volume_db = float(call.get_meta("base_db", -20.0)) + linear_to_db(maxf(gain, 0.0001))
			if gain <= 0.001: call.stop()
	if target_gain < 0.2:
		_quiet_in = maxf(_quiet_in,25.0)
		return
	for rec in layers:
		if rec.kind == "random": rec.remaining -= delta
	# Silence starts after the last recording ends; layers cannot pile up or catch up.
	for call in calls:
		if call.playing: return
	_quiet_in -= delta
	if _quiet_in > 0.0: return
	var due: Array = layers.filter(func(rec: Dictionary) -> bool: return rec.kind == "random" and rec.remaining <= 0.0)
	if due.is_empty(): return
	var rec: Dictionary = due[rng.randi_range(0,due.size()-1)]
	if play_event(rec,camera.global_position):
		rec.remaining = rng.randf_range(float(rec.interval[0]),float(rec.interval[1]))
		_quiet_in = rng.randf_range(QUIET_MIN,QUIET_MAX)
	else: _quiet_in = 5.0

func _load_one() -> void:
	if _load_index < _files.size():
		var file := _files[_load_index]
		var stream := AudioStreamOggVorbis.load_from_file(ProjectSettings.globalize_path(DIR + file))
		if stream != null: streams[file] = stream
		_load_index += 1
		return
	for rec in layers:
		if rec.kind != "loop" or not streams.has(rec.files[0]): continue
		var bed := AudioStreamPlayer.new()
		bed.bus = _bus(); bed.stream = streams[rec.files[0]].duplicate()
		(bed.stream as AudioStreamOggVorbis).loop = true
		bed.volume_db = -80.0; bed.set_meta("gain", float(rec.gain))
		add_child(bed); beds.append(bed)
	_loaded = true

func play_event(rec: Dictionary, eye: Vector3) -> bool:
	var emitter: AudioStreamPlayer3D
	for call in calls:
		if not call.playing: emitter = call; break
	if emitter == null: return false
	var choices: Array = rec.files.filter(func(file: String) -> bool: return streams.has(file) and (rec.files.size() == 1 or file != rec.last))
	if choices.is_empty(): return false
	var fresh: Array = choices.filter(func(file: String) -> bool: return not _recent.has(file))
	if not fresh.is_empty(): choices = fresh
	var selected: String = choices[rng.randi_range(0, choices.size() - 1)]
	_recent.append(selected)
	if _recent.size() > 4: _recent.pop_front()
	rec.last = selected
	var angle := rng.randf() * TAU
	var radius := rng.randf_range(35.0, 90.0)
	# Fixed world-space source throughout playback; doesn't orbit or follow the head.
	var at := eye + Vector3(cos(angle) * radius, rng.randf_range(-0.5, 7.0), sin(angle) * radius)
	if is_instance_valid(WorldTerrain.instance):
		var ground: float = WorldTerrain.instance.height_at(at)
		if is_finite(ground): at.y = maxf(at.y, ground + 1.0)
	emitter.global_position = at
	emitter.stream = streams[selected]
	emitter.pitch_scale = rng.randf_range(0.94, 1.06)
	var db := linear_to_db(float(rec.gain)) - 9.0 + rng.randf_range(-3.0, 1.0)
	emitter.set_meta("base_db", db)
	emitter.volume_db = db + linear_to_db(maxf(gain, 0.0001))
	emitter.play()
	return true
