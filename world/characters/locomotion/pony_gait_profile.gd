extends Resource
## Imported trot poses and measured contacts, shared by terrain and step timing.

const SOLVER := preload("res://world/characters/locomotion/limb_solver.gd")
const CYCLE := 16.0 / 24.0
## Native clips baked by tools/import_gaits.py + tools/build_gaits.gd; the
## gallop is added to the model's AnimationPlayer next to its shipped trot at bind time.
const GAIT_LIBRARY := preload("res://world/characters/hybrid_mare/pony_gaits.res")
const GAIT_NAMES := ["walk", "trot", "gallop"]
## Walking folds each leg between its loaded endpoints instead of carrying
## the trot's airborne push-off into flight: the rear's backward kick, and the
## front's backward toe-drag that left the hoof hovering low exactly where the
## same-side hind lands (forging). Angles are in the model's bend plane.
const REAR_WALK_CURL := {"flank": 21.0, "femur": -45.0, "legLower": 30.0,
	"tarsal": -3.0, "hoof": -1.0}
## Forearm flexion carries the hoof forward and up; the shoulder counter-swing
## keeps it from overshooting the landing. tools/probe_front_curl_axes.gd
## measured about 5.5 cm of peak lift with no backward travel within limits.
const FRONT_WALK_CURL := {"shoulder": -18.0, "lowerArm": 45.0}
const DEFINITIONS := [
	["FL", "pony_shoulder_L", "pony_lowerArm_L", "pony_hand_L", "pony_finger_L_end"],
	["FR", "pony_shoulder_R", "pony_lowerArm_R", "pony_hand_R", "pony_finger_R_end"],
	["RL", "pony_flank_L", "pony_legLower_L", "pony_tarsal_L", "pony_hoof_L_end"],
	["RR", "pony_flank_R", "pony_legLower_R", "pony_tarsal_R", "pony_hoof_R_end"],
]

## Speed at which the shipped trot plays at 1x with its contact locks absorbing the
## remaining hoof slip; kept for older callers, cadence now follows each gait's own
## measured natural speed (see `gaits`).
@export var nominal_speed := 1.2
## Travel ceiling: the gallop catch-up limit measured by tools/probe_gait_reach.gd.
@export var max_travel_speed := 4.5
@export var acceleration := 2.5
@export var braking := 3.5
## Native navigation follower (docs/NAVIGATION_PHASE_2_2026_10_02.md): the lateral acceleration a
## turning pony keeps her planted contacts inside the 30 mm reach budget at (v * yaw_rate, m/s^2).
## tools/navigation/measure_turn_limits.gd, 2026-10-02: worst planted drift 29.9 mm at 2.8 m/s and
## 2 m/s^2 (27.8 mm straight), 31.2 mm at 3 m/s^2. Stepping turn on the spot: yaw rate (rad/s) of
## the deliberate supported turn used only where no walking arc exists; every tested rate exceeds
## the drift budget (178 mm at the conversation turn's 0.45 rad/s, 268 mm at 1.2), a known limit.
## Neither value changes joints, reach or contact tolerances.
@export var lateral_acceleration := 2.0
@export var stepping_turn_rate := 1.2
## Everyday travel bands in metres per second. Autonomous walks, explicit travel and
## group outings draw from these; nobody requests fractions of the old nominal speed.
## Measured on flat ground by tools/probe_gait_reach.gd (captures/gait/reach*.log):
## the four-beat walk keeps planted contacts inside the 30 mm reach budget up to about
## 0.5 m/s, the trot to 3.2 m/s, the gallop through the 4.5 m/s ceiling.
@export var walk_speed := Vector2(0.3, 0.36)
@export var trot_speed := Vector2(2.2, 3.1)
@export var gallop_speed := Vector2(3.2, 4.5)
## Gait switching: separate entry/exit speeds so terrain-speed noise cannot flicker,
## plus a minimum hold. Playback stays inside cadence_range x the clip's natural
## cadence; ground beyond that comes from stride extension within joint reach.
@export var trot_entry := 0.45
@export var trot_exit := 0.4
@export var gallop_entry := 3.0
@export var gallop_exit := 2.7
@export var gait_hold_seconds := 0.5
@export var gait_blend_seconds := 0.3
@export var cadence_range := Vector2(0.8, 1.3)
## Extra ground per stance the hoof may cover beyond the authored sweep, per gait
## (metres); measured against joint reach by tools/probe_gait_reach.gd.
@export var stride_extension := {"walk": 0.12, "trot": 0.16, "gallop": 0.2}
## Walking: the hoof sweep per stance grows from walk_sweep.x at walk_sweep_speed.x to
## walk_sweep.y at walk_sweep_speed.y (metres, m/s), and the folded swing quickens from
## authored tempo at walk_swing_speed.x to cadence_range.y at walk_swing_speed.y.
## The period never exceeds walk_period_max; quick steps, never a longer sweep.
@export var walk_sweep := Vector2(0.2, 0.3)
@export var walk_sweep_speed := Vector2(0.25, 0.4)
@export var walk_swing_speed := Vector2(0.5, 0.7)
@export var walk_period_max := 2.2
## Shortest four-beat period: one period across the whole everyday band, so a speed
## change inside the band never asks a loaded stance to finish faster than it can.
@export var walk_period_min := 1.2
## Body size multiplier (1 = canon show proportion). Authored sweeps, natural speeds,
## reach caps and the travel bands scale with it so a horse-sized pony walks like a horse.
var body_scale := 1.0


