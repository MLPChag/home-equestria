class_name PonyMouth
extends SkeletonModifier3D
## Mouth shapes for the OpenPony rig, blended on the Bento face bones.
##
## Base shapes are sampled at start-up from the devkit clips in the mare's
## AnimationPlayer (tools/export_openpony_anims.py): one shape = the delta of a
## set of face bones between the skeleton rest and one frame of one clip.
## Weights blend on top of whatever pose the body clip left on those bones, so
## an idle or a walk keeps playing while she talks. Visemes are Rhubarb Lip
## Sync's mouth shapes (A-H, X) expressed as weight mixes of the base shapes
## (VISEMES); expressions (smile, frown...) are a second layer added on top.
##
## Must be a child of the Skeleton3D (SkeletonModifier3D rule). Runs after the
## AnimationPlayer because the player writes the pose first, modifiers next.

## Bone name prefixes a mouth shape may touch. Eyes, brows and ears stay with
## the eye system; the nose stays still (sneeze wrinkles it).
const CROWD_PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under the crowd lab's --profile-cpu
const MOUTH := ["mFaceJaw", "mFaceChin", "mFaceTeethLower", "mFaceTeethUpper", "mFaceLip", "mFaceCheekLower"]
const TONGUE := ["mFaceTongue"]

## Base shapes: source clip, time in seconds (-1 = last frame), bone prefixes.
## Picked from tools/probe_openpony_mouth.gd (which bones each clip moves).
const SHAPES := {
	"open": {"clip": "sneeze", "time": 0.33, "bones": MOUTH},
	"open_soft": {"clip": "talk_2", "time": 1.13, "bones": MOUTH},
	"open_lips": {"clip": "mouth_open_tongue", "time": 0.0, "bones": MOUTH},
	"tongue": {"clip": "mouth_open_tongue", "time": 0.0, "bones": TONGUE},
	"pout": {"clip": "mouth_pout", "time": -1.0, "bones": MOUTH},
	"smile": {"clip": "mouth_smile", "time": -1.0, "bones": MOUTH},
	"smile_teeth": {"clip": "mouth_smile_teeth", "time": 0.0, "bones": MOUTH},
	"smile_big": {"clip": "mouth_smile_big", "time": -1.0, "bones": MOUTH},
	"frown": {"clip": "mouth_frown", "time": 0.0, "bones": MOUTH},
	"frown_big": {"clip": "mouth_frown_big", "time": 0.0, "bones": MOUTH},
	"neutral": {"clip": "mouth_neutral", "time": 0.0, "bones": MOUTH},
	"yikes": {"clip": "mouth_yikes", "time": 0.0, "bones": MOUTH},
	# The devkit's curled-lip poses (dev 2026-10-01: the resting face).
	"smirk": {"clip": "mouth_smirk", "time": -1.0, "bones": MOUTH},
	"catsmile": {"clip": "mouth_catsmile", "time": -1.0, "bones": MOUTH},
}

## Rhubarb mouth shapes -> base shape weights.
##   A closed (M B P)      B slightly open, teeth (most consonants, EE)
##   C open (EH AE)        D wide open (AA)        E rounded, slightly open (AO ER)
##   F puckered (UW OW W)  G upper teeth on lip (F V)   H tongue up (L)   X rest
## No smile_teeth in speech (dev 2026-10-14: its lopsided grin read as a creepy, confused mouth).
## Open shapes come from the talk clip (open_soft): the sneeze "open" throws the jaw and
## cheeks at a sneeze angle, which read as lips jutting out mid-sentence (dev).
const VISEMES := {
	"X": {},
	"A": {},
	"B": {"open_soft": 0.25},
	"C": {"open_soft": 0.7},
	"D": {"open_soft": 1.0, "open": 0.25},
	"E": {"open_soft": 0.45, "pout": 0.5},
	"F": {"pout": 0.9},
	"G": {"open_soft": 0.15},
	"H": {"open_soft": 0.45, "tongue": 0.3},
}
## How far the expression layer (resting smile) yields while a viseme is active: both are
## additive deltas on the same lip bones, stacked they overdrive the corners.
const EXPRESSION_YIELD := 0.75

