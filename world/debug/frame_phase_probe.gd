extends Node
## Diagnostic-only wall-clock boundaries, verified against Godot 4.5 main.cpp and scene_tree.cpp.
## These spans partition the frame; no average is subtracted from Performance's one-second peaks.
## Callback signals and clocks add a small measurement overhead. Deferred skeleton/transform work
## belongs to the span where Godot executes it; no span is labelled as Jolt alone.
var phase := ""
var last_us := 0
var totals: Dictionary = {}
var final: Node

class EndProbe extends Node:
	var owner_probe: Node
	func _physics_process(_delta: float) -> void:
		owner_probe.mark("after_physics_callbacks")
	func _process(_delta: float) -> void:
		owner_probe.mark("after_process_callbacks")

func _ready() -> void:
	process_priority = -100000
	process_physics_priority = -100000
	final = EndProbe.new()
	final.owner_probe = self
	final.process_priority = 100000
	final.process_physics_priority = 100000
	add_child(final)
	get_tree().physics_frame.connect(_physics_signal)
	get_tree().process_frame.connect(_process_signal)
	RenderingServer.frame_pre_draw.connect(_pre_draw)
	RenderingServer.frame_post_draw.connect(_post_draw)

func _physics_signal() -> void: mark("before_physics_callbacks")
func _physics_process(_delta: float) -> void: mark("physics_callbacks")
func _process_signal() -> void: mark("before_process_callbacks")
func _process(_delta: float) -> void: mark("process_callbacks")
func _pre_draw() -> void: mark("render_frame")
func _post_draw() -> void: mark("after_render_to_next_frame")

func mark(next_phase: String) -> void:
	var now := Time.get_ticks_usec()
	if last_us > 0: totals[phase] = int(totals.get(phase, 0)) + now - last_us
	last_us = now
	phase = next_phase

func reset() -> void:
	totals.clear()
	last_us = Time.get_ticks_usec()

func report(frames: int) -> Dictionary:
	mark(phase)
	var result := {}
	for key: String in totals:
		result[key] = float(totals[key]) / (1000.0 * maxi(frames, 1))
	return result

func monitors() -> Dictionary:
	return {
		"physics_backend": ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT"),
		"physics_counter_note": "Godot 4.5 built-in Jolt returns zero for all process-info monitors; zero does not mean no physics work",
		"active_physics_objects": Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		"collision_pairs": Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS),
		"physics_islands": Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT),
		"audio_output_latency_seconds": Performance.get_monitor(Performance.AUDIO_OUTPUT_LATENCY),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"static_memory_bytes": Performance.get_monitor(Performance.MEMORY_STATIC),
		"render_thread_model": ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1),
		"monitor_note": "TIME_* values are last-second peaks; audio output latency is not CPU time"}
