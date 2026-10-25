extends RefCounted
## Unattended development harness (--capture, --perf, --perf-stereo, --probe): screenshots, frame timing and ground probes.
## Split out of game.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning game node; shared state stays there.

const TOON_OVERLAY := preload("res://world/toon_overlay.gd")
const PONY := preload("res://world/characters/pony.gd")
const CAPTURE_DIR := "res://captures"
## Positions are XZ only -- height is snapped to the terrain at capture time so
## a viewpoint stays valid when the zone's geometry or prune list changes.
## "height" is metres above ground; eye height matches the player rigs.
const VIEWPOINTS := [
	{"name": "town", "xz": Vector2(122, -110), "height": 1.7, "look": Vector2(130, -200)},
	{"name": "square", "xz": Vector2(60, -150), "height": 1.7, "look": Vector2(170, -190)},
	{"name": "trees", "xz": Vector2(171, 30), "height": 1.7, "look": Vector2(171, -70)},
	{"name": "wide", "xz": Vector2(-40, 90), "height": 35.0, "look": Vector2(130, -180)},
	# Steeply downward: isolates whether the ground surface itself is rendering,
	# independent of anything on the horizon.
	{"name": "ground", "xz": Vector2(122, -110), "height": 8.0, "look": Vector2(122, -113)},
]
## Sunset sits at 17.5 rather than 18.0 because the sun crosses the horizon at
## 18.0 exactly -- half an hour earlier is the golden hour we actually want.
const CAPTURE_TIMES := [
	{"name": "dawn", "hours": 6.5},
	{"name": "noon", "hours": 12.0},
	{"name": "sunset", "hours": 17.5},
	{"name": "night", "hours": 23.0},
]
## Pixel-load proxy without a headset (driver: tools/profile_stereo.sh).
## One offscreen 4128x2208 SubViewport -- both Quest 3 eyes side by side, so
## the pixel count matches a multiview frame while shadows and culling run once
## roughly like multiview -- this is NOT a stereo or XR-rig measurement.
## Quality's XR overrides are on *before* the
## zone is processed (zone_processor and god_rays read Quality.xr_mode), vsync
## off, no player rig. Per view: wall time between frame_post_draw, and the
## viewport's own CPU/GPU render times, as p50/p95/p99/max. Two yaw sweeps from
## the spawn point come first: the cold pass records first-view hitches with
## compilation counters, the warm pass picks the yaw with the most draw calls as
## the worst-case view. Eye height is a scaled player's (PLAYER_SCALE * 1.75 m).
##   --perf-stereo [--label s] [--out path] [--seconds 8] [--hours 12]
##                 [--preset N] [--eyes 1|2] [--no-shadows] [--no-rays]
## --eyes 2 renders two 2064x2208 viewports instead (draw calls doubled): the
## upper bound a non-multiview renderer would pay.
const STEREO_SIZE := Vector2i(4128, 2208)
const STEREO_VIEWS := [
	{"name": "spawn", "xz": Vector2(132, -128), "look": Vector2(130, -195)},
	{"name": "town", "xz": Vector2(122, -110), "look": Vector2(130, -200)},
	{"name": "square", "xz": Vector2(60, -150), "look": Vector2(170, -190)},
	# Looking down at one's own feet: near ground fills the frame (dev, headset
	# round 2: "looking down at my playermodel causes me to lag like crazy").
	{"name": "feet", "xz": Vector2(132, -128), "look": Vector2(132.3, -128.3)},
]

var host: Node3D


func _init(owner_node: Node3D) -> void:
	host = owner_node


## The outline pass has to hang off the live camera, which differs between rigs.
func _attach_toon_overlay(rig: Node) -> Node:
	var cam: Node3D = host._find_camera(rig)
	if cam == null:
		push_warning("[game] no camera found; outline overlay skipped")
		return null
	host.toon = TOON_OVERLAY.new()
	host.toon.name = "ToonOverlay"
	cam.add_child(host.toon)
	return host.toon


