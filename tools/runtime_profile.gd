extends Node
## Opt-in sampling of the actual game, including its rig, character and XR wait.
## All samples stay in memory until the run ends; screenshots are taken afterward.

const COUNTERS := {
	"mesh": Performance.PIPELINE_COMPILATIONS_MESH,
	"surface": Performance.PIPELINE_COMPILATIONS_SURFACE,
	"draw": Performance.PIPELINE_COMPILATIONS_DRAW,
	"specialization": Performance.PIPELINE_COMPILATIONS_SPECIALIZATION,
}
const CPU_SCOPES := preload("res://tools/crowd_cpu_profile.gd")
signal completed
var keep_open:=false
var _rows: Array[Dictionary] = []
var _start := 0
var _last := 0
var _ready_at := 0
var _duration := 30.0
var _out := "res://captures/performance/runtime.json"
var _initial_counters := {}
var _metadata := {}
var _finishing := false
var _transition_frame := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	CPU_SCOPES.enabled=true
	_duration = clampf(float(_arg(args, "--profile-seconds", "30")), 2.0, 300.0)
	_out = _arg(args, "--profile-out", _out)
	_initial_counters = counters()
	_start = Time.get_ticks_usec()
	_last = _start
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	RenderingServer.frame_post_draw.connect(_sample)


func begin(game: Node) -> void:
	CPU_SCOPES.reset()
	_ready_at = Time.get_ticks_usec()
	_transition_frame = true
	var interface := XRServer.find_interface("OpenXR")
	var xr: bool = game.xr_active and interface != null and interface.is_initialized() and get_viewport().use_xr
	_metadata = {
		"schema": 1, "when": Time.get_datetime_string_from_system(true),
		"mode": "openxr_multiview" if xr else "desktop_mono",
		"gpu": RenderingServer.get_video_adapter_name(), "engine": Engine.get_version_info(),
		"viewport": var_to_str(get_viewport().size), "world_scale": XRServer.world_scale,
		"quality": get_node("/root/Quality").get_config(),
		"player_scene": game.player.scene_file_path,
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"loading_seconds": (_ready_at - _start) / 1000000.0,
		"counter_note": "Some Performance counters can update up to one second late; temporal correlation is approximate.",
		"timing_note": "Frame intervals include XR pacing/compositor waits. GPU/CPU values are engine viewport measurements, not transport latency.",
	}
	if xr:
		_metadata["per_eye_size"] = var_to_str(interface.get_render_target_size())
		_metadata["refresh_rate_hz"] = interface.get_display_refresh_rate()
	print("[runtime-profile] measuring %s for %.1f seconds; look around and move your hands normally" % [_metadata.mode, _duration])


func _sample() -> void:
	if _finishing:
		return
	var now := Time.get_ticks_usec()
	var vp := get_viewport().get_viewport_rid()
	var row := {"elapsed_s": (now - _start) / 1000000.0, "wall_ms": (now - _last) / 1000.0,
		"stage": "loading" if _ready_at == 0 else ("transition" if _transition_frame else "active"),
		"cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(vp),
		"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(vp),
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"pipelines": counters()}
	_rows.append(row)
	_last = now
	# Keep the final loading frame in the trace, but only time complete
	# gameplay frames in the active distribution.
	if _transition_frame:
		_transition_frame = false
		_ready_at = now
	if _ready_at > 0 and now - _ready_at >= _duration * 1000000.0:
		_finishing = true
		_finish.call_deferred()


func _finish() -> void:
	var active := _rows.filter(func(row: Dictionary) -> bool: return row.stage == "active")
	var summary := {}
	for metric in ["wall_ms", "cpu_ms", "gpu_ms", "physics_ms", "process_ms", "draw_calls", "primitives"]:
		var samples: Array[float] = []
		for row in active:
			samples.append(float(row[metric]))
		summary[metric] = distribution(samples)
	var pipelines := counters()
	for key in pipelines:
		pipelines[key] -= int(_initial_counters[key])
	_metadata.merge({"summary": summary, "frames": active.size(), "pipelines_total": pipelines, "samples": _rows})
	_metadata["script_cpu_inclusive"]=CPU_SCOPES.report()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out.get_base_dir()))
	var file := FileAccess.open(_out, FileAccess.WRITE)
	if file == null:
		if keep_open or "--profile-keep-open" in OS.get_cmdline_user_args():
			push_warning("Cannot save runtime profile: " + _out)
			_resume_game()
		else:
			push_error("Cannot save runtime profile: " + _out)
			get_tree().quit(1)
		return
	file.store_string(JSON.stringify(_metadata, "\t"))
	file.close()
	print("[runtime-profile] ", summary)
	print("[runtime-profile] wrote ", _out)
	if "--profile-screenshot" in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(_out.get_basename() + ".png")
	if not keep_open and "--profile-keep-open" not in OS.get_cmdline_user_args():get_tree().quit()
	else:_resume_game()


func _resume_game() -> void:
	CPU_SCOPES.enabled=false
	if RenderingServer.frame_post_draw.is_connected(_sample):
		RenderingServer.frame_post_draw.disconnect(_sample)
	completed.emit()


static func counters() -> Dictionary:
	var result := {}
	for key in COUNTERS:
		result[key] = int(Performance.get_monitor(COUNTERS[key]))
	return result


static func distribution(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {"count": 0}
	var ordered := samples.duplicate()
	ordered.sort()
	var sum := 0.0
	var over_11 := 0
	var over_22 := 0
	for value in ordered:
		sum += value
		if value > 1000.0 / 90.0: over_11 += 1
		if value > 1000.0 / 45.0: over_22 += 1
	return {"count": ordered.size(), "mean": sum / ordered.size(),
		"p50": ordered[int((ordered.size() - 1) * 0.50)],
		"p95": ordered[int((ordered.size() - 1) * 0.95)],
		"p99": ordered[int((ordered.size() - 1) * 0.99)], "max": ordered[-1],
		"above_11_11": over_11, "above_22_22": over_22}


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var index := args.find(key)
	return args[index + 1] if index >= 0 and index + 1 < args.size() else fallback