## Multiply every metres-per-second band and reach cap by `factor` (relative change).
func rescale(factor: float) -> void:
	body_scale *= factor
	walk_speed *= factor; trot_speed *= factor; gallop_speed *= factor
	trot_entry *= factor; trot_exit *= factor; gallop_entry *= factor; gallop_exit *= factor
	max_travel_speed *= factor; acceleration *= factor; braking *= factor; lateral_acceleration *= factor
	step_height *= factor; radius *= factor; clearance *= factor
	walk_sweep *= factor; walk_sweep_speed *= factor; walk_swing_speed *= factor
	for name in stride_extension: stride_extension[name] = float(stride_extension[name]) * factor
@export var max_slope_degrees := 35.0  # dev 2026-09-18: 20 disconnected every real hill in the walk grid
@export var step_height := 0.117
@export var wade_depth := 0.35
@export var swim := false
@export var radius := 0.45
@export var clearance := 1.2
@export var start_blend_seconds := 0.3
## Secondary motion preserves the imported gait; zero is useful for A/B review.
@export_range(0.0, 1.5) var sway_amount := 1.0
## Front walk curl, overridable by tuning probes before rebuild_walk_curls().
var front_walk_curl: Dictionary = FRONT_WALK_CURL
var hip_height := 0.586
var parents := PackedInt32Array()
var rest: Array[Transform3D] = []
var standing: Array[Transform3D] = []
var legs: Array[Dictionary] = []
var samples: Array = []
var animated_bones:=PackedInt32Array()
var blend_bones:=PackedInt32Array()
## Whole-body sampling skips the leg chains: their own phase/weight pass overwrites them.
## Derived after every bind, including gallop's additions to blend_bones.
var _body_animated_bones := PackedInt32Array()
var _body_blend_bones := PackedInt32Array()
## Immutable native sampling tables, rebuilt with the rig or tuned walk curls.
## Null retains the source-pose GDScript path (also with an older extension).
var native_sampler: RefCounted
## name -> {cycle, samples, animated_bones, legs: [{contact_start, contact_span,
## contact_weights, stance_travel}], natural_speed}. "trot" shares this profile's
## top-level arrays and leg tables; "walk" reuses the trot samples with its own cadence.
var gaits: Dictionary = {}
var _contact_phase := INF
var _contact_gait: Dictionary = {}
var _contact_before: Array[Transform3D] = []
var _contact_after: Array[Transform3D] = []
## Fitted bodies retain native rotations but rebase translation keys onto their
## own rest lengths. Empty for the existing mare/stallion, preserving that path.
var native_rest_positions: Dictionary = {}
## Fitted-body exports may contain only a rest-pose placeholder. Use an explicit
## native source before measuring contacts; never derive a gait from a static clip.
var native_trot: Animation
var _native_positions: Array[Vector3] = []
var _native_scales := PackedFloat32Array()