func _run_capture() -> void:
	var args := preload("res://world/dev_tools.gd").user_args()
	var only_preset: String = host._arg_value(args, "--preset")
	var tag: String = host._arg_value(args, "--tag")

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURE_DIR))

	var cam := Camera3D.new()
	cam.fov = 70.0
	cam.far = Quality.get_value("draw_distance", 9000.0)
	cam.current = true
	host.add_child(cam)

	# --character <res-path> drops a character into the world and frames the shots
	# on it. Scale is the thing this is really for: a pony only looks right
	# measured against Ponyville's doorways, not against an empty grid.
	var char_path: String = host._arg_value(args, "--character")
	var char_pos := Vector3.ZERO
	if char_path != "":
		var packed: PackedScene = load(char_path)
		if packed == null:
			push_error("[capture] could not load character %s" % char_path)
		elif char_path.ends_with(".tscn"):
			# Self-contained physics character: photographs her own live
			# simulation, no wrapper.
			var rig: Node3D = packed.instantiate()
			host.add_child(rig)
			host._pending_character = rig
		else:
			# Wrapped in a Pony even for stills, so what gets photographed is the
			# rig as it actually behaves -- gaze and the mane/tail slaving
			# included. Shooting the bare model hides exactly the faults that
			# only appear once something drives the skeleton.
			var p: CharacterBody3D = PONY.new()
			p.name = "RainbowDash"
			p.model_scene = packed
			host.add_child(p)
			host._pending_character = p

	# --style N shoots a specific outline preset, for A/B comparison shots.
	var style_arg: String = host._arg_value(args, "--style")
	if style_arg != "":
		var ov = _attach_toon_overlay(cam)
		if ov != null:
			ov.apply_style(int(style_arg))

	ZoneManager.setup(host.zones, cam)
	TimeOfDay.paused = true
	await ZoneManager.wait_until_idle()
	# Streamed geometry needs a few frames before its materials are resident,
	# and its collision bodies are not in the physics space until physics has
	# stepped -- without that wait, viewpoint ground-snapping silently falls
	# back to y=0 and buries the camera inside the terrain.
	for i in 20:
		await RenderingServer.frame_post_draw
	for i in 10:
		await host.get_tree().physics_frame

	# --quick shoots one viewpoint at noon: enough to judge a shader change
	# without paying for the full 16-shot matrix.
	var quick := "--quick" in args
	var presets: Array = []
	if only_preset != "":
		presets.append(int(only_preset))
	else:
		presets = [Quality.Preset.LOW, Quality.Preset.HIGH]

	# --at x,y,z --dir dx,dy,dz reproduces an exact in-game vantage, so a bug
	# spotted while walking around can be shot from the same spot. Pair with the
	# player's P key, which prints position and look direction.
	var at_arg: String = host._arg_value(args, "--at")
	var dir_arg: String = host._arg_value(args, "--dir")

	# Placed after physics is live so she stands on the ground rather than in it.
	if host._pending_character != null:
		var spot := Vector2(150.0, -150.0)
		char_pos = Vector3(spot.x, _ground_y(spot), spot.y)
		# The physics pony baked her bodies at the origin when she entered the
		# tree; only a rigid teleport moves her as one piece.
		if host._pending_character.has_method("teleport"):
			host._pending_character.call("teleport", Transform3D(Basis.IDENTITY, char_pos))
		else:
			host._pending_character.global_position = char_pos
		# A stand-in for the player, parked off to one side and slightly high, so
		# gaze is exercised at a real angle rather than dead ahead -- a broken
		# forward axis is invisible when the target is straight in front.
		# The physics pony has no gaze yet, so only assign where it exists.
		if "player" in host._pending_character:
			var look_dummy := Node3D.new()
			host.add_child(look_dummy)
			look_dummy.global_position = char_pos + Vector3(2.2, 0.6, 2.2)
			host._pending_character.player = look_dummy
		print("[capture] character at %s" % char_pos.round())

	var times: Array = [CAPTURE_TIMES[1]] if quick else CAPTURE_TIMES
	# Eye-level, so ground detail is judged at the distance the player sees it.
	var views: Array = [VIEWPOINTS[0], VIEWPOINTS[4]] if quick else VIEWPOINTS

	for p in presets:
		Quality.preset = p
		var pname: String = Quality.preset_name().to_lower().replace(" ", "_")
		for t in times:
			TimeOfDay.hours = t["hours"]
			if host._pending_character != null:
				# Three-quarter view at pony eye level, then a wider one for scale.
				for shot in [
						{"n": "face", "off": Vector3(1.15, 0.85, 1.15), "look": 0.75},
						{"n": "body", "off": Vector3(2.1, 1.0, 2.1), "look": 0.55},
						{"n": "scale", "off": Vector3(4.0, 1.6, 4.0), "look": 0.55},
					]:
					cam.global_position = char_pos + (shot["off"] as Vector3)
					cam.look_at(char_pos + Vector3.UP * float(shot["look"]), Vector3.UP)
					for i in 12:
						await RenderingServer.frame_post_draw
					var cshot := "%s/%s%s_%s_%s.png" % [
						CAPTURE_DIR, ("%s_" % tag) if tag != "" else "",
						pname, t["name"], shot["n"]]
					host.get_viewport().get_texture().get_image().save_png(cshot)
					print("[capture] ", cshot)
				continue

			if at_arg != "":
				cam.global_position = _parse_vec3(at_arg)
				var d := _parse_vec3(dir_arg) if dir_arg != "" else Vector3.FORWARD
				cam.look_at(cam.global_position + d.normalized(), Vector3.UP)
				for i in 12:
					await RenderingServer.frame_post_draw
				var shot := "%s/%s%s_%s_repro.png" % [
					CAPTURE_DIR, ("%s_" % tag) if tag != "" else "", pname, t["name"]]
				host.get_viewport().get_texture().get_image().save_png(shot)
				print("[capture] ", shot)
				continue

			for v in views:
				var xz: Vector2 = v["xz"]
				var lxz: Vector2 = v["look"]
				var gy := _ground_y(xz)
				cam.global_position = Vector3(xz.x, gy + float(v["height"]), xz.y)
				cam.look_at(Vector3(lxz.x, _ground_y(lxz) + 1.5, lxz.y), Vector3.UP)
				print("[capture]   %s cam=%s ground_y=%.2f" % [
					v["name"], cam.global_position.round(), gy])
				# SDFGI and the realtime radiance map both converge over several
				# frames; shooting early gives dark, wrong-looking probes.
				for i in 12:
					await RenderingServer.frame_post_draw
				var img := host.get_viewport().get_texture().get_image()
				var fname := "%s/%s%s_%s_%s.png" % [
					CAPTURE_DIR, ("%s_" % tag) if tag != "" else "",
					pname, t["name"], v["name"]]
				img.save_png(fname)
				print("[capture] ", fname)

	print("[capture] done")
	host.get_tree().quit()


