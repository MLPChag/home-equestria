extends RefCounted
## Crowd clip tiers of pony_locomotion.gd (split 2026-10-13; docs/CLIP_TIER_2026_09_25.md): the
## hand-off into and out of the solver-baked clips, and the choice of gait and posture clip. The
## per-step clip motion (_far_tick, _clip_logic, _clip_step, the posture ticks) stays in the pony
## beside the state it shares with the motor. Calls back go through `pony.` so overrides apply.

const BAKED_GAITS := preload("res://world/characters/locomotion/baked_gaits.gd")


## Into NEAR/FAR from the solver: no collision body, the terrain modifier off, the solved pose
## baked into a hand-off clip, and the mixer advanced by hand from _far_tick.
static func enter(pony: Node) -> void:
	pony._logic_delta = 0.0
	pony._logic_steps = 0
	pony._clip_pitch = 0.0
	pony._clip_pitch_target = 0.0
	pony._clip_floor = NAN
	pony._clip_probe_logic = 0
	pony._clip_floor_from_ray = false
	pony._clip_ahead_certified = false
	pony._clip_advance_delta = 0.0
	pony._clip_pivot_settled = false
	pony._posture_pivot_settled = false
	pony._posture_clip_held = false
	pony._clip_blocked = false
	pony._clip_gait_hold = 0.0
	var desired: Vector3 = pony._desired
	var wanted := desired.length()
	pony._clip_wanted = wanted
	pony._clip_yaw = atan2(-desired.x, -desired.z) if wanted > 0.01 else pony.rotation.y
	# Start the first gait clip where the solver's leading leg was, in the gait it was in.
	var step_timing: RefCounted = pony.step_timing
	var hero_gait: String = step_timing.gait
	pony._clip_enter_phase = step_timing.gallop_phase if hero_gait == "gallop" else step_timing.phases[0]
	pony._clip_gait = hero_gait if hero_gait != "trot" else ("trot_fast" if pony.actual_speed >= pony.profile.trot_speed.x else "trot")
	# The head keeps its look: the live head layer starts from the secondary's current angles.
	var secondary: RefCounted = pony.secondary
	var head := PackedVector3Array([secondary.head_angles, secondary.gaze_angles, secondary._neck_gaze])
	pony.clip_head_from = head
	pony.clip_head_to = head.duplicate()
	var collision: CollisionShape3D = pony._collision
	if collision != null:
		collision.disabled = true
	pony.modifier.active = false
	pony._bake_handoff()
	var pivot: Node3D = pony.pivot
	pony._clip_from = pivot.transform
	pony._clip_blend = 0.0
	pony._clip_age = 0.0
	pony._clip_blend_end = 0.0
	pony._clip_static = false
	var skeleton: Skeleton3D = pony.skeleton
	skeleton.reset_bone_poses()
	for foot: Dictionary in pony.feet:
		foot.planted = false
		foot.valid = false
	pony.self_collision.reset()
	step_timing.reset()
	# Manual: advanced from _far_tick every physics step.
	var animation: AnimationPlayer = pony.animation
	animation.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	animation.speed_scale = 1.0
	var posture: RefCounted = pony.posture
	if posture != null and posture.active() and pony._posture_clip(posture.advance_sleep(0.0)).exact:
		# Mid-posture the baked clip at the posture's own clip time is the solver's pose without
		# the gaze, and the live head adds that gaze back at once: no crossfade needed. (While a
		# sleep pose blends on some other timeline, the hand-off clip below bridges the two.)
		pony._clip_blend = 1.0
		pony._play_posture_clip(posture.advance_sleep(0.0), true)
		animation.advance(0.0)
		return
	var handoff: String = pony.HANDOFF
	animation.play(handoff if animation.has_animation(handoff) else pony._baked_name(BAKED_GAITS.STAND))
	animation.advance(0.0)