func bind(skeleton: Skeleton3D, player: AnimationPlayer) -> bool:
	native_sampler = null
	parents.clear()
	rest.clear()
	legs.clear()
	samples.clear()
	_contact_phase = INF
	if not player.has_animation("trot"):
		push_error("The native mare must include its original trot")
		return false
	for bone in skeleton.get_bone_count():
		var parent := skeleton.get_bone_parent(bone)
		if parent >= bone:
			return false
		parents.append(parent)
		rest.append(skeleton.get_bone_rest(bone))
	_native_positions.clear()
	_native_scales.clear()
	for bone in rest.size():
		var origin: Vector3 = native_rest_positions.get(skeleton.get_bone_name(bone), rest[bone].origin)
		_native_positions.append(origin)
		_native_scales.append(rest[bone].origin.length() / origin.length() if origin.length() > .00001 else 1.0)
	if native_trot != null:
		player.stop(true)
		var library_name := player.find_animation_library(player.get_animation("trot"))
		var library := player.get_animation_library(library_name).duplicate() as AnimationLibrary
		library.remove_animation("trot")
		library.add_animation("trot", retarget_native_animation(native_trot, skeleton))
		player.remove_animation_library(library_name)
		player.add_animation_library(library_name, library)
	var fk := SOLVER.forward_kinematics(parents, rest)
	var hips := skeleton.find_bone("pony_hips")
	if hips < 0:
		return false
	hip_height = fk[hips].origin.y
	standing = rest.duplicate()
	for definition in DEFINITIONS:
		var indices: Array[int] = []
		for name in definition.slice(1):
			var bone := skeleton.find_bone(name)
			if bone < 0:
				push_error("Missing native trot bone: " + name)
				return false
			indices.append(bone)
		var point := fk[indices[3]].origin
		var end_height := point.y
		point.y = 0.0
		var chain: Array[int] = []
		var ancestor := indices[3]
		while ancestor >= indices[0]:
			chain.append(ancestor)
			ancestor = parents[ancestor]
		var proximal_name := "pony_upperArm_" if String(definition[0]).begins_with("F") else "pony_femur_"
		var proximal := skeleton.find_bone(proximal_name + String(definition[0]).substr(1, 1))
		legs.append({"name": definition[0], "root": indices[0], "middle": indices[1],
			"proximal": proximal,
			"leaf": indices[2], "end": indices[3], "end_height": end_height, "chain": chain,
			"sole": fk[indices[2]].affine_inverse() * point,
			"standing_sole": point, "neutral_sole": point, "pole": Vector3.BACK,
			"sole_basis": fk[indices[2]].basis.orthonormalized()})
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	player.play("trot")
	# The imported keys start at 1/24 s, not zero. Sample those 16 original
	# frames and interpolate the last back to the first, avoiding a held first
	# frame followed by a hard seam every stride.
	for frame in 16:
		player.seek((frame + 1) / 24.0, true)
		var pose: Array[Transform3D] = []
		for bone in skeleton.get_bone_count():
			pose.append(skeleton.get_bone_pose(bone))
		samples.append(pose)
	player.seek(0.0, true)
	animated_bones.clear();blend_bones.clear()
	for bone in rest.size():
		var animated:=false;var differs:=false
		for pose:Array in samples:
			animated=animated or pose[bone]!=samples[0][bone]
			differs=differs or pose[bone]!=standing[bone]
		if animated:animated_bones.append(bone)
		if differs:blend_bones.append(bone)
	_measure_contacts()
	rebuild_walk_curls(skeleton)
	gaits.clear()
	gaits["trot"] = {"name": "trot", "cycle": CYCLE, "samples": samples, "animated_bones": animated_bones,
		"legs": legs, "natural_speed": _natural_speed(legs, CYCLE)}
	gaits["walk"] = gaits["trot"]
	_bind_gallop(player, skeleton)
	_bind_body_bones()
	_bind_native_sampler()
	return true


