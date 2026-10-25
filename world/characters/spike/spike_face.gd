extends RefCounted
## Spike's face: the model's own shape keys (brows, lids, mouth) and the drawn eyes
## (spike_eye.gdshader). Same public calls as hybrid_expressions.gd, so the conversation director,
## relationships and touch code drive him like any pony: set_dialogue / finish_dialogue /
## clear_dialogue, touch / release_touch, stare, fluster, kiss, boop. Speech visemes come from the
## same Rhubarb cues the ponies' heads use (lip_sync.gd).
## Like the ponies, no line face opens his mouth (dev 2026-10-15); only speech does.

const DIALOGUE_RELEASE_DELAY := 3.0
## Line faces by the same names as the ponies' (hybrid_expressions.gd LINE_FACES), as shape keys.
const LINE_FACES := {
	"neutral": {},
	"happy": {"Happy": 0.65, "EyebrowsUpper": 0.25},
	"amused": {"Smirk": 0.7, "LidDown": 0.25, "Happy": 0.2},
	"relaxed": {"Relaxed": 0.75, "LidDown": 0.35},
	"shy": {"Happy": 0.3, "LidDown": 0.25, "EyebrowsUpper": 0.35, "blush": 0.85},
	"sad": {"Sad": 0.9, "Frown": 0.55},
	"annoyed": {"Angry": 0.5, "MouthAngry": 0.35, "LidDown": 0.2},
	"angry": {"Angry": 1.0, "MouthAngry": 0.6},
	"surprised": {"Wide": 1.0, "EyebrowsUpper": 0.8},
	"confused": {"EyebrowsLowerer": 0.45, "Smirk": 0.25, "LidUp": 0.2},
}
## Rhubarb letters to mouth shapes (A closed MBP, B teeth/consonants, C open, D wide, E rounded,
## F puckered OO/W, G F/V lip bite, H L, X rest).
const VISEMES := {
	"A": {"MouthClosed": 0.6},
	"B": {"MouthOpen": 0.22, "MouthStretch": 0.25},
	"C": {"MouthOpen": 0.5, "MouthStretch": 0.15},
	"D": {"MouthOpen": 0.85},
	"E": {"MouthOpen": 0.3, "MouthO": 0.65},
	"F": {"MouthPuckerer": 0.8, "MouthO2": 0.25},
	"G": {"LipsBite": 0.7, "MouthOpen": 0.1},
	"H": {"MouthOpen": 0.38, "LipUp": 0.3},
	"X": {},
}
## Face names used above, mapped to the model's shape keys (the VN-VJ Spike: most come as a left
## and a right half). A name with no shape on this model is simply skipped.
const SHAPES := {
	"Angry": ["l_angry", "r_angry"], "Sad": ["l_sad", "r_sad"], "Relaxed": ["l_relaxed", "r_relaxed"],
	"Wide": ["l_wide", "r_wide"], "LidUp": ["l_lid_raise", "r_lid_raise"], "LidDown": ["l_lid_lowerer", "r_lid_lowerer"],
	"EyebrowsUpper": [], "EyebrowsLowerer": ["l_eyebrow_lowerer", "r_eyebrow_lowerer"], "Happy": ["l_happy", "r_happy"],
	"EyeClosed": ["eye_closer_left", "eye_closer_right"], "MouthOpen": ["jaw_open"], "MouthClosed": ["jaw_closer"],
	"Grin": ["grin"], "BigGrin": ["big_grin"], "Frown": ["l_frown", "r_frown"], "Smirk": ["l_smirk"],
	"LipUp": ["l_lip_up", "r_lip_up"], "LipDown": ["l_lip_down", "r_lip_down"], "MouthPuckerer": ["mouth_pucker"],
	"MouthStretch": ["l_stretch", "r_stretch"], "MouthFull": ["mouth_full"], "MouthAngry": ["mouth_angry"],
	"MouthNeutral": ["mouth_neutral"], "MouthS": ["mouth_S"], "MouthO": ["mouth_O"], "MouthO2": ["mouth_o2"],
	"LowerLipOut": ["lower_lip_out"], "LipsBite": ["lip_bite"], "NoseWrinkle": ["nose_wrinkle"],
}

var mesh: MeshInstance3D
var eye_materials: Array[ShaderMaterial] = []
var _index: Dictionary = {}          # shape name -> blend shape index
var _current: Dictionary = {}        # shape name -> weight now
var dialogue_face := ""
var _line_release := -1.0
var _touches: Dictionary = {}        # source -> Vector2(smile, lids)
var _stare := 0.0
var fluster_amount := 0.0
var _fluster_left := 0.0
var _kiss_left := 0.0
var _boop_left := 0.0
var blush_weight := 0.0
var _blink_left := 2.5
var _blink := 0.0
var rng := RandomNumberGenerator.new()
## Set by the actor each frame.
var sleeping := false
var mood := ""                       # a held mood face ("" none): asleep/sad states from outside
var viseme := "X"
var gaze := Vector2.ZERO             # UV units, + = his left / up
var _gaze_now := Vector2.ZERO
var pucker := 0.0                    # a kiss in progress (pony_affection asks through the actor)
var mouth_open := 0.0                # eating, fire breath

func bind(face_mesh: MeshInstance3D, eyes: Array[ShaderMaterial]) -> void:
	mesh = face_mesh
	eye_materials = eyes
	rng.randomize()
	if mesh == null or mesh.mesh == null: return
	for shape: String in SHAPES:
		var found: Array[int] = []
		for key: String in SHAPES[shape]:
			var i := mesh.find_blend_shape_by_name(key)
			if i >= 0: found.append(i)
		if not found.is_empty(): _index[shape] = found