## The solver's last prepared pose as a one-key looping clip in this pony's own library, so
## `_far_tick`'s first `play(clip, blend)` crossfades from it instead of cutting. Every bone is
## keyed, not only the gait clips' bones: a mare looking up at the player had her neck cut 45°
## to rest at the switch (dev 2026-09-17); the mixer now blends bones the target clip leaves
## unkeyed from the hand-off pose to their rest value.
static func bake_handoff(pony: Node) -> void:
	var baked: AnimationLibrary = pony._baked
	var base := String(baked.get_meta("base_path", "")) if baked != null else ""
	if base.is_empty():
		return
	var skeleton: Skeleton3D = pony.skeleton
	var prepared: Array = pony.modifier.prepared
	var pose_of: Array = prepared if prepared.size() == skeleton.get_bone_count() else []
	var clip := Animation.new()
	clip.length = 1.0
	clip.loop_mode = Animation.LOOP_LINEAR
	for bone in skeleton.get_bone_count():
		var pose: Transform3D = pose_of[bone] if not pose_of.is_empty() else skeleton.get_bone_pose(bone)
		var path := NodePath(base + ":" + skeleton.get_bone_name(bone))
		var k := clip.add_track(Animation.TYPE_POSITION_3D)
		clip.track_set_path(k, path)
		clip.position_track_insert_key(k, 0.0, pose.origin)
		k = clip.add_track(Animation.TYPE_ROTATION_3D)
		clip.track_set_path(k, path)
		clip.rotation_track_insert_key(k, 0.0, pose.basis.get_rotation_quaternion())
		k = clip.add_track(Animation.TYPE_SCALE_3D)
		clip.track_set_path(k, path)
		clip.scale_track_insert_key(k, 0.0, pose.basis.get_scale())
	var animation: AnimationPlayer = pony.animation
	var library: AnimationLibrary
	if animation.has_animation_library("handoff"):
		library = animation.get_animation_library("handoff")
		if library.has_animation("crowd_handoff"):
			library.remove_animation("crowd_handoff")
	else:
		library = AnimationLibrary.new()
		animation.add_animation_library("handoff", library)
	library.add_animation("crowd_handoff", clip)


## Back onto the solver: the pose the clip was showing, the clip's phase and speed, collision on.
static func leave(pony: Node) -> void:
	pony._set_rest_frozen(false)
	pony._clip_static = false
	var skeleton: Skeleton3D = pony.skeleton
	var animation: AnimationPlayer = pony.animation
	# Until the solver's first tick prepares its own pose, the terrain modifier shows the pose
	# the clip was showing, not whatever it last prepared before she left for the clip tier.
	var shown: Array[Transform3D] = []
	for bone in skeleton.get_bone_count():
		shown.append(skeleton.get_bone_pose(bone))
	pony.modifier.prepared = shown
	# The solver picks up at the clip's phase and speed: a pony walking into close range keeps
	# walking instead of stopping to restart her gait.
	var clip_phase := 0.0
	var clip_moving: bool = pony._clip_gait_playing()
	if clip_moving and animation.current_animation_length > 0.0:
		clip_phase = fposmod(animation.current_animation_position / animation.current_animation_length, 1.0)
	animation.pause()
	animation.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	animation.speed_scale = 1.0
	skeleton.reset_bone_poses()
	pony.modifier.active = true
	var collision: CollisionShape3D = pony._collision
	if collision != null:
		collision.disabled = false
	var actual_speed: float = pony.actual_speed
	clip_moving = clip_moving and actual_speed > 0.05
	pony.velocity = Vector3.ZERO
	pony._command_speed = actual_speed if clip_moving else 0.0
	pony._ground_velocity = Vector3.ZERO
	pony._previous_horizontal_velocity = Vector3.ZERO
	pony._body_height = 0.0
	pony._body_tilt = Quaternion.IDENTITY
	pony._blend = 1.0 if clip_moving else 0.0
	pony._stop_elapsed = 0.0
	pony.state = pony.Motion.MOVING if clip_moving else pony.Motion.STANDING
	pony.step_timing.reset(clip_phase)
	pony.phase = clip_phase
	var posture: RefCounted = pony.posture
	if posture != null and posture.active():
		# Mid-posture: the solver's FK picks up at the same clip time the baked clip was at.
		posture._last_source_time = -1.0
		if posture.phase != "recover":
			posture._join_time = maxf(posture._join_time, 1.0)
	pony._initialized = false
	pony._spawn_settle = 0.35
	pony._corner_speed = INF
	pony._blocked = false
	pony._unsupported_seconds = 0.0
	pony._heightmap_supported = false
	# The grid height that carried her at a distance may sit under the real surface.
	if pony.is_inside_tree():
		pony._recover_support()