## Frame-time measurement per quality preset.
##
## The shipping floor is a 3060 holding 90 fps in stereo -- an 11 ms frame,
## rendered twice. The 3060 is roughly 2.5x slower than this 4080 Super at this
## workload and stereo is not free, so the Low preset needs to land near 4-5 ms
## here to have any chance there. That ratio is a rule of thumb, not a
## measurement: it wants checking against a real 3060 before anyone trusts it.
func _run_perf() -> void:
	const WARMUP := 90
	const FRAMES := 220

	var cam := Camera3D.new()
	cam.fov = 70.0
	cam.far = Quality.get_value("draw_distance", 9000.0)
	cam.current = true
	host.add_child(cam)

	# The outline pass must be in the measurement or the numbers describe a build
	# nobody plays. --style N picks which preset to measure; default is Ink.
	var style_arg: String = host._arg_value(preload("res://world/dev_tools.gd").user_args(), "--style")
	var ov = _attach_toon_overlay(cam)
	if ov != null:
		ov.apply_style(int(style_arg) if style_arg != "" else 2)
		print("[perf] outline style: %s" % ov.style_name())

	ZoneManager.setup(host.zones, cam)
	TimeOfDay.paused = true
	TimeOfDay.hours = 12.0
	await ZoneManager.wait_until_idle()
	for i in 10:
		await host.get_tree().physics_frame

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var v: Dictionary = VIEWPOINTS[0]
	var xz: Vector2 = v["xz"]
	var lxz: Vector2 = v["look"]
	cam.global_position = Vector3(xz.x, _ground_y(xz) + 1.7, xz.y)
	cam.look_at(Vector3(lxz.x, _ground_y(lxz) + 1.5, lxz.y), Vector3.UP)

	print("\n time    preset   avg ms   p95 ms    fps   draw calls   Mprims   VRAM MB")
	print(" ------  -------  ------  -------  -----  -----------  -------  -------")

	# Night is measured too: 128 lamp omni lights only exist after dark, and they
	# are the one cost that does not show up in a noon measurement.
	for when in [{"name": "noon", "h": 12.0}, {"name": "night", "h": 23.0}]:
		TimeOfDay.hours = float(when["h"])
		for p in [Quality.Preset.VERY_LOW, Quality.Preset.LOW, Quality.Preset.MEDIUM,
				Quality.Preset.HIGH, Quality.Preset.ULTRA]:
			Quality.preset = p
			for i in WARMUP:
				await RenderingServer.frame_post_draw

			var samples: Array[float] = []
			for i in FRAMES:
				var t0 := Time.get_ticks_usec()
				await RenderingServer.frame_post_draw
				samples.append(float(Time.get_ticks_usec() - t0) / 1000.0)

			samples.sort()
			var total := 0.0
			for s in samples:
				total += s
			var avg := total / float(samples.size())
			var p95 := samples[int(float(samples.size()) * 0.95)]

			print(" %-6s  %-7s  %6.2f  %7.2f  %5.0f  %11d  %7.2f  %7.0f" % [
				when["name"], Quality.PRESET_NAMES[p], avg, p95,
				1000.0 / maxf(avg, 0.001),
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1e6,
				Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])

	print("\nLow needs to be near 4-5 ms here for a 3060 to hold 90 fps in stereo.")
	host.get_tree().quit()