## Seconds for a weight to travel 0 -> 1 (Rhubarb cues are 50-200 ms long).
@export var blend_time := 0.06

var current_viseme := "X"

var _shapes := {}      # name -> {bone_idx: {"q": Quaternion, "p": Vector3}}
var _bones: Array[int] = []
## PonyCrowd NEAR mares: full run every `rate_divisor`-th physics tick, cached writes between.
var rate_divisor := 1
var rate_phase := 0
## The last full run's writes, in bone order (re-applied on the skipped ticks).
var _written_bones := PackedInt32Array()
var _written_rotations: Array[Quaternion] = []
var _written_positions := PackedVector3Array()
## [bone names, rests, source clips] -> [shapes, bones]. Every head of a model samples the same
## shapes from the same shared clip library; build() did it again for each spawned pony.
static var _built := {}
var _weights := {}     # name -> current weight
var _targets := {}     # name -> target weight (visemes + expressions)
var _viseme_targets := {}
var _expression := {}


## Sample every shape in SHAPES from the player's clips. Returns the number of
## shapes that found their clip and moved at least one bone.
func build(player: AnimationPlayer) -> int:
	var skel := get_skeleton()
	if skel == null or player == null:
		return 0
	var names := PackedStringArray()
	var rests: Array[Transform3D] = []
	for i in skel.get_bone_count():
		names.append(skel.get_bone_name(i))
		rests.append(skel.get_bone_rest(i))
	var clips := []
	for shape_name in SHAPES:
		var clip: String = SHAPES[shape_name]["clip"]
		clips.append(player.get_animation(clip) if player.has_animation(clip) else null)
	var key := [names, rests, clips]
	if _built.has(key):
		# Shared, never edited: build() replaces _shapes instead of clearing it.
		_shapes = _built[key][0]
		_bones.assign(_built[key][1])
		return _shapes.size()
	_shapes = {}
	var bones := {}
	for shape_name in SHAPES:
		var def: Dictionary = SHAPES[shape_name]
		if not player.has_animation(def["clip"]):
			continue
		var anim := player.get_animation(def["clip"])
		var t: float = def["time"]
		if t < 0.0:
			t = anim.length
		t = clampf(t, 0.0, anim.length)
		var deltas := {}
		for i in anim.get_track_count():
			var bone := String(anim.track_get_path(i).get_subname(0))
			if not _matches(bone, def["bones"]):
				continue
			var idx := skel.find_bone(bone)
			if idx < 0:
				continue
			var rest := skel.get_bone_rest(idx)
			var d: Dictionary = deltas.get(idx, {"q": Quaternion.IDENTITY, "p": Vector3.ZERO})
			match anim.track_get_type(i):
				Animation.TYPE_ROTATION_3D:
					d["q"] = rest.basis.get_rotation_quaternion().inverse() * anim.rotation_track_interpolate(i, t)
				Animation.TYPE_POSITION_3D:
					d["p"] = anim.position_track_interpolate(i, t) - rest.origin
				_:
					continue
			deltas[idx] = d
		for idx in deltas.keys():
			var d: Dictionary = deltas[idx]
			if (d["q"] as Quaternion).get_angle() < 0.0005 and (d["p"] as Vector3).length() < 0.0001:
				deltas.erase(idx)
			else:
				bones[idx] = true
		if not deltas.is_empty():
			_shapes[shape_name] = deltas
	_bones.assign(bones.keys())
	_built[key] = [_shapes, _bones.duplicate()]
	return _shapes.size()


func shape_names() -> PackedStringArray:
	return PackedStringArray(_shapes.keys())


