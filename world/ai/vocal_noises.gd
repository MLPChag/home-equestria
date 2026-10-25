extends Node
## Small non-word voice sounds per character (dev 2026-09-28): soft "mm" noises during a deep
## kiss and a quiet breathy laugh after being flustered. Kept rare and far under dialogue; the
## first perky "Teehee!" lines sounded cartoony ("they sound really stupid like TEE HEE"). Each is a short line from the pony's own TTS voice,
## generated in the background the first time she is touched, then kept on disk. Dialogue
## always has the voice server first: a clip is requested only while the director's TTS is idle.
## No voice server, ponese voices or voice off: nothing is generated and nothing plays.
const TTS := preload("res://world/ai/tts_client.gd")
const CHATTER := preload("res://world/ai/chatter_voice.gd")
const DIR := "user://voice_noises"
const LINES := {
	"m": ["Mm.", "Mmh.", "Hm."],
	"laugh": ["Heh.", "Hm, heh."],
}
## Calm and whispered, not the perky "happy" style.
const EMOTIONS := {"m": "calm", "laugh": "whispering"}
## Fillies only ever laugh.
const ADULT_ONLY := ["m"]
var director: Node
var _tts: Node
var _queue: Array[Dictionary] = []
var _queued: Dictionary = {}
var _clips: Dictionary = {} # "<id>/<kind>" -> Array[AudioStreamWAV]
var _players: Dictionary = {} # id -> AudioStreamPlayer3D

func setup(owner_director: Node) -> void:
	director = owner_director
	_tts = TTS.new()
	_tts.name = "NoiseTts"
	_tts.output_dir = DIR + "/incoming"
	add_child(_tts)

func configure(section: Dictionary) -> void:
	_tts.configure(section)
	_clips.clear()

## Queue any missing clips for this pony. Cheap to call on every touch.
func prepare(id: String) -> void:
	var profile := _profile(id)
	if profile.is_empty() or not _voiced(profile): return
	for kind: String in LINES:
		if kind in ADULT_ONLY and _filly(id): continue
		var folder := _folder(id, profile, kind)
		for i in LINES[kind].size():
			var path := "%s/%d.wav" % [folder, i]
			if FileAccess.file_exists(path) or _queued.has(path): continue
			_queued[path] = true
			_queue.append({"id": id, "kind": kind, "text": LINES[kind][i], "path": path, "profile": profile})

## Play one cached clip of `kind` from her mouth. False when none is ready yet.
func play(id: String, kind: String, at: Node3D, volume_db := -30.0) -> bool:
	if kind in ADULT_ONLY and _filly(id): return false
	var profile := _profile(id)
	if profile.is_empty() or not _voiced(profile): return false
	var key := id + "/" + kind
	if not _clips.has(key):
		var loaded: Array[AudioStreamWAV] = []
		var folder := _folder(id, profile, kind)
		for i in LINES[kind].size():
			var path := "%s/%d.wav" % [folder, i]
			if FileAccess.file_exists(path):
				var stream := AudioStreamWAV.load_from_file(ProjectSettings.globalize_path(path))
				if stream != null: loaded.append(stream)
		if loaded.size() < LINES[kind].size(): prepare(id)
		if loaded.is_empty(): return false
		_clips[key] = loaded
	var player: AudioStreamPlayer3D = _players.get(id)
	if not is_instance_valid(player) or player.get_parent() != at:
		if is_instance_valid(player): player.queue_free()
		player = AudioStreamPlayer3D.new()
		player.bus = "Voice" if AudioServer.get_bus_index("Voice") >= 0 else ("SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master")
		player.max_distance = 6.0; player.unit_size = 1.0
		at.add_child(player)
		_players[id] = player
	if player.playing: return true
	player.stream = (_clips[key] as Array).pick_random()
	player.volume_db = volume_db
	player.pitch_scale = randf_range(.97, 1.04)
	player.play()
	return true

func _process(_delta: float) -> void:
	if _queue.is_empty() or _tts.busy: return
	# Spoken dialogue first: never compete with a line being voiced.
	if is_instance_valid(director) and (director.tts.busy or director.state != "idle"): return
	var job: Dictionary = _queue.pop_front()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(str(job.path).get_base_dir()))
	var profile: Dictionary = job.profile
	var started: bool = _tts.synthesize(job.text, int(profile.get("tts_speaker_id", 31)), str(EMOTIONS.get(job.kind, "calm")),
		_saved.bind(job), str(profile.get("openai_voice", "")))
	if not started: _queued.erase(job.path)

func _saved(path: String, error: String, job: Dictionary) -> void:
	_queued.erase(job.path)
	if not error.is_empty() or path.is_empty():
		if director != null and director.debug: print("[voice-noise] ", job.id, " ", job.kind, " failed: ", error.left(80))
		return
	DirAccess.rename_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(job.path))
	_clips.erase(str(job.id) + "/" + str(job.kind))

func _profile(id: String) -> Dictionary:
	if not is_instance_valid(director) or not director.characters.has(id): return {}
	return director.characters[id].profile

func _filly(id: String) -> bool:
	var node: Variant = director.characters[id].node if director.characters.has(id) else null
	return not is_instance_valid(node) or bool(node.identity.filly)

func _voiced(profile: Dictionary) -> bool:
	var settings: Node = get_node_or_null("/root/Settings")
	if settings != null and settings.has_method("tts_enabled") and not settings.tts_enabled(): return false
	if not _tts.has_server() or CHATTER.is_ponese_mode(_tts.voice_mode): return false
	var openai_voiced: bool = _tts.provider == "openai" and profile.has("openai_voice")
	return openai_voiced or not CHATTER.use_chatter(profile, _tts.voice_mode)

## One folder per voice and per set of lines, so changing a pony's voice, the server or these
## lines makes fresh clips.
func _folder(id: String, profile: Dictionary, kind: String) -> String:
	var voice := [_tts.provider, _tts.url, _tts.remote_url, _tts.model, int(profile.get("tts_speaker_id", 31)), str(profile.get("openai_voice", ""))]
	return "%s/%s/%s/%s-%s" % [DIR, id, str(hash(voice)), kind, str(hash([LINES[kind], EMOTIONS.get(kind, "")]))]