func _run_perf_stereo() -> void:
	var args := preload("res://world/dev_tools.gd").user_args()
	var label: String = host._arg_value(args, "--label")
	if label == "":
		label = "baseline"
	var out_path: String = host._arg_value(args, "--out")
	if out_path == "":
		out_path = "/tmp/stereo_perf_%s.json" % label
	var seconds := 8.0 if host._arg_value(args, "--seconds") == "" else float(host._arg_value(args, "--seconds"))
	var hours := 12.0 if host._arg_value(args, "--hours") == "" else float(host._arg_value(args, "--hours"))
	var eyes := 2 if host._arg_value(args, "--eyes") == "2" else 1
	var no_shadows := "--no-shadows" in args

	# XR quality first: the zone processor gates the cel/water pass on it.
	Quality.set_xr_mode(true)
	if host._arg_value(args, "--preset") != "":
		Quality.preset = int(host._arg_value(args, "--preset"))
	var cfg := Quality.get_config()
	# The window only shows the offscreen render; it must not be a second 3D pass.
	host.get_viewport().disable_3d = true

	var head := Node3D.new()
	head.name = "StereoHead"
	host.add_child(head)
	var strip := HBoxContainer.new()
	strip.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(strip)
	var vps: Array[SubViewport] = []
	var cams: Array[Camera3D] = []
	for e in eyes:
		var svp := SubViewport.new()
		svp.size = Vector2i(STEREO_SIZE.x / eyes, STEREO_SIZE.y)
		svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		# Quality only writes the root viewport; mirror its knobs here.
		svp.msaa_3d = cfg["msaa"]
		svp.scaling_3d_scale = cfg["render_scale"]
		svp.screen_space_aa = cfg["screen_space_aa"]
		svp.positional_shadow_atlas_size = cfg["shadow_atlas"]
		svp.mesh_lod_threshold = cfg["mesh_lod_threshold"]
		host.add_child(svp)
		var cam := Camera3D.new()
		# Quest 3 is ~93 deg tall per eye; one wide view needs a bit less to keep
		# the horizontal near the ~110 deg the two eyes cover together.
		cam.fov = 93.0 if eyes == 2 else 86.0
		cam.far = Quality.get_value("draw_distance", 9000.0)
		svp.add_child(cam)
		cam.current = true
		RenderingServer.viewport_set_measure_render_time(svp.get_viewport_rid(), true)
		vps.append(svp)
		cams.append(cam)
		var tr := TextureRect.new()
		tr.texture = svp.get_texture()
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		tr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		strip.add_child(tr)

	ZoneManager.setup(host.zones, head)
	TimeOfDay.paused = true
	TimeOfDay.hours = hours
	if "--live-time" in args:
		TimeOfDay.paused = false
	await ZoneManager.wait_until_idle()
	for i in 10:
		await host.get_tree().physics_frame

	var sun: DirectionalLight3D = host.get_node("Sun")
	if no_shadows:
		# Nothing rewrites this later: time is paused and quality is final.
		sun.shadow_enabled = false

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var look_in_xr: bool = bool(_zone_config("ponyville").get("look_in_xr", false)) or "--profile-look" in args
	print("[perf] desktop pixel proxy '%s': %dx%d x%d views, preset %s, look_in_xr=%s, shadows=%s, rays=%s" % [
		label, vps[0].size.x, vps[0].size.y, eyes, Quality.preset_name(), look_in_xr,
		sun.shadow_enabled, false])

	# Sweeps from spawn: cold (first sight of every material) then warm.
	var spawn_xz: Vector2 = STEREO_VIEWS[0]["xz"]
	var cold := await _stereo_sweep(head, cams, vps, spawn_xz, 8)
	var warm := await _stereo_sweep(head, cams, vps, spawn_xz, 8)
	var worst: Dictionary = warm[0]
	for s in warm:
		if s["draw_calls"] > worst["draw_calls"]:
			worst = s
	var yaw := deg_to_rad(float(worst["yaw_deg"]))
	var views: Array = STEREO_VIEWS.duplicate()
	views.append({"name": "worst", "xz": spawn_xz,
		"look": spawn_xz + Vector2(sin(yaw), cos(yaw)) * 50.0})

	print("\n view    frames  wall p50  wall p95  wall p99  wall max   gpu p50   gpu p95  draws   Mprims")
	var results: Array = []
	for v in views:
		_stereo_place(head, cams, v["xz"], v["look"])
		# --profile-anon puts the player body in the feet view (dev, headset
		# round 2: looking down at himself lagged); -plain swaps his materials
		# for a StandardMaterial3D, -nooutline drops only the hull pass.
		var anon_probe: Node3D = null
		if v["name"] == "feet" and "--profile-anon" in args:
			anon_probe = load("res://player/anon_body.tscn").instantiate()
			anon_probe.set_process(false)
			anon_probe.set_physics_process(false)
			host.add_child(anon_probe)
			var fwd := -head.global_basis.z
			fwd.y = 0.0
			var at := head.global_position + fwd.normalized() * 0.6
			at.y = _ground_y(Vector2(at.x, at.z))
			anon_probe.global_position = at
			for mi in anon_probe.find_children("*", "MeshInstance3D", true, false):
				var m := mi as MeshInstance3D
				if "--profile-anon-plain" in args:
					m.material_override = StandardMaterial3D.new()
				elif "--profile-anon-nooutline" in args:
					for si in m.mesh.get_surface_count():
						var mat := m.get_active_material(si)
						if mat != null:
							mat.next_pass = null
		for i in 60:
			await RenderingServer.frame_post_draw
		var r := await _stereo_measure(vps, seconds)
		if anon_probe != null:
			anon_probe.queue_free()
		r["name"] = v["name"]
		r["xz"] = [v["xz"].x, v["xz"].y]
		r["look"] = [v["look"].x, v["look"].y]
		r["shadows_enabled"] = sun.shadow_enabled
		results.append(r)
		print(" %-6s  %6d  %8.2f  %8.2f  %8.2f  %8.2f  %8.2f  %8.2f  %5d  %7.2f" % [
			v["name"], r["frames"], r["wall_ms"]["p50"], r["wall_ms"]["p95"],
			r["wall_ms"]["p99"], r["wall_ms"]["max"], r["gpu_ms"]["p50"], r["gpu_ms"]["p95"],
			r["draw_calls"], r["primitives"] / 1e6])

	var record := {
		"label": label, "when": Time.get_datetime_string_from_system(),
		"mode": "two_mono_viewports" if eyes == 2 else "wide_mono_pixel_proxy",
		"gpu": RenderingServer.get_video_adapter_name(),
		"size": [STEREO_SIZE.x, STEREO_SIZE.y], "eyes": eyes, "hours": hours,
		"preset": Quality.preset_name(), "quality": cfg, "look_in_xr": look_in_xr,
		"shadows": sun.shadow_enabled, "god_rays": false,
		"seconds_per_view": seconds, "eye_height": host.STEREO_EYE_HEIGHT,
		"sweep_cold": cold, "sweep_warm": warm, "worst_yaw_deg": worst["yaw_deg"],
		"views": results,
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path.get_base_dir()))
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(record, "  "))
		print("[perf] wrote %s" % out_path)
	else:
		push_error("[perf] cannot write %s" % out_path)
		host.get_tree().quit(1)
		return
	host.get_tree().quit()


