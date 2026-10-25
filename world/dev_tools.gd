extends RefCounted
## Developer tools gate (dev 2026-10-20: player builds show no debug or dev tools). Player
## exports carry the "player_build" feature (tools/build/make_export_presets.py): no command
## console, noclip, weather/visit keys, profilers or developer launch flags. Editor runs, dev
## launches and tester builds keep everything. The plain FPS counter and quick saves stay.

## Launch arguments a player may pass (launchers, VR restart, seated play).
const PLAYER_ARGS := ["--require-vr", "--seated", "--room-scale"]


static func enabled() -> bool:
	return not OS.has_feature("player_build")


## Exported debug builds for testers (dev 2026-10-20: "debug build so he can get all his ai
## logs ... optimize token usage") record full AI traffic without launch flags: the same as
## `-- --ai-trace-full`. The editor and release exports do not.
static func tester_capture() -> bool:
	return enabled() and OS.has_feature("template") and OS.is_debug_build()


## Game arguments after "--". Player builds keep only PLAYER_ARGS.
static func user_args() -> PackedStringArray:
	var args := OS.get_cmdline_user_args()
	if enabled(): return args
	var kept := PackedStringArray()
	for arg in args:
		if arg in PLAYER_ARGS: kept.append(arg)
	return kept