func _bind_native_sampler() -> void:
	native_sampler = null
	var backend := preload("res://world/characters/locomotion/native_solver.gd")
	if not backend.allowed or not backend.enabled("gait_sampling") or not ClassDB.class_exists("PonyGaitSampler"): return
	var sampler: RefCounted = ClassDB.instantiate("PonyGaitSampler")
	if sampler.configure(standing, samples, gaits.get("gallop", {}), legs, _body_animated_bones, _body_blend_bones):
		native_sampler = sampler


func _bind_body_bones() -> void:
	var leg_bones := {}
	for leg in legs:
		for bone: int in leg.chain: leg_bones[bone] = true
	_body_animated_bones.clear()
	_body_blend_bones.clear()
	for bone in animated_bones:
		if not leg_bones.has(bone): _body_animated_bones.append(bone)
	for bone in blend_bones:
		if not leg_bones.has(bone): _body_blend_bones.append(bone)


## The native gallop next to the shipped trot: same skeleton, its own cycle, contact
## windows and flight phases. Never retimed to trot contacts.
func native_position(bone: int, value: Vector3) -> Vector3:
	if native_rest_positions.is_empty(): return value
	return rest[bone].origin + (value - _native_positions[bone]) * _native_scales[bone]


func retarget_native_animation(source: Animation, skeleton: Skeleton3D) -> Animation:
	if native_rest_positions.is_empty(): return source
	var clip := source.duplicate() as Animation
	for track in clip.get_track_count():
		if clip.track_get_type(track) != Animation.TYPE_POSITION_3D: continue
		var path := clip.track_get_path(track)
		if path.get_subname_count() != 1: continue
		var bone := skeleton.find_bone(path.get_subname(0))
		if bone < 0: continue
		for key in clip.track_get_key_count(track):
			clip.track_set_key_value(track, key, native_position(bone, clip.track_get_key_value(track, key)))
	return clip


func _bind_gallop(player: AnimationPlayer, skeleton: Skeleton3D) -> void:
	if not player.has_animation("gallop"):
		player.stop(true)
		var libraries := player.get_animation_library_list()
		var library: AnimationLibrary = player.get_animation_library(libraries[0] if not libraries.is_empty() else "")
		library.add_animation("gallop", retarget_native_animation(GAIT_LIBRARY.get_animation("gallop"), skeleton))
	var clip: Animation = player.get_animation("gallop")
	player.play("gallop")
	var gait := {"name": "gallop", "cycle": clip.length, "samples": [], "animated_bones": PackedInt32Array(), "legs": []}
	const COUNT := 48
	for frame in COUNT:
		player.seek(clip.length * frame / COUNT, true)
		var pose: Array[Transform3D] = []
		for bone in skeleton.get_bone_count():
			pose.append(skeleton.get_bone_pose(bone))
		gait.samples.append(pose)
	player.seek(0.0, true)
	player.play("trot")
	player.seek(0.0, true)
	for bone in rest.size():
		var animated := false
		var differs := false
		for pose: Array in gait.samples:
			animated = animated or pose[bone] != gait.samples[0][bone]
			differs = differs or pose[bone] != standing[bone]
		if animated: gait.animated_bones.append(bone)
		if differs and not blend_bones.has(bone): blend_bones.append(bone)
	for leg in legs:
		gait.legs.append({"name": leg.name})
	gaits["gallop"] = gait
	_measure_contacts(gait)
	gait.natural_speed = _natural_speed(gait.legs, gait.cycle)