func shape_bone_count(shape_name: String) -> int:
	return (_shapes.get(shape_name, {}) as Dictionary).size()


## Rhubarb letter (A-H, X). Unknown letters read as X.
func set_viseme(letter: String, blend := -1.0) -> void:
	current_viseme = letter if VISEMES.has(letter) else "X"
	_viseme_targets = VISEMES[current_viseme]
	_retarget(blend)


## One base shape at a weight, for labs and captures. Replaces the viseme mix.
func set_shape(shape_name: String, weight: float, blend := -1.0) -> void:
	current_viseme = ""
	_viseme_targets = {shape_name: weight} if weight > 0.0 else {}
	_retarget(blend)


## Persistent layer under the visemes (smile while talking).
func set_expression(shape_name: String, weight: float, blend := -1.0) -> void:
	if weight > 0.0:
		_expression[shape_name] = weight
	else:
		_expression.erase(shape_name)
	_retarget(blend)


func clear(blend := -1.0) -> void:
	_expression.clear()
	set_viseme("X", blend)


func weight_of(shape_name: String) -> float:
	return _weights.get(shape_name, 0.0)


func _retarget(blend: float) -> void:
	_targets = {}
	var activity := 0.0
	for k in _viseme_targets:
		_targets[k] = _viseme_targets[k]
		activity += _viseme_targets[k]
	var expression_scale := 1.0 - EXPRESSION_YIELD * clampf(activity, 0.0, 1.0)
	for k in _expression:
		_targets[k] = minf(_targets.get(k, 0.0) + _expression[k] * expression_scale, 1.0)
	if blend == 0.0:
		_weights = _targets.duplicate()
		for k in _weights.keys():
			if _weights[k] <= 0.0:
				_weights.erase(k)


func _unprofiled_process_modification() -> void:
	var skel := get_skeleton()
	if skel == null or _bones.is_empty():
		return
	if rate_divisor > 1 and ((Engine.get_physics_frames() + rate_phase) % rate_divisor) != 0:
		# Clip-tier mare: re-apply the last full run (Skeleton3D reverts modifier writes).
		for k in _written_bones.size():
			skel.set_bone_pose_rotation(_written_bones[k], _written_rotations[k])
			skel.set_bone_pose_position(_written_bones[k], _written_positions[k])
		return
	_written_bones.resize(0)
	_written_rotations.clear()
	_written_positions.resize(0)
	# Ease the weights toward their targets.
	var step := 1.0 if blend_time <= 0.0 else get_process_delta_time() * rate_divisor / blend_time
	for k in _targets:
		_weights[k] = move_toward(_weights.get(k, 0.0), _targets[k], step)
	for k in _weights.keys():
		if not _targets.has(k):
			var w: float = move_toward(_weights[k], 0.0, step)
			if w <= 0.0:
				_weights.erase(k)
			else:
				_weights[k] = w
	if _weights.is_empty():
		return
	for idx in _bones:
		var q := skel.get_bone_pose_rotation(idx)
		var p := skel.get_bone_pose_position(idx)
		var touched := false
		for shape_name in _weights:
			var w: float = _weights[shape_name] * influence
			if w <= 0.0001:
				continue
			var d: Variant = _shapes[shape_name].get(idx)  # no default: `{}` allocated per miss
			if d == null:
				continue
			q = q * Quaternion.IDENTITY.slerp(d["q"], minf(w, 1.0))
			p += (d["p"] as Vector3) * w
			touched = true
		if touched:
			q = q.normalized()
			skel.set_bone_pose_rotation(idx, q)
			skel.set_bone_pose_position(idx, p)
			_written_bones.append(idx)
			_written_rotations.append(q)
			_written_positions.append(p)


static func _matches(bone: String, prefixes: Array) -> bool:
	for prefix in prefixes:
		if bone.begins_with(prefix):
			return true
	return false


func _process_modification() -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_process_modification()
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("mouth", started)
