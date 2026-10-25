extends Node3D
## Foley and ambience: wind, a daytime forest bed, night crickets, birds
## calling from nearby tree canopies, and footsteps for the player and hoofsteps
## for ponies. Sources and local exceptions: THIRD_PARTY.md, "Sounds".
##
## Beds follow TimeOfDay. Birds choose real loaded trees before each call and
## stay at that canopy until finished; treeless ground stays quiet.
## Footsteps come from whoever reports a
## step (`connect_stepper`), else from listener travel distance, which is
## what the desktop rig needs.

const WIND := preload("res://world/audio/designed/environment/breeze.ogg")
const FOREST_DAY := preload("res://world/audio/ambience/forest_day.ogg")
const CRICKETS := preload("res://world/audio/ambience/crickets.mp3")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const CATALOGUE := preload("res://world/audio/environment_catalogue.gd")
const CONTACT := preload("res://world/audio/ground_contact_audio.gd")
const MOVEMENT := preload("res://world/audio/player_movement_audio.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
const WATER_MASK := 1 << 15
const BIRD_COUNT := 10

@export var wind_db := -30.0
@export var wind_quiet_seconds := Vector2(90.0, 180.0)
@export var wind_gust_seconds := Vector2(8.0, 14.0)
@export var forest_db := -18.0
@export var crickets_db := -14.0
@export var bird_db := -22.0
@export var footstep_db := -13.0
@export var min_footstep_gap := 0.45
var _last_footstep := -10.0
@export var hoofstep_db := -16.0
## Metres of listener travel per footstep when nobody reports real steps.
@export var stride := 0.72

var listener: Node3D
## Cached acoustic context, also read by Weather; actual room bounds and door state own shelter.
var room: Node3D
var outdoor_gain := 1.0
var underwater := 0.0
var _water_view: Node
var _context_timer := 0.0
var _weather: Node
var _movement: Node
var _player_pony: WeakRef
var _water_host: Node3D
var _water_handle := 0
var _water_at := Vector3.INF
var _water_search := 0.0
var _creak_wait := 120.0
var _wind: AudioStreamPlayer
var _forest: AudioStreamPlayer3D
var _forest_host: Node3D
var _forest_gain := 0.0
var _forest_search := 0.0
var _crickets: AudioStreamPlayer
var _birds: Array[AudioStreamPlayer3D] = []
var _bird_clips: Array[AudioStream] = []
var _wind_wait := 0.0
var _wind_elapsed := 0.0
var _wind_duration := 0.0
var _biome_timer := 0.0
var _biome_gains := Vector3.ONE
var _biome_target := Vector3.ONE
var _bird_hosts: Dictionary = {}
var _bird_levels: Dictionary = {}
var _has_stepper := false
var _last_listener := Vector3.INF
var _travel := 0.0
var _rng := RandomNumberGenerator.new()
# Resolved at runtime so headless tests without the autoload table still load.
var _tod: Node


func _ready() -> void:
	_rng.randomize()
	SOUNDS.register_catalogue(self, CATALOGUE.EVENTS)
	_tod = get_node_or_null("/root/TimeOfDay")
	for i in range(1, BIRD_COUNT + 1):
		_bird_clips.append(load("res://world/audio/birds/bird_%02d.ogg" % i))
	_wind = AudioStreamPlayer.new()
	_wind.bus = "Wind" if AudioServer.get_bus_index("Wind") >= 0 else "Ambience" if AudioServer.get_bus_index("Ambience") >= 0 else "Master"
	_wind.stream = WIND.duplicate()
	(_wind.stream as AudioStreamOggVorbis).loop = true
	_wind.volume_db = -80.0; add_child(_wind)
	_wind_wait = _rng.randf_range(wind_quiet_seconds.x, wind_quiet_seconds.y)
	# This recording contains birds: it needs a real canopy, just like solo calls.
	_forest = AudioStreamPlayer3D.new()
	_forest.bus = "WorldAmbience" if AudioServer.get_bus_index("WorldAmbience") >= 0 else "Ambience" if AudioServer.get_bus_index("Ambience") >= 0 else "Master"
	_forest.stream = FOREST_DAY.duplicate()
	(_forest.stream as AudioStreamOggVorbis).loop = true
	_forest.max_distance = 90.0; _forest.unit_size = 20.0
	_forest.volume_db = -80.0; add_child(_forest)
	_crickets = _bed(CRICKETS, crickets_db)
	# One distant bird, a call or two every three to four minutes (dev,
	# 2026-09-06, after a first pass that chirped without pause).
	for i in 1:
		var bird := AudioStreamPlayer3D.new()
		bird.bus = _forest.bus
		bird.volume_db = bird_db
		bird.max_distance = 90.0
		bird.unit_size = 12.0
		bird.attenuation_filter_cutoff_hz = 9000.0
		add_child(bird)
		_birds.append(bird)
		var timer := Timer.new()
		timer.name = "CallTimer"; timer.one_shot = true
		bird.add_child(timer)
		timer.timeout.connect(_play_bird.bind(bird))
		bird.finished.connect(_schedule_bird.bind(bird))
		_schedule_bird(bird)
	_creak_wait = _rng.randf_range(120.0, 300.0)


## Composition-root hook: observes the existing motor, never creates another movement owner.
func setup(body: CharacterBody3D, camera: Node3D) -> void:
	listener = camera
	if body == null: return
	if not is_instance_valid(_movement):
		_movement = MOVEMENT.new()
		_movement.name = "MovementAudio"
		add_child(_movement)
	_movement.setup(body, self)


func _bed(stream: AudioStream, _db: float) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.bus = _forest.bus
	player.stream = stream.duplicate()
	# Startup may precede the first time-of-day/context update; never leak a full-volume bed.
	player.volume_db = -80.0
	if player.stream is AudioStreamOggVorbis:
		(player.stream as AudioStreamOggVorbis).loop = true
	elif player.stream is AudioStreamMP3:
		(player.stream as AudioStreamMP3).loop = true
	add_child(player)
	player.play(_rng.randf() * 5.0)
	return player


## Anyone with a `stepped(world_position: Vector3)` signal: Anon's body.
func connect_stepper(node: Node) -> void:
	if node != null and node.has_signal("stepped"):
		if not node.is_connected("stepped", play_footstep): node.connect("stepped", play_footstep)
		_has_stepper = true


## Anyone with a `hoof_planted(world_position: Vector3)` signal: the mare.
func connect_pony(node: Node) -> void:
	if node != null and node.has_signal("hoof_planted"):
		var contact := _pony_contact.bind(node)
		if not node.is_connected("hoof_planted", contact): node.connect("hoof_planted", contact)
	if node != null and node.has_signal("audio_jumped"):
		var jumped := _pony_jump.bind(node)
		if not node.is_connected("audio_jumped", jumped): node.connect("audio_jumped", jumped)
	if node != null and node.has_signal("audio_landed"):
		var landed := _pony_land.bind(node)
		if not node.is_connected("audio_landed", landed): node.connect("audio_landed", landed)


## The player's own pony (player/pony_form.gd): her real hoofsteps replace the footsteps
## synthesised from listener travel.
func connect_player_pony(node: Node) -> void:
	connect_pony(node)
	if node != null and node.has_signal("hoof_planted"):
		_has_stepper = true
		_player_pony = weakref(node)
		# Actual pony motor signals replace the human observer. No polling of NPC rigs.
		if is_instance_valid(_movement): _movement.set_physics_process(false)


func _process(delta: float) -> void:
	var daylight := _daylight()
	_context_timer -= delta
	if _context_timer <= 0.0:
		_context_timer = .35
		_update_context()
		_update_water(.35)
	# Head immersion already has a camera-owned blend; reuse it without waiting for a room scan.
	if is_instance_valid(_water_view):
		var head_gain := clampf(float(_water_view.get("immersion")), 0.0, 1.0)
		if absf(head_gain-underwater) >= .01:
			underwater = head_gain
			SOUNDS.set_listener_context(self, 1.0-outdoor_gain, underwater)
	_biome_timer -= delta
	if _biome_timer <= 0.0 and is_instance_valid(listener) and is_instance_valid(WorldTerrain.instance):
		_biome_timer = 0.5
		var field: WorldBiomeField = WorldTerrain.instance.biomes
		var w := field.sample_weights(Vector2(listener.global_position.x, listener.global_position.z))
		_biome_target = Vector3.ZERO
		for i in w.size():
			var p: Dictionary = field.presets[i]
			_biome_target += Vector3(float(p.wind_gain), float(p.forest_gain), float(p.cricket_gain)) * w[i]
	_biome_gains = _biome_gains.lerp(_biome_target, 1.0 - exp(-delta / 2.0))
	_update_wind(delta, daylight)
	_update_forest(delta, daylight)
	var night_gain := (1.0 - smoothstep(.05, .4, daylight)) * _biome_gains.z * outdoor_gain * (1.0 - underwater)
	if is_instance_valid(_weather) and str(_weather.get("season")) == "winter": night_gain = 0.0
	_crickets.volume_db = crickets_db + linear_to_db(maxf(night_gain, .00001))
	if night_gain <= .005 and _crickets.playing: _crickets.stop()
	elif night_gain > .005 and not _crickets.playing: _crickets.play(_rng.randf() * 5.0)
	_update_creak(delta)
	if listener == null:
		return
	# Do not drag a singing bird along with the listener or leave a call in empty
	# space when streaming/painting removes its tree. Its next call picks anew.
	for bird in _birds:
		if not bird.playing: continue
		var host: Variant = _bird_hosts.get(bird)
		if not is_instance_valid(host) or not host.is_visible_in_tree():
			bird.stop(); _bird_hosts.erase(bird); _schedule_bird(bird)
		else:
			bird.volume_db = float(_bird_levels.get(bird, bird_db)) + linear_to_db(maxf(outdoor_gain * (1.0-underwater), .00001))
	if not _has_stepper:
		var flat := Vector3(listener.global_position.x, 0.0, listener.global_position.z)
		if _last_listener.is_finite():
			var distance := flat.distance_to(_last_listener)
			var grounded: bool = is_instance_valid(_movement) and is_instance_valid(_movement.body) and bool(_movement.body.is_on_floor())
			if not grounded or distance > maxf(.75, delta * 25.0): _travel = 0.0
			else: _travel += distance
			if _travel >= stride:
				_travel = 0.0
				play_footstep(_movement.body.global_position)
		_last_listener = flat


func _update_wind(delta: float, daylight: float) -> void:
	if not _wind.playing:
		_wind_wait -= delta
		if _wind_wait > 0.0: return
		_wind_duration = maxf(1.0, _rng.randf_range(wind_gust_seconds.x, wind_gust_seconds.y))
		_wind_elapsed = 0.0
		_wind.volume_db = -80.0
		_wind.play(_rng.randf_range(0.0, maxf(0.0, _wind.stream.get_length()-_wind_duration)))
		return
	_wind_elapsed += delta
	if _wind_elapsed >= _wind_duration:
		_wind.stop()
		_wind_wait = _rng.randf_range(wind_quiet_seconds.x, wind_quiet_seconds.y)
		return
	var fade := minf(2.0, _wind_duration*.25)
	var envelope := smoothstep(0.0, fade, _wind_elapsed) * smoothstep(0.0, fade, _wind_duration-_wind_elapsed)
	# A quiet air/leaf bed, softer after dark; no repeating pitched whoosh.
	_wind.volume_db = wind_db - (1.0-daylight)*2.0 + linear_to_db(maxf(envelope*_biome_gains.x*outdoor_gain*(1.0-underwater), .00001))


func _daylight() -> float:
	return float(_tod.call("daylight")) if _tod != null and _tod.has_method("daylight") else 1.0


func _update_forest(delta: float, daylight: float) -> void:
	var origin: Vector3 = listener.global_position if is_instance_valid(listener) else global_position
	var present := is_instance_valid(_forest_host) and _forest_host.is_visible_in_tree()
	var near := present and origin.distance_to(_forest.global_position) <= 80.0
	# Fade to silence before moving the continuous bed to a different tree.
	# A removed tree stops immediately; ordinary listener travel gets a soft fade.
	_forest_gain = move_toward(_forest_gain, 1.0 if near else 0.0, delta / (2.0 if near else .75)) if present else 0.0
	if _forest_gain <= 0.0 and not near:
		_forest.stop(); _forest_host = null
		_forest_search -= delta
		if _forest_search <= 0.0:
			_forest_search = 2.0
			var perch := _bird_perch()
			if not perch.is_empty():
				_forest_host = perch.owner; _forest.global_position = perch.position
				_forest.play(_rng.randf() * 5.0)
	var weather_gain := 1.0
	if is_instance_valid(_weather):
		var weather_params: Dictionary = _weather.get("params")
		weather_gain = 1.0 - float(weather_params.get("rain", 0.0)) * .8
	_forest.volume_db = forest_db + linear_to_db(maxf(daylight * _biome_gains.y * _forest_gain * outdoor_gain * (1.0-underwater) * weather_gain, .00001))


func _bird_perch() -> Dictionary:
	var origin: Vector3 = listener.global_position if is_instance_valid(listener) else global_position
	var perches: Array = []
	for habitat in get_tree().get_nodes_in_group("bird_habitats"):
		perches.append_array(habitat.bird_perches(origin))
	return perches[_rng.randi_range(0, perches.size() - 1)] if not perches.is_empty() else {}


func _schedule_bird(bird: AudioStreamPlayer3D) -> void:
	# Quiet gaps between calls; fewer and quieter as the light goes.
	var daylight := _daylight()
	var gap := _rng.randf_range(100.0, 240.0) + (1.0 - daylight) * 300.0
	# Owned by the emitter, so unloading the world also cancels its future call.
	(bird.get_node("CallTimer") as Timer).start(gap)


func _play_bird(bird: AudioStreamPlayer3D) -> void:
	if bird.playing: return
	var now := _daylight()
	if now < 0.08 or underwater > .5:
		_schedule_bird(bird)
		return
	var perch := _bird_perch()
	if perch.is_empty():
		_schedule_bird(bird)
		return
	_bird_hosts[bird] = perch.owner
	bird.global_position = perch.position
	bird.stream = _bird_clips[_rng.randi_range(0, _bird_clips.size() - 1)]
	bird.pitch_scale = _rng.randf_range(0.92, 1.1)
	_bird_levels[bird] = bird_db + linear_to_db(clampf(now, .2, 1.0)) + _rng.randf_range(-4.0, 0.0)
	bird.volume_db = float(_bird_levels[bird]) + linear_to_db(maxf(outdoor_gain * (1.0-underwater), .00001))
	bird.play()


func play_footstep(world_position: Vector3) -> void:
	if _player_pony != null and is_instance_valid(_player_pony.get_ref()): return
	# Never two footsteps closer than this, whatever reports them (dev,
	# 2026-09-07: "more delayed in between each footstep").
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_footstep < min_footstep_gap:
		return
	_last_footstep = now
	# Crouched or seated players step softly: the lower the ears are above
	# the foot, the quieter (dev, 2026-09-07).
	var db := footstep_db
	if listener != null:
		var ear_height := listener.global_position.y - world_position.y
		db -= 8.0 * clampf((1.5 - ear_height) / 0.6, 0.0, 1.0)
	_play_contact(self, "env_footstep", world_position, 1.0, db - footstep_db)


func play_hoofstep(world_position: Vector3) -> void:
	_play_contact(self, "env_hoofstep", world_position)


func _pony_contact(at: Vector3, source: Node3D) -> void:
	# Gait feel: a walk lands softer than a trot, a gallop a little louder, and no two hooves
	# land quite alike (the cue's pitch range varies the rest).
	var moving: Variant = source.get("actual_speed")
	var size: Variant = source.get("body_scale")
	var speed := (float(moving) if moving is float else 0.0) / maxf(float(size) if size is float else 1.0, .2)
	var db := _rng.randf_range(-1.5, 1.0) + (1.5 if speed >= 3.2 else 0.0)
	_play_contact(source, "env_hoofstep", at, clampf(.62 + .12 * speed, .62, 1.0), db)


func _pony_jump(at: Vector3, source: Node3D) -> void:
	# Bare ponies have a hoof push-off, not a human clothing rustle.
	_play_contact(source, "env_hoofstep", at, .55)


func _pony_land(at: Vector3, speed: float, source: Node3D) -> void:
	play_landing(source, at, speed, true)


func play_jump(source: Node3D, at: Vector3) -> void:
	if _near(at, 6.0): SOUNDS.play_event(source, "env_jump", {}, at)


func play_landing(source: Node3D, at: Vector3, speed: float, pony := false) -> void:
	if not is_finite(speed) or speed < 1.2: return
	_play_contact(source, "env_hoof_land" if pony else "env_land", at, clampf(speed / 5.0, .25, 1.0))
	if not pony: _last_footstep = Time.get_ticks_msec() * .001


func _near(at: Vector3, distance: float) -> bool:
	return at.is_finite() and (not is_instance_valid(listener) or listener.global_position.distance_squared_to(at) <= distance * distance)


func _play_contact(source: Node3D, event: String, at: Vector3, intensity := 1.0, db := 0.0) -> void:
	if not is_instance_valid(source) or not _near(at, 18.0): return
	var kind := CONTACT.material(source, at, _weather)
	if kind.is_empty(): return # No support: air, load-in and teleport contacts stay silent.
	if kind == "water": event = "env_hoof_wade" if event == "env_hoofstep" else "env_wade"
	var occlusion := 0.0
	if is_instance_valid(room) and HOUSE.at(get_tree(), at + Vector3.UP * .02) != room: occlusion = 1.0 - outdoor_gain
	SOUNDS.play_event(source, event, {"material": kind, "intensity": intensity, "volume_db": db, "occlusion": occlusion}, at)


func _update_context() -> void:
	if not is_instance_valid(listener) or not listener.global_position.is_finite(): return
	room = null
	for home: Node3D in get_tree().get_nodes_in_group("house_interiors"):
		if home.global_position.distance_squared_to(listener.global_position) > float(home.call("_reach_squared")): continue
		if bool(home.call("contains", listener.global_position, true)):
			room = home
			break
	outdoor_gain = 1.0
	if is_instance_valid(room):
		var door: Node = room.call("door") if room.has_method("door") else null
		var opened := is_instance_valid(door) and door.has_method("opening_angle") and absf(float(door.call("opening_angle"))) > .3
		outdoor_gain = .45 if opened else .12
	_water_view = listener.get_node_or_null("PlayerWaterView")
	underwater = clampf(float(_water_view.get("immersion")), 0.0, 1.0) if is_instance_valid(_water_view) else 0.0
	SOUNDS.set_listener_context(self, 1.0 - outdoor_gain, underwater)
	if not is_instance_valid(_weather): _weather = get_tree().get_first_node_in_group("weather")


func _update_creak(delta: float) -> void:
	_creak_wait -= delta
	if _creak_wait > 0.0: return
	_creak_wait = _rng.randf_range(120.0, 300.0)
	if not is_instance_valid(_weather) or underwater > .1: return
	var weather_params: Dictionary = _weather.get("params")
	if float(weather_params.get("gust", 0.0)) < .35: return
	var perch := _bird_perch()
	if not perch.is_empty(): SOUNDS.play_event(perch.owner, "env_tree_creak", {"intensity": outdoor_gain}, perch.position)


func _update_water(delta: float) -> void:
	if not is_instance_valid(listener): return
	_water_search -= delta
	if _water_search <= 0.0:
		_water_search = 1.05
		var found := _nearest_water(listener.global_position)
		var host: Node3D = found.get("owner") as Node3D
		if host != _water_host:
			if is_instance_valid(_water_host) and _water_handle != 0: SOUNDS.stop_loop(_water_host, _water_handle)
			_water_host = host
			_water_handle = 0
		_water_at = found.get("position", Vector3.INF)
	if not is_instance_valid(_water_host) or not _water_host.is_inside_tree() or not _water_at.is_finite(): return
	var gain := outdoor_gain * (1.0 - underwater * .9)
	if _water_handle == 0: _water_handle = SOUNDS.start_loop(_water_host, "env_water_edge", {"intensity": gain})
	if _water_handle != 0 and not SOUNDS.update_loop(_water_host, _water_handle, {"intensity": gain}, _water_at): _water_handle = 0


func _nearest_water(origin: Vector3) -> Dictionary:
	var candidates: Array[Dictionary] = []
	for node: Node in get_tree().get_nodes_in_group("navigation_water"):
		var mesh := node as MeshInstance3D
		# The FFT preset hides the classic sea mesh but retains its physical surface.
		if mesh == null or mesh.mesh == null or not mesh.is_inside_tree() or mesh.is_queued_for_deletion(): continue
		var bounds: AABB = mesh.global_transform * mesh.get_aabb()
		var at := Vector3(clampf(origin.x, bounds.position.x + .02, bounds.end.x - .02), bounds.get_center().y,
			clampf(origin.z, bounds.position.z + .02, bounds.end.z - .02))
		var distance := origin.distance_squared_to(at)
		if distance < 28.0 * 28.0: candidates.append({"owner": mesh, "position": at, "distance": distance})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.distance) < float(b.distance))
	# Bounds alone can contain a dry island or bend; confirm actual loaded water collision.
	# At most two rays once a second, independent of emitter/pony count.
	var space := get_world_3d().direct_space_state
	for i in mini(candidates.size(), 2):
		var at: Vector3 = candidates[i].position
		var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 2.0, at - Vector3.UP * 3.0, WATER_MASK)
		ray.hit_back_faces = true
		var hit: Dictionary = space.intersect_ray(ray)
		if not hit.is_empty():
			var point: Vector3 = hit.position
			# The world's sea plane extends under dry land; buried water is not shoreline.
			# Terrain's existing height cache avoids another acoustic ray or collider scan.
			if is_instance_valid(WorldTerrain.instance):
				var ground: float = WorldTerrain.instance.height_at(point)
				if is_finite(ground) and ground > point.y + .12: continue
			return {"owner": candidates[i].owner, "position": point}
	return {}
