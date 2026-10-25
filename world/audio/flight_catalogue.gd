extends RefCounted
## Recorded CC0 sources/processing evidence: FEATURE_07_FLIGHT_SOUND_2026_10_13.md.
const WINGS := [preload("res://world/audio/designed/flight/wing_01.res"), preload("res://world/audio/designed/flight/wing_02.res"), preload("res://world/audio/designed/flight/wing_03.res")]
const EVENTS := {
	"flight_air_soft": {"streams": [preload("res://world/audio/designed/flight/air_soft.res")], "loop": true, "spatial": false, "bus": "Wind", "volume_db": -24.0, "priority": 3, "distance": 8.0, "concurrency": 1},
	"flight_air_rush": {"streams": [preload("res://world/audio/designed/flight/air_rush.res")], "loop": true, "spatial": false, "bus": "Wind", "volume_db": -24.0, "priority": 3, "distance": 8.0, "concurrency": 1},
	"flight_wing_self": {"streams": WINGS, "spatial": false, "bus": "SFX", "volume_db": -17.0, "priority": 3, "distance": 8.0, "concurrency": 2, "cooldown": .11, "pitch_min": .97, "pitch_max": 1.03},
	"flight_takeoff": {"streams": [preload("res://world/audio/designed/flight/takeoff.res")], "spatial": false, "bus": "SFX", "volume_db": -21.0, "priority": 3, "distance": 8.0, "cooldown": .7},
	"flight_fold": {"streams": [preload("res://world/audio/designed/flight/fold.res")], "spatial": false, "bus": "SFX", "volume_db": -23.0, "priority": 3, "distance": 8.0, "cooldown": .4},
	"flight_wing_nearby": {"streams": WINGS, "bus": "SFX", "volume_db": -17.0, "priority": 1, "distance": 28.0, "concurrency": 2, "cooldown": .14},
	"flight_passby": {"streams": [preload("res://world/audio/designed/flight/air_pass.res")], "loop": true, "bus": "Wind", "volume_db": -18.0, "priority": 1, "distance": 28.0, "concurrency": 2},
}