## Clip gait for a wanted and actual speed, from the current one: the solver's walk/trot and
## trot/gallop entry and exit, and trot vs trot_fast split at the trot travel band's floor.
static func choose_gait(profile: Resource, gait: String, wanted: float, speed: float) -> String:
	var split: float = profile.trot_speed.x
	var gallop_ready: bool = wanted >= profile.gallop_entry and speed >= profile.gallop_entry - 0.8
	match gait:
		"gallop":
			if wanted < profile.gallop_exit or speed < profile.gallop_exit - 0.8:
				return "trot_fast" if speed >= split else "trot"
		"walk":
			if gallop_ready: return "gallop"
			if wanted >= profile.trot_entry: return "trot_fast" if speed >= split else "trot"
		_:
			if gallop_ready: return "gallop"
			if wanted > 0.0 and wanted < profile.trot_exit and speed < profile.trot_entry: return "walk"
			if gait != "trot_fast" and speed >= split + 0.1: return "trot_fast"
			if gait == "trot_fast" and speed < split - 0.1: return "trot"
			if gait != "trot" and gait != "trot_fast": return "trot"
	return gait


## The baked clip for the posture's phase: the entry clip (played backwards while reversing), the
## hold, the sleep pose while settling in or asleep, the rise, then the stand clip for recovery.
## NightRest's bedtime (lie down and fall asleep together) and waking (rise while the sleep pose
## unwinds) have their own baked clips, so they match the solver's blend exactly; `exact` is
## false only while a sleep pose blends in or out on some other timeline (a crossfade then).
static func posture_clip(posture: RefCounted, style: String) -> Dictionary:
	var choice := {"clip": "", "time": posture.source_time, "speed": 1.0, "blend": 0.18, "hold": false, "exact": true}
	var sleep_pose: String = posture.sleep_pose_name(posture._sleep_style) if posture._sleep_style != "" else ""
	var sleep_seconds: float = posture.SLEEP_SECONDS.get(posture._sleep_style, 1.3)
	match posture.phase:
		"enter", "reverse":
			choice.clip = posture.kind
			choice.speed = -1.0 if posture.phase == "reverse" else 1.0
			if sleep_pose != "" and posture._sleep_blend > 0.0:
				choice.exact = false
				if posture.kind == "lie_down" and style != "" and absf(posture._sleep_blend - minf(1.0, posture.source_time / sleep_seconds)) < 0.05:
					choice.clip = "lie_down_sleep_" + sleep_pose
					choice.exact = true
		"exit":
			choice.clip = posture.clip
			if sleep_pose != "" and posture._sleep_blend > 0.0:
				choice.exact = false
				if posture.kind == "lie_down" and absf(posture._sleep_blend - maxf(0.0, 1.0 - posture.source_time / (sleep_seconds * 0.6))) < 0.05:
					choice.clip = "lie_down_stand_sleep_" + sleep_pose
					choice.exact = true
		"recover":
			choice.clip = BAKED_GAITS.STAND
			choice.blend = 0.2
			choice.hold = true
		_:
			choice.hold = true
			var sleep: bool = sleep_pose != "" and posture._sleep_blend > 0.0
			if sleep and style != "":
				choice.clip = "sleep_" + sleep_pose
				choice.blend = (1.0 - posture._sleep_blend) * posture.sleep_seconds(style)
			else:
				choice.clip = posture.kind + "_hold"
				choice.blend = posture._sleep_blend * posture.sleep_seconds("") if sleep else 0.18
			choice.exact = posture._sleep_blend <= 0.0 or posture._sleep_blend >= 1.0
	return choice