func _stereo_place(head: Node3D, cams: Array[Camera3D], xz: Vector2, look: Vector2) -> void:
	head.global_position = Vector3(xz.x, _ground_y(xz) + host.STEREO_EYE_HEIGHT, xz.y)
	# A look point within a metre means "look at the ground there".
	var look_h: float = 0.0 if look.distance_to(xz) < 1.0 else host.STEREO_EYE_HEIGHT
	head.look_at(Vector3(look.x, _ground_y(look) + look_h, look.y), Vector3.UP)
	# A Camera3D under a SubViewport is not in the head's transform chain.
	for i in cams.size():
		var ipd: float = 0.0 if cams.size() == 1 else (0.064 * host.PLAYER_SCALE) * (float(i) - 0.5)
		cams[i].global_transform = head.global_transform.translated_local(Vector3(ipd, 0.0, 0.0))


## Level gaze every 15 deg around a point; a few frames each. Returns per yaw the
## worst wall frame and the draw count. Compilation counters help attribute
## first-view hitches; a cold frame alone does not prove a compilation stall.
func _stereo_sweep(head: Node3D, cams: Array[Camera3D], vps: Array[SubViewport],
		xz: Vector2, frames: int) -> Array:
	var out: Array = []
	for step in 24:
		var compile_before: Dictionary = load(host.RUNTIME_PROFILE_PATH).counters()
		var yaw := deg_to_rad(step * 15.0)
		_stereo_place(head, cams, xz, xz + Vector2(sin(yaw), cos(yaw)) * 50.0)
		var worst := 0.0
		var gpu_worst := 0.0
		for i in frames:
			var t0 := Time.get_ticks_usec()
			await RenderingServer.frame_post_draw
			worst = maxf(worst, float(Time.get_ticks_usec() - t0) / 1000.0)
			gpu_worst = maxf(gpu_worst, _stereo_gpu_ms(vps))
		out.append({"yaw_deg": step * 15, "max_ms": worst, "gpu_max_ms": gpu_worst,
			"pipelines_before": compile_before,
			"pipelines_after": load(host.RUNTIME_PROFILE_PATH).counters(),
			"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))})
	return out


func _stereo_gpu_ms(vps: Array[SubViewport]) -> float:
	var g := 0.0
	for svp in vps:
		g += RenderingServer.viewport_get_measured_render_time_gpu(svp.get_viewport_rid())
	return g


func _stereo_measure(vps: Array[SubViewport], seconds: float) -> Dictionary:
	var wall: Array[float] = []
	var cpu: Array[float] = []
	var gpu: Array[float] = []
	var physics: Array[float] = []
	var process: Array[float] = []
	var compile_before: Dictionary = load(host.RUNTIME_PROFILE_PATH).counters()
	var t_end := Time.get_ticks_usec() + int(seconds * 1e6)
	var t_prev := Time.get_ticks_usec()
	while Time.get_ticks_usec() < t_end:
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		wall.append(float(now - t_prev) / 1000.0)
		t_prev = now
		var c := 0.0
		for svp in vps:
			c += RenderingServer.viewport_get_measured_render_time_cpu(svp.get_viewport_rid())
		cpu.append(c)
		gpu.append(_stereo_gpu_ms(vps))
		physics.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		process.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	return {
		"frames": wall.size(),
		"wall_ms": _stereo_stats(wall), "cpu_ms": _stereo_stats(cpu), "gpu_ms": _stereo_stats(gpu),
		"physics_ms": _stereo_stats(physics), "process_ms": _stereo_stats(process),
		"pipelines_before": compile_before, "pipelines_after": load(host.RUNTIME_PROFILE_PATH).counters(),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"vram_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
	}


func _stereo_stats(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {"mean": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted := samples.duplicate()
	sorted.sort()
	var total := 0.0
	for s in sorted:
		total += s
	var n := sorted.size()
	return {
		"mean": total / n,
		"p50": sorted[mini(int(n * 0.50), n - 1)],
		"p95": sorted[mini(int(n * 0.95), n - 1)],
		"p99": sorted[mini(int(n * 0.99), n - 1)],
		"max": sorted[n - 1],
	}


func _zone_config(id: String) -> Dictionary:
	var path := "res://world/zones/%s/zone.json" % id
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## Reports what is actually under a set of points -- the direct answer to
## "is there ground here", which a screenshot can only hint at.
func _run_probe() -> void:
	ZoneManager.setup(host.zones, host)
	await ZoneManager.wait_until_idle()
	for i in 20:
		await host.get_tree().physics_frame

	print("\n--- terrain placement ---")
	var stack: Array[Node] = [host.zones]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D and str(n.name).begins_with("Terrain_"):
			var mi := n as MeshInstance3D
			var box: AABB = mi.global_transform * mi.get_aabb()
			print("  %s\n     x: %.1f .. %.1f   z: %.1f .. %.1f   y: %.1f .. %.1f" % [
				n.name, box.position.x, box.position.x + box.size.x,
				box.position.z, box.position.z + box.size.z,
				box.position.y, box.position.y + box.size.y])
			for ch in mi.get_children():
				if ch is StaticBody3D:
					var body := ch as StaticBody3D
					print("     body=%s layer=%d pos=%s shapes=%d" % [
						body.name, body.collision_layer,
						body.global_position, body.get_child_count()])
					for sh in body.get_children():
						if sh is CollisionShape3D:
							var s := (sh as CollisionShape3D).shape
							var faces := 0
							if s is ConcavePolygonShape3D:
								faces = (s as ConcavePolygonShape3D).get_faces().size() / 3
							print("       shape=%s faces=%d disabled=%s" % [
								s, faces, (sh as CollisionShape3D).disabled])

	var points := [
		Vector2(122, -165), Vector2(60, -150), Vector2(200, -200),
		Vector2(0, -100), Vector2(300, -300), Vector2(171, 30), Vector2(-100, -50),
	]
	var space := host.get_world_3d().direct_space_state
	print("\n--- ground probe ---")
	for p in points:
		var q := PhysicsRayQueryParameters3D.create(
			Vector3(p.x, 500.0, p.y), Vector3(p.x, -300.0, p.y))
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			print("  (%6.0f, %6.0f)  NO HIT" % [p.x, p.y])
		else:
			var col: Object = hit["collider"]
			var owner_name := "?"
			if col is Node:
				var parent := (col as Node).get_parent()
				owner_name = str(parent.name) if parent else str((col as Node).name)
			print("  (%6.0f, %6.0f)  y=%8.2f  <- %s" % [
				p.x, p.y, hit["position"].y, owner_name])
	# Collision only reveals what the player can touch. Anything visible but
	# non-colliding -- which is what an unexplained surface usually turns out to
	# be -- has to be found geometrically instead.
	var probe_at: String = host._arg_value(preload("res://world/dev_tools.gd").user_args(), "--probe-at")
	var target := Vector2(122, -165)
	if probe_at != "":
		var pv := _parse_vec3(probe_at + ",0")
		target = Vector2(pv.x, pv.y)
	print("\n--- visible meshes spanning (%.0f, %.0f), highest first ---" % [
		target.x, target.y])
	var found: Array = []
	var walk: Array[Node] = [host.zones]
	while not walk.is_empty():
		var n: Node = walk.pop_back()
		for c in n.get_children():
			walk.push_back(c)
		if not (n is MeshInstance3D):
			continue
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var box: AABB = mi.global_transform * mi.get_aabb()
		if target.x < box.position.x or target.x > box.position.x + box.size.x:
			continue
		if target.y < box.position.z or target.y > box.position.z + box.size.z:
			continue
		var mat := mi.get_active_material(0)
		var mat_name := "-"
		if mat != null:
			mat_name = mat.resource_name if mat.resource_name != "" else mat.get_class()
		if mi.material_override != null:
			mat_name = "override:" + mi.material_override.get_class()
		found.append([box.position.y + box.size.y, str(mi.name), mat_name,
			box.size.x, box.size.z])
	found.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	for f in found.slice(0, 14):
		print("  topY=%8.2f  %-34s %-26s  %.0f x %.0f m" % [
			f[0], f[1], f[2], f[3], f[4]])
	print("  total spanning: %d" % found.size())

	# Cast along an actual view direction and name what is hit. Requires the zone
	# config to give collision to everything; otherwise the ray sails through the
	# very mesh being investigated.
	var ray_at: String = host._arg_value(preload("res://world/dev_tools.gd").user_args(), "--at")
	var ray_dir: String = host._arg_value(preload("res://world/dev_tools.gd").user_args(), "--dir")
	if ray_at != "" and ray_dir != "":
		var origin := _parse_vec3(ray_at)
		var dir := _parse_vec3(ray_dir).normalized()
		print("\n--- view ray from %s toward %s ---" % [origin, dir])
		var sp := host.get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 400.0)
		var h := sp.intersect_ray(q)
		if h.is_empty():
			print("  NO HIT (nothing solid along that view)")
		else:
			var node: Node = h["collider"]
			var trail: Array = []
			var walk_up: Node = node
			while walk_up != null and trail.size() < 6:
				trail.push_front(str(walk_up.name))
				walk_up = walk_up.get_parent()
			print("  hit at %s, %.1f m away" % [
				h["position"], origin.distance_to(h["position"])])
			print("  path: %s" % "/".join(trail))
	print("--- end probe ---")
	host.get_tree().quit()


## Terrain height under an XZ point, via the collision the zone processor built.
## Falls back to 0 when nothing is hit, which is the flat-plain height anyway.
func _ground_y(xz: Vector2) -> float:
	var space := host.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(xz.x, 400.0, xz.y), Vector3(xz.x, -200.0, xz.y), 1)
	var hit := space.intersect_ray(query)
	if not hit.has("position"):
		# Outside physics collision (unloaded zone, beyond Terrain3D's dynamic radius): the
		# world heightmap still knows the ground.
		if is_instance_valid(WorldTerrain.instance):
			var ground: float = WorldTerrain.instance.height_at(Vector3(xz.x, 0.0, xz.y))
			if is_finite(ground):
				return ground
		push_warning("[capture] no ground under (%.0f, %.0f); using y=0" % [xz.x, xz.y])
		return 0.0
	return float(hit["position"].y)


func _parse_vec3(s: String) -> Vector3:
	var parts := s.split(",")
	if parts.size() < 3:
		return Vector3.ZERO
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