## Support-time-weighted mean of the authored hoof sweep over each leg's contact window.
static func _natural_speed(tables: Array, cycle: float) -> float:
	var travel := 0.0
	var seconds := 0.0
	for leg in tables:
		travel += float(leg.stance_travel)
		seconds += float(leg.contact_span) * cycle
	return travel / maxf(seconds, 0.001)


## Poses of every distinct native clip: joint limits are recovered from all authored
## motion, so the gallop's own reach is a rig limit, never a widened tolerance.
func calibration_samples() -> Array:
	var result: Array = samples.duplicate()
	for name in gaits:
		if gaits[name].name == name and name != "trot":
			result.append_array(gaits[name].samples)
	return result


func walk_stance_sweep(speed: float) -> float:
	var t := clampf((speed - walk_sweep_speed.x) / maxf(walk_sweep_speed.y - walk_sweep_speed.x, 0.01), 0.0, 1.0)
	return lerpf(walk_sweep.x, walk_sweep.y, t)


## Contact table for a gait and leg index (trot/walk share this profile's leg tables).
func gait_leg(gait: String, i: int) -> Dictionary:
	return gaits[gait].legs[i] if gaits.has(gait) else legs[i]


func gait_cycle(gait: String) -> float:
	return float(gaits[gait].cycle) if gaits.has(gait) else CYCLE


func gait_natural_speed(gait: String) -> float:
	return (float(gaits[gait].natural_speed) if gaits.has(gait) else nominal_speed) * body_scale


## Whole-body pose of a single-clock gait (gallop) at a phase; every leg on one clock.
func sample_gait_pose(gait: String, phase: float) -> Array[Transform3D]:
	if not gaits.has(gait) or gaits[gait].name == "trot":
		return sample_pose(phase)
	var table: Dictionary = gaits[gait]
	var frames: Array = table.samples
	var cursor := fposmod(phase, 1.0) * frames.size()
	var index := int(cursor)
	var result: Array[Transform3D] = frames[0].duplicate()
	for bone in table.animated_bones:
		result[bone] = frames[index][bone].interpolate_with(frames[(index + 1) % frames.size()][bone], cursor - index)
	return result


## Blend two whole-body poses (rotation slerp, offsets lerp): the body by `amount`,
## each leg chain by its own weight, so a planted hoof keeps the pose it landed with.
## Authored offsets/scales are never invented.
func blend_poses(from: Array[Transform3D], to: Array[Transform3D], amount: float,
		leg_amounts: PackedFloat64Array = PackedFloat64Array()) -> Array[Transform3D]:
	var result: Array[Transform3D] = from.duplicate()
	for bone in _body_blend_bones:
		result[bone] = from[bone].interpolate_with(to[bone], amount)
	for i in legs.size():
		var leg_amount := amount if leg_amounts.size() != legs.size() else float(leg_amounts[i])
		for bone: int in legs[i].chain:
			result[bone] = from[bone].interpolate_with(to[bone], leg_amount)
	return result


func rebuild_walk_curls(skeleton: Skeleton3D) -> void:
	var fk := SOLVER.forward_kinematics(parents, rest)
	for leg in legs:
		var table: Dictionary = REAR_WALK_CURL if String(leg.name).begins_with("R") else front_walk_curl
		leg.walk_lift = sample_pose(leg.contact_start + leg.contact_span)
		leg.walk_land = sample_pose(leg.contact_start)
		leg.walk_curl = {}
		for bone: int in leg.chain:
			var part := skeleton.get_bone_name(bone).trim_prefix("pony_").trim_suffix("_L").trim_suffix("_R")
			if table.has(part) and absf(float(table[part])) > 0.001:
				var axis := fk[parents[bone]].basis.orthonormalized().inverse() * Vector3.RIGHT
				leg.walk_curl[bone] = axis * deg_to_rad(table[part])
	# Tuning an already bound profile must refresh the copied native tables too.
	if native_sampler != null: _bind_native_sampler()


