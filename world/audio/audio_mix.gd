extends RefCounted
## Dedicated world buses preserve settings sliders and leave speech/UI untouched.
const ROUTES := {"WorldSFX": "SFX", "WorldAmbience": "Ambience", "Wind": "WorldAmbience"}
var _filters: Array[AudioEffectLowPassFilter] = []
var _reverbs: Array[AudioEffectReverb] = []
var _ambience_bus := -1
var _voice_bus := -1
var _indoor := 0.0
var _underwater := 0.0
var _duck_db := 0.0
var _peak_clock := 0.0
var _voice_hold := 0.0

static func ensure_buses() -> void:
	for bus: String in ROUTES:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.get_bus_count() - 1, bus)
		AudioServer.set_bus_send(AudioServer.get_bus_index(bus), ROUTES[bus])

func setup() -> void:
	ensure_buses()
	_ambience_bus = AudioServer.get_bus_index("WorldAmbience")
	_voice_bus = AudioServer.get_bus_index("Voice")
	for bus: String in ["WorldSFX", "WorldAmbience"]:
		var index: int = AudioServer.get_bus_index(bus)
		# Reuse our own effects after a scoped mixer is replaced.
		var filter: AudioEffectLowPassFilter
		var reverb: AudioEffectReverb
		for i in AudioServer.get_bus_effect_count(index):
			var effect: AudioEffect = AudioServer.get_bus_effect(index, i)
			if effect is AudioEffectLowPassFilter: filter = effect
			elif effect is AudioEffectReverb: reverb = effect
		if filter == null:
			filter = AudioEffectLowPassFilter.new(); filter.cutoff_hz = 18000.0
			filter.resonance = .1
			AudioServer.add_bus_effect(index, filter)
		if reverb == null:
			reverb = AudioEffectReverb.new(); reverb.wet = 0.0; reverb.dry = 1.0
			reverb.room_size = .35; reverb.damping = .65
			AudioServer.add_bus_effect(index, reverb)
		_filters.append(filter); _reverbs.append(reverb)
	reset()

func step(delta: float, indoor: float, underwater: float, foreground: bool) -> void:
	var blend: float = 1.0 - exp(-maxf(delta, 0.0) * 5.0)
	_indoor = lerpf(_indoor, indoor, blend)
	_underwater = lerpf(_underwater, underwater, blend)
	_peak_clock -= delta
	_voice_hold = maxf(_voice_hold - delta, 0.0)
	if _peak_clock <= 0.0:
		_peak_clock = .1
		if _voice_bus >= 0 and not AudioServer.is_bus_mute(_voice_bus):
			var peak: float = maxf(AudioServer.get_bus_peak_volume_left_db(_voice_bus, 0), AudioServer.get_bus_peak_volume_right_db(_voice_bus, 0))
			if peak > -48.0: _voice_hold = .35
	var target_db: float = -7.0 if foreground or _voice_hold > 0.0 else 0.0
	_duck_db = lerpf(_duck_db, target_db, 1.0 - exp(-delta * (12.0 if target_db < _duck_db else 2.5)))
	if _ambience_bus >= 0: AudioServer.set_bus_volume_db(_ambience_bus, _duck_db)
	var cutoff: float = lerpf(lerpf(18000.0, 12500.0, _indoor), 850.0, _underwater)
	var wet: float = lerpf(_indoor * .085, .025, _underwater)
	for filter: AudioEffectLowPassFilter in _filters: filter.cutoff_hz = cutoff
	for reverb: AudioEffectReverb in _reverbs: reverb.wet = wet

func reset() -> void:
	_indoor = 0.0; _underwater = 0.0; _duck_db = 0.0; _voice_hold = 0.0
	if _ambience_bus >= 0: AudioServer.set_bus_volume_db(_ambience_bus, 0.0)
	for filter: AudioEffectLowPassFilter in _filters: filter.cutoff_hz = 18000.0
	for reverb: AudioEffectReverb in _reverbs: reverb.wet = 0.0