func has_shapes() -> bool:
	return not _index.is_empty()

func set_dialogue(value: String) -> void:
	dialogue_face = value if LINE_FACES.has(value) else ""
	_line_release = -1.0

func finish_dialogue(delay := DIALOGUE_RELEASE_DELAY) -> void:
	if not dialogue_face.is_empty(): _line_release = maxf(0.0, delay)

func clear_dialogue() -> void:
	dialogue_face = ""
	_line_release = -1.0

func touch(source: String, smile: float, lids: float) -> void:
	_touches[source] = Vector2(smile, lids)

func release_touch(source: String) -> void:
	_touches.erase(source)

func stare(on: bool, lids := .5) -> void:
	_stare = lids if on else 0.0

func fluster(seconds: float, _peeks := true) -> void:
	_fluster_left = maxf(_fluster_left, seconds)

func flustered() -> bool:
	return _fluster_left > 0.0

func kiss() -> void:
	_kiss_left = 2.5

func boop() -> void:
	_boop_left = 1.6

## One frame of the face. `interest` 0..1 = how much he is looking at the player.
func advance(delta: float, _resting: bool, interest: float = 0.0, speaking := false) -> void:
	if _line_release >= 0.0:
		_line_release -= delta
		if _line_release < 0.0: dialogue_face = ""
	_fluster_left = maxf(0.0, _fluster_left - delta)
	_kiss_left = maxf(0.0, _kiss_left - delta)
	_boop_left = maxf(0.0, _boop_left - delta)
	fluster_amount = move_toward(fluster_amount, 1.0 if _fluster_left > 0.0 else 0.0, delta * 2.0)
	var target: Dictionary = {}
	# Rest face: a small easy smile, warmer while he looks at the player.
	target["Happy"] = 0.15 + 0.2 * interest
	var line: Dictionary = LINE_FACES.get(mood if dialogue_face.is_empty() else dialogue_face, {})
	for key: String in line:
		if key == "blush": continue
		target[key] = maxf(float(target.get(key, 0.0)), float(line[key]))
	if line.has("Sad") or line.has("Angry") or line.has("Wide"): target["Happy"] = 0.0
	for source: String in _touches:
		var t: Vector2 = _touches[source]
		target["Happy"] = maxf(float(target.get("Happy", 0.0)), t.x)
		target["LidDown"] = maxf(float(target.get("LidDown", 0.0)), t.y)
	if _stare > 0.0: target["LidDown"] = maxf(float(target.get("LidDown", 0.0)), _stare * 0.6)
	if fluster_amount > 0.0:
		target["Grin"] = 0.45 * fluster_amount
		target["EyebrowsUpper"] = maxf(float(target.get("EyebrowsUpper", 0.0)), 0.5 * fluster_amount)
	if _kiss_left > 0.0 or _boop_left > 0.0:
		target["EyeClosed"] = 0.85 if _boop_left > 0.8 else 0.0
		target["Happy"] = maxf(float(target.get("Happy", 0.0)), 0.8)
	var blush_goal := float(line.get("blush", 0.0))
	blush_goal = maxf(blush_goal, fluster_amount * 0.9)
	if _kiss_left > 0.0: blush_goal = 1.0
	blush_weight = move_toward(blush_weight, blush_goal, delta * 1.5)
	# Mouth: speech visemes on top of everything, else a pucker or an open mouth from an action.
	if speaking:
		for key: String in VISEMES.get(viseme, {}):
			target[key] = maxf(float(target.get(key, 0.0)), float(VISEMES[viseme][key]))
		target["Happy"] = minf(float(target.get("Happy", 0.0)), 0.35)
	if pucker > 0.0: target["MouthPuckerer"] = maxf(float(target.get("MouthPuckerer", 0.0)), pucker)
	if mouth_open > 0.0: target["MouthOpen"] = maxf(float(target.get("MouthOpen", 0.0)), mouth_open)
	# Blinks: every 2-6 s, a 0.14 s close and open; asleep, shut.
	_blink_left -= delta
	if _blink_left <= 0.0:
		_blink = 0.14
		_blink_left = rng.randf_range(2.0, 6.0)
	var blink := 0.0
	if _blink > 0.0:
		_blink -= delta
		blink = sin(clampf(_blink / 0.14, 0.0, 1.0) * PI)
	if sleeping: blink = 1.0
	target["EyeClosed"] = maxf(float(target.get("EyeClosed", 0.0)), blink)
	_apply(target, delta, speaking)
	_gaze_now = _gaze_now.lerp(gaze, minf(1.0, delta * 12.0))
	for material in eye_materials:
		material.set_shader_parameter("gaze", _gaze_now)

func _apply(target: Dictionary, delta: float, speaking: bool) -> void:
	if mesh == null: return
	for shape: String in _index:
		var goal := clampf(float(target.get(shape, 0.0)), 0.0, 1.0)
		var now := float(_current.get(shape, 0.0))
		# Mouth shapes follow speech fast; brows/lids ease; blinks snap.
		var rate := 18.0 if (speaking and shape.begins_with("Mouth") or shape.begins_with("Lip")) else (40.0 if shape == "EyeClosed" else 6.0)
		now = move_toward(now, goal, delta * rate)
		if absf(now - float(_current.get(shape, -1.0))) < 0.0005: continue
		_current[shape] = now
		for i: int in _index[shape]: mesh.set_blend_shape_value(i, now)