func sample_pose(phase: float) -> Array[Transform3D]:
	var cursor := fposmod(phase, 1.0) * samples.size()
	var index := int(cursor)
	var result:Array[Transform3D]=samples[0].duplicate()
	for bone in animated_bones:
		result[bone]=samples[index][bone].interpolate_with(
			samples[(index + 1) % samples.size()][bone], cursor - index)
	return result

func blended_steps(pose:Array[Transform3D],amount:float)->Array[Transform3D]:
	if amount>=1.0:return pose.duplicate()
	if amount<=0.0:return standing.duplicate()
	var result:Array[Transform3D]=standing.duplicate()
	for bone in _body_blend_bones:result[bone]=standing[bone].interpolate_with(pose[bone],amount)
	# Walk curling can move an otherwise constant bone.
	for leg in legs:
		for bone:int in leg.chain:
			result[bone]=standing[bone].interpolate_with(pose[bone],amount)
	return result


func sample_steps(body_phase: float, leg_phases: PackedFloat64Array, walk_amount: float = 0.0) -> Array[Transform3D]:
	var body_cursor := fposmod(body_phase, 1.0) * samples.size()
	var body_index := int(body_cursor)
	var result: Array[Transform3D] = samples[0].duplicate()
	for bone in _body_animated_bones:
		result[bone] = samples[body_index][bone].interpolate_with(
			samples[(body_index + 1) % samples.size()][bone], body_cursor - body_index)
	for i in legs.size():
		var progress := fposmod(leg_phases[i] - float(legs[i].contact_start), 1.0)
		var swing := clampf((progress - float(legs[i].contact_span)) / (1.0 - float(legs[i].contact_span)), 0.0, 1.0)
		var pose_phase := leg_phases[i]
		if swing > 0.0:
			# Ease out of push-off and into touchdown without stretching the
			# whole swing. The shorter recovery arc absorbs the middle's pace.
			var eased := swing - 0.35 * walk_amount * sin(TAU * swing) / TAU
			pose_phase = float(legs[i].contact_start) + float(legs[i].contact_span) + eased * (1.0 - float(legs[i].contact_span))
		var cursor := fposmod(pose_phase, 1.0) * samples.size()
		var index := int(cursor)
		# Every leg has a folding walk recovery between the same loaded
		# endpoints; the trot's airborne push-off is not part of a walk.
		var folding := swing > 0.0 and walk_amount > 0.0
		var curl := sin(PI * swing) ** 2
		for bone: int in legs[i].chain:
			result[bone] = samples[index][bone].interpolate_with(
				samples[(index + 1) % samples.size()][bone], cursor - index)
			if folding:
				var folded: Transform3D = legs[i].walk_lift[bone].interpolate_with(
					legs[i].walk_land[bone], smoothstep(0.0, 1.0, swing))
				if legs[i].walk_curl.has(bone):
					var bend: Vector3 = legs[i].walk_curl[bone]
					folded.basis = Basis(bend.normalized(), bend.length() * curl) * folded.basis
				# Sin-squared flexion has no angular impulse at either end;
				# only rotations change, never authored bone offsets or scales.
				var rotation := result[bone].basis.orthonormalized().get_rotation_quaternion()
				result[bone].basis = Basis(rotation.slerp(folded.basis.orthonormalized().get_rotation_quaternion(), walk_amount)).scaled_local(result[bone].basis.get_scale())
	return result


## Contact tables keyed on every input _measure_contacts reads (bone parents, the sampled
## clip poses, cycle, sole bones and heights), so ponies sharing a body skip ~1,500 FK passes
## per spawn. The whole key is compared on lookup, not just its hash.
static var _contact_cache := {}


