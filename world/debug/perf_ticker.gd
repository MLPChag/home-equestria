extends Node
## Frame budget line in the log every few seconds (headset builds, or `--perf-ticker`): FPS,
## the engine's process vs physics time, draw calls, primitives, objects and video memory.
## Steers the potato work on a Quest, where no profiler UI can be reached (dev 2026-09-29).
const PERIOD := 5.0
var _frames := 0
var _process_us := 0
var _physics_us := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	# A Timer drives the print: it keeps ticking whatever the parent's process mode does.
	var timer := Timer.new(); timer.wait_time = PERIOD; timer.autostart = true; timer.ignore_time_scale = true
	timer.process_callback = Timer.TIMER_PROCESS_IDLE; add_child(timer); timer.timeout.connect(_report)
	print("[perf] ticker on: %s, physics %d Hz" % [RenderingServer.get_video_adapter_name(), Engine.physics_ticks_per_second])

func _process(_delta: float) -> void:
	_frames += 1
	_process_us += int(Performance.get_monitor(Performance.TIME_PROCESS) * 1e6)
	_physics_us += int(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1e6)

func _report() -> void:
	var n := maxi(1, _frames)
	var crowd: Node = get_tree().root.get_node_or_null("PonyCrowd")
	var tiers: String = str(crowd.statistics) if crowd != null and "statistics" in crowd else "-"
	var nav: Node = get_tree().get_first_node_in_group("pony_navigation")
	if nav != null and "search_counts" in nav: tiers += " nav=" + str(nav.search_counts) + " grid=" + str(nav.get("statistics"))
	print("[perf] fps=%.1f process=%.1fms physics=%.1fms(x%d/s) nav=%.1fms draws=%d prims=%dk objects=%d nodes=%d bodies=%d pairs=%d islands=%d vram=%dMB static=%dMB crowd=%s" % [
		Engine.get_frames_per_second(), _process_us / 1000.0 / n, _physics_us / 1000.0 / n, Engine.physics_ticks_per_second,
		Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)), int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)) / 1000,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)), int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)), int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)), int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)),
		int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576), int(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576), tiers])
	_frames = 0; _process_us = 0; _physics_us = 0
