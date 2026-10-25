extends RefCounted
## Sounds of Trixie's show (interaction_sounds.gd catalogue). CC0 recordings, converted and
## loudness-matched; sources and licences: archive/trixie-show-sounds-2026-10-16/.
const BURSTS := [preload("res://world/events/trixie_show/sounds/firework_burst_01.ogg"), preload("res://world/events/trixie_show/sounds/firework_burst_02.ogg"),
	preload("res://world/events/trixie_show/sounds/firework_burst_03.ogg"), preload("res://world/events/trixie_show/sounds/firework_burst_04.ogg"),
	preload("res://world/events/trixie_show/sounds/firework_burst_05.ogg"), preload("res://world/events/trixie_show/sounds/firework_burst_06.ogg")]
const BOOMS := [preload("res://world/events/trixie_show/sounds/cannon_boom_01.ogg"), preload("res://world/events/trixie_show/sounds/cannon_boom_02.ogg"),
	preload("res://world/events/trixie_show/sounds/cannon_boom_03.ogg")]
const EVENTS := {
	"show_firework": {"streams": BURSTS, "volume_db": -8.0, "distance": 90.0, "priority": 2, "concurrency": 4, "pitch_min": .9, "pitch_max": 1.1},
	"show_boom": {"streams": BOOMS, "volume_db": -9.0, "distance": 70.0, "priority": 2, "concurrency": 2, "pitch_min": .95, "pitch_max": 1.05},
	"show_crackle": {"streams": [preload("res://world/events/trixie_show/sounds/firework_crackle_loop.ogg")], "volume_db": -14.0, "distance": 80.0, "priority": 1, "concurrency": 1},
	"show_applause": {"streams": [preload("res://world/events/trixie_show/sounds/applause_01.ogg")], "volume_db": -10.0, "distance": 40.0, "priority": 2, "concurrency": 2, "cooldown": 1.5, "pitch_min": .96, "pitch_max": 1.04},
	"show_whoosh": {"streams": [preload("res://world/audio/designed/flight/takeoff.res")], "volume_db": -16.0, "distance": 40.0, "priority": 1, "concurrency": 3, "pitch_min": 1.2, "pitch_max": 1.5},
	"show_wings": {"streams": [preload("res://world/audio/designed/flight/wing_01.res"), preload("res://world/audio/designed/flight/wing_02.res"), preload("res://world/audio/designed/flight/wing_03.res")],
		"volume_db": -14.0, "distance": 25.0, "priority": 1, "concurrency": 3, "cooldown": .08, "pitch_min": 1.5, "pitch_max": 1.9},
}

static func register(source: Node) -> void:
	preload("res://world/audio/interaction_sounds.gd").register_catalogue(source, EVENTS)