func _measure_contacts(gait: Dictionary = {}) -> void:
	# Bind-time sampling avoids additional full-skeleton FK per leg per tick.
	const COUNT := 256
	var tables: Array = gait.legs if not gait.is_empty() else legs
	var name: String = gait.name if not gait.is_empty() else "trot"
	var ends := []
	for leg in legs: ends.append_array([leg.end, leg.end_height])
	var key := [parents, gait.samples if not gait.is_empty() else samples, gait_cycle(name), ends]
	var cached: Array = _contact_cache.get(key, [])
	if not cached.is_empty():
		for j in tables.size():
			var weights: PackedFloat32Array = cached[j][0]
			tables[j].contact_weights = weights.duplicate()
			tables[j].contact_start = cached[j][1]; tables[j].contact_span = cached[j][2]; tables[j].stance_travel = cached[j][3]
		return
	for leg in tables:
		leg.contact_weights = PackedFloat32Array()
	for i in COUNT:
		var phase := float(i) / COUNT
		var fk := SOLVER.forward_kinematics(parents, sample_gait_pose(name, phase))
		for j in tables.size():
			tables[j].contact_weights.append(contact_weight(legs[j], fk, phase, name))
	for j in tables.size():
		var leg: Dictionary = tables[j]
		var first := 0
		var span := 0
		for i in COUNT:
			if leg.contact_weights[i] >= 0.7 and leg.contact_weights[(i + COUNT - 1) % COUNT] < 0.7:
				first = i
				break
		while span < COUNT and leg.contact_weights[(first + span) % COUNT] >= 0.7:
			span += 1
		leg.contact_start = float(first) / COUNT
		leg.contact_span = float(maxi(span - 1, 1)) / COUNT
		var start_fk := SOLVER.forward_kinematics(parents, sample_gait_pose(name, leg.contact_start))
		var end_fk := SOLVER.forward_kinematics(parents, sample_gait_pose(name, leg.contact_start + leg.contact_span))
		leg.stance_travel = maxf(0.0, sole_point(legs[j], end_fk).z - sole_point(legs[j], start_fk).z)
	var result := []
	for leg in tables: result.append([leg.contact_weights.duplicate(), leg.contact_start, leg.contact_span, leg.stance_travel])
	# bind() clears parents and samples in place, so the stored key owns its copies.
	var frames: Array = key[1]
	_contact_cache[[parents.duplicate(), frames.duplicate(true), key[2], ends]] = result


func step_contact_weight(leg: Dictionary, phase: float) -> float:
	var weights: PackedFloat32Array = leg.contact_weights
	var cursor := fposmod(phase, 1.0) * weights.size()
	var index := int(cursor)
	return lerpf(weights[index], weights[(index + 1) % weights.size()], cursor - index)


func sole_point(leg: Dictionary, fk: Array[Transform3D]) -> Vector3:
	# The toe moves relative to the hand/tarsal during the original push-off.
	# A fixed offset in that ancestor erased precisely that movement.
	return fk[leg.end].origin - Vector3.UP * float(leg.end_height)


func contact_weight(leg: Dictionary, fk: Array[Transform3D], phase: float, gait: String = "trot") -> float:
	var lift := sole_point(leg, fk).y
	var cycle := gait_cycle(gait)
	if phase != _contact_phase or _contact_gait.get("name", "trot") != gait:
		_contact_phase = phase
		_contact_gait = gaits.get(gait, {"name": gait})
		_contact_before = SOLVER.forward_kinematics(parents, sample_gait_pose(gait, phase - 0.0125))
		_contact_after = SOLVER.forward_kinematics(parents, sample_gait_pose(gait, phase + 0.0125))
	var backwards_speed := (sole_point(leg, _contact_after).z - sole_point(leg, _contact_before).z) / (0.025 * cycle)
	return (1.0 - smoothstep(0.006, 0.028, lift)) * smoothstep(-0.05, 0.3, backwards_speed)
