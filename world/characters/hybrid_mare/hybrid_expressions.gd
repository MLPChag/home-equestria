extends RefCounted
## Expression weights for the hybrid mare's native face (mouth smile pose, lid relaxation).
##
## Three layers, the largest wins:
## - The default face, the closed smile at full (`rest_smile` 1.0; dev 2026-10-01 picked it from the
##   front-view renders as the OpenPony resting mouth), walking included; at SPEAKING_SMILE
##   while she talks; replaced only by a dialogue face with a mouth of its own.
## - Player interest (from HybridAttention): a warmer smile and softly half-lidded eyes while
##   she is looking at the player.
## - Occasional bigger smiles, some of them relaxed (half-lidded), between quiet rests.
## This changes expression weights only; it never plays a body animation.
## The open grins (smile_big, smile_teeth) are out of the line faces for now (dev 2026-10-14: "remove
## the smile expression, it's creepy with the static eyes"); brows and ears still carry the mood.
## No line face opens the mouth (dev 2026-10-15, fifth time: "remove the confused open mouth
## thing"): "surprised" lost its open_lips gape, which held through the line and 3 s after it.
## Surprise and confusion live in brows, eyes and ears; only speech visemes open the mouth.
## tools/life/test_closed_mouth_faces.gd guards every face here on the real rig.
const LINE_FACES := {
	"neutral": {"mouth":{}, "lids":0.0},
	"happy": {"mouth":{}, "lids":0.0, "brows":"brows_happy_right", "weight":.8, "ears":"ears_alert", "ear_weight":.65},
	"amused": {"mouth":{}, "lids":.28, "brows":"brows_happy_right", "weight":.95, "ears":"ears_side", "ear_weight":.16},
	"relaxed": {"mouth":{"smile":.65}, "lids":.48, "ears":"ears_side", "ear_weight":.33},
	"shy": {"mouth":{"smile":.25}, "lids":.18, "brows":"brows_sad", "weight":.65, "blush":.85, "ears":"ears_side", "ear_weight":.52},
	"sad": {"mouth":{"frown_big":.8}, "lids":0.0, "brows":"brows_sad", "weight":.9, "eyes":"eyes_sad", "eye_weight":.8, "ears":"ears_side", "ear_weight":.65},
	"annoyed": {"mouth":{"frown":.75,"pout":.1}, "lids":0.0, "brows":"brows_angry", "weight":.65, "eyes":"eyes_mad", "eye_weight":.5, "ears":"ears_agitated", "ear_weight":.3},
	"angry": {"mouth":{"frown_big":.95}, "lids":0.0, "brows":"brows_angry", "weight":1.0, "eyes":"eyes_mad", "eye_weight":.9, "ears":"ears_agitated", "ear_weight":.58},
	"surprised": {"mouth":{}, "lids":0.0, "brows":"brows_wide", "weight":1.0, "eyes":"eyes_wide", "eye_weight":1.0, "ears":"ears_alert", "ear_weight":1.0},
	"confused": {"mouth":{}, "lids":0.0, "brows":"brows_confused_left", "weight":1.0, "ears":"ears_alert", "ear_weight":.3},
}
const LINE_MOUTH_SHAPES := ["smile_big","smile_teeth","frown","frown_big","pout","open_lips"]
var dialogue_face := ""
var blush_weight := 0.0
var _line_mix := 0.0
const DIALOGUE_RELEASE_DELAY := 3.0
var _line_release := -1.0
var _line_weights: Dictionary = {}
var _line_brows: Dictionary = {}
var brow_visuals: Array[MeshInstance3D] = []
var brow_amount := 0.0

func bind_brow_visual(mesh: MeshInstance3D) -> void:
	if mesh not in brow_visuals: brow_visuals.append(mesh)
	_write_brow_ink(mesh)

func _write_brow_ink(mesh: MeshInstance3D) -> void:
	# Dummy RenderingServer has no spatial shader instance-parameter storage. The
	# expression state remains available to behavior tests; Forward+ owns the ink.
	if DisplayServer.get_name() == "headless" or mesh.is_queued_for_deletion(): return
	mesh.set_instance_shader_parameter("brow_amount", brow_amount)

func _apply_brow_ink() -> void:
	# Pose weights are already eased. Match ink to that same transition, without a
	# threshold that could pop or blink. Rest/interest smiles never add idle eyebrows.
	brow_amount = 0.0
	for weight: float in eyes.expression_brows.values(): brow_amount = maxf(brow_amount, weight)
	if brow_amount < 0.0001: brow_amount = 0.0
	for mesh: MeshInstance3D in brow_visuals:
		if is_instance_valid(mesh): _write_brow_ink(mesh)
var _line_eyes: Dictionary = {}
var _line_ears: Dictionary = {}
var _line_lids := 0.0
var _line_smile := 0.0

func set_dialogue(value: String) -> void:
	dialogue_face = value if LINE_FACES.has(value) else ""
	_line_release = -1.0

## The director finishes the whole spoken reply, not each synthesized sentence.
## A replacement face cancels this countdown; no timer/callback can clear a later turn.
func finish_dialogue(delay := DIALOGUE_RELEASE_DELAY) -> void:
	if not dialogue_face.is_empty(): _line_release = maxf(0.0, delay)

func clear_dialogue() -> void:
	dialogue_face = ""
	_line_release = -1.0

var mouth: PonyMouth
var eyes: SkeletonModifier3D
var rng := RandomNumberGenerator.new()
var preview := -1 # -1 automatic, 0 small smile, 1 relaxed smile
var rest_smile := 1.0
const SPEAKING_SMILE := 0.6
var interest_smile := 0.5
var interest_lids := 0.22
var idle_lids_enabled := true
var smile_weight := 0.0
var lid_weight := 0.0
var _rest := 0.0      # eased resting-smile weight
var _wait := 4.0
var _time := -1.0
var _hold := 3.0
var _smile := 0.65
var _lids := 0.0
var _cancel_time := -1.0
var _cancel_smile := 0.0
var _cancel_lids := 0.0
var _boop_time := -1.0
var _kiss_time := -1.0
## Boop reaction seconds: eyes shut (rise, hold, release) and the big smile's length.
var boop_shut_rise := 0.1
var boop_shut_hold := 1.1
var boop_shut_release := 0.35
var boop_smile_length := 2.8
var _touches:Dictionary={}
var _touch_weights:=Vector2.ZERO
## Flustered loop (dev 2026-09-28) while booped or kissed: eyes squeezed shut, a peek, shut
## again, at random; ears pinned back and a shy smile. The mare spreads her blush across the
## nose with `fluster_amount`. fluster() keeps it going; it eases out once the contact stops.
var fluster_amount := 0.0
var _fluster_left := 0.0
var _fluster_peeks := true
var _fluster_step := 0.0
var _fluster_lids := 0.0
var _fluster_goal := 1.0
func fluster(seconds: float, peeks := true) -> void:
	_fluster_left = maxf(_fluster_left, seconds)
	_fluster_peeks = peeks
func flustered() -> bool:
	return _fluster_left > 0.0
## A half-lidded gaze that overrides every other lid source while on (deep-kiss breather).
var stare_lids := .5
var _stare_goal := 0.0
var _stare_mix := 0.0
func stare(on: bool, lids := .5) -> void:
	_stare_goal = 1.0 if on else 0.0
	stare_lids = lids
func touch(source:String,smile:float,lids:float) -> void:
	_touches[source]=Vector2(clampf(smile,0,1),clampf(lids,0,1))
func release_touch(source:String) -> void:
	_touches.erase(source)


func bind(native_mouth: PonyMouth, native_eyes: SkeletonModifier3D) -> void:
	mouth = native_mouth
	eyes = native_eyes
	# From the global generator: random in game, repeatable in a test that calls seed().
	rng.seed = randi()
	_wait = rng.randf_range(3.0, 6.0)


func set_preview(value: int) -> void:
	preview = value
	_time = -1.0
	_cancel_time = -1.0
	_wait = rng.randf_range(8.0, 16.0)
	_apply(0.0 if value < 0 else 0.65, 0.42 if value == 1 else 0.0)


## `resting`: standing still and not speaking. `interest`: 0..1 from HybridAttention.
## `speaking`: her voice is playing (the default face gives way to the mouth shapes).
func advance(delta: float, resting: bool, interest: float = 0.0, speaking := false) -> void:
	if preview >= 0: return
	if _line_release >= 0.0:
		_line_release -= delta
		if _line_release <= 0.0: clear_dialogue()
	_stare_mix = move_toward(_stare_mix, _stare_goal, delta / .25)
	# Talking keeps most of it: the mouth shapes yield to it in PonyMouth anyway.
	_rest = move_toward(_rest, rest_smile * (SPEAKING_SMILE if speaking else 1.0), delta / 0.6)
	var episode := _episode(delta, resting)
	var warm := clampf(interest, 0.0, 1.0)
	var booped := _boop(delta).max(_fluster(delta))
	var kissed := _kiss(delta)
	var tactile:=Vector2.ZERO
	for value:Vector2 in _touches.values():tactile=tactile.max(value)
	_touch_weights=_touch_weights.lerp(tactile,1.0-exp(-delta/.22))
	if dialogue_face.is_empty() and _line_mix < .0001:
		if _line_mix > 0.0:
			_line_mix=0.0;_line_lids=0.0;_line_smile=0.0;blush_weight=0.0
			_line_weights.clear();_line_brows.clear();eyes.expression_brows.clear()
			_line_eyes.clear();_line_ears.clear();eyes.expression_eyes.clear();eyes.expression_ears.clear()
			for shape in LINE_MOUTH_SHAPES:mouth.set_expression(shape,0.0)
		_apply(maxf(maxf(maxf(_rest,episode.x),interest_smile*warm),maxf(booped.x,_touch_weights.x)),
			maxf(maxf(maxf(episode.y,interest_lids*warm),maxf(booped.y,kissed)),_touch_weights.y))
		return
	var active := not dialogue_face.is_empty()
	var target: Dictionary = LINE_FACES.get(dialogue_face, {})
	var ease := 1.0 - exp(-delta / (.22 if active else .38))
	_line_mix = lerpf(_line_mix, 1.0 if active else 0.0, ease)
	# Retain the last requested face during its fade, but return every weight to zero.
	var mouth_target: Dictionary = target.get("mouth", {})
	_line_smile = lerpf(_line_smile, float(mouth_target.get("smile",0.0)), ease)
	_line_lids = lerpf(_line_lids, float(target.get("lids",0.0)), ease)
	blush_weight = lerpf(blush_weight, float(target.get("blush",0.0)), ease)
	var physical_smile := maxf(booped.x,_touch_weights.x)
	var physical_lids := maxf(maxf(booped.y,kissed),_touch_weights.y)
	for shape in LINE_MOUTH_SHAPES:
		_line_weights[shape] = lerpf(float(_line_weights.get(shape,0.0)),float(mouth_target.get(shape,0.0)),ease)
		mouth.set_expression(shape,_line_weights[shape] * (1.0-physical_lids))
	for name in ["brows_happy_right","brows_sad","brows_angry","brows_wide","brows_confused_left"]:
		_line_brows[name]=lerpf(float(_line_brows.get(name,0.0)),float(target.get("weight",0.0)) if target.get("brows","")==name else 0.0,ease)
		eyes.expression_brows[name]=_line_brows[name]*(1.0-physical_lids)
	for name in ["eyes_sad","eyes_mad","eyes_wide"]:
		_line_eyes[name]=lerpf(float(_line_eyes.get(name,0.0)),float(target.get("eye_weight",0.0)) if target.get("eyes","")==name else 0.0,ease)
		eyes.expression_eyes[name]=_line_eyes[name]*(1.0-physical_lids)
	for name in ["ears_alert","ears_side","ears_agitated"]:
		_line_ears[name]=lerpf(float(_line_ears.get(name,0.0)),float(target.get("ear_weight",0.0)) if target.get("ears","")==name else 0.0,ease)
		eyes.expression_ears[name]=_line_ears[name]*(1.0-physical_lids)*(1.0-fluster_amount)
	var ordinary_smile := maxf(maxf(_rest,episode.x),interest_smile*warm)
	var ordinary_lids := maxf(episode.y,interest_lids*warm)
	# A face with a mouth of its own (sad, annoyed, angry...) replaces the smile; one without
	# ("neutral", "confused", "surprised") keeps the default closed face.
	var mouth_mix := _line_mix if not mouth_target.is_empty() else 0.0
	_apply(maxf(ordinary_smile*(1.0-mouth_mix)+_line_smile,physical_smile),
		maxf(ordinary_lids*(1.0-_line_mix)+_line_lids,physical_lids))


## Gentle native eyelid closure; independent of the boop flinch/squee.
func kiss() -> void:
	_kiss_time = 0.0


func _kiss(delta: float) -> float:
	if _kiss_time < 0.0: return 0.0
	_kiss_time += delta
	if _kiss_time < 0.12: return smoothstep(0.0, 0.12, _kiss_time)
	if _kiss_time < 0.85: return 1.0
	if _kiss_time < 1.25: return 1.0 - smoothstep(0.85, 1.25, _kiss_time)
	_kiss_time = -1.0
	return 0.0


## A boop: eyes squeezed shut for a moment and a big smile that outlasts them.
func boop() -> void:
	_boop_time = 0.0


func _fluster(delta: float) -> Vector2:
	_fluster_left = maxf(0.0, _fluster_left - delta)
	fluster_amount = move_toward(fluster_amount, 1.0 if _fluster_left > 0.0 else 0.0, delta / (.25 if _fluster_left > 0.0 else .9))
	if eyes != null:
		if fluster_amount > .001: eyes.expression_ears["ears_pinned"] = .9 * fluster_amount
		else: eyes.expression_ears.erase("ears_pinned")
	if fluster_amount <= 0.0: return Vector2.ZERO
	_fluster_step -= delta
	if _fluster_step <= 0.0:
		# Mostly squeezed shut; now and then a peek or a soft half-lid. A deep kiss rarely peeks.
		var roll := rng.randf()
		var shut := .55 if _fluster_peeks else .85
		_fluster_goal = 1.0 if roll < shut else (.1 if roll < shut + (1.0 - shut) * .55 else .55)
		_fluster_step = rng.randf_range(.4, 1.2) if _fluster_goal > .99 else rng.randf_range(.15, .45)
	_fluster_lids = move_toward(_fluster_lids, _fluster_goal, delta / .09)
	return Vector2(.55, _fluster_lids) * fluster_amount


func _boop(delta: float) -> Vector2:
	if _boop_time < 0.0: return Vector2.ZERO
	_boop_time += delta
	var t := _boop_time
	var shut: float
	if t < boop_shut_rise: shut = smoothstep(0.0, 1.0, t / boop_shut_rise)
	elif t < boop_shut_rise + boop_shut_hold: shut = 1.0
	else: shut = 1.0 - smoothstep(0.0, 1.0, (t - boop_shut_rise - boop_shut_hold) / boop_shut_release)
	var smile := 0.75 * _ease(t / 0.3) * (1.0 - _ease((t - boop_smile_length + 0.9) / 0.9))
	if t >= boop_smile_length:
		_boop_time = -1.0
		return Vector2.ZERO
	return Vector2(smile, shut)


## The occasional bigger smile: (smile, lids) for this tick.
func _episode(delta: float, resting: bool) -> Vector2:
	if not resting and _time >= 0.0 and _cancel_time < 0.0:
		_cancel_time = 0.0
		_cancel_smile = _smile * _amount()
		_cancel_lids = _lids * _amount()
	if _cancel_time >= 0.0:
		_cancel_time += delta
		var amount := 1.0 - _ease(_cancel_time / 0.55)
		if _cancel_time >= 0.55:
			_cancel_time = -1.0
			_time = -1.0
			_wait = rng.randf_range(8.0, 16.0)
			return Vector2.ZERO
		return Vector2(_cancel_smile * amount, _cancel_lids * amount)
	if _time < 0.0:
		# Require a quiet rest before starting; movement does not bank a smile.
		if not resting:
			_wait = maxf(_wait, 3.0)
			return Vector2.ZERO
		_wait -= delta
		if _wait > 0.0: return Vector2.ZERO
		_time = 0.0
		_hold = rng.randf_range(2.0, 4.0)
		_smile = rng.randf_range(0.5, 0.75)
		_lids = rng.randf_range(0.36, 0.45) if idle_lids_enabled and rng.randf() < 0.4 else 0.0
	_time += delta
	var amount := _amount()
	if _time >= 0.9 + _hold + 1.3:
		_time = -1.0
		_wait = rng.randf_range(12.0, 24.0)
	return Vector2(_smile * amount, _lids * amount)


func _amount() -> float:
	if _time < 0.0: return 0.0
	return _ease(_time / 0.9) * (1.0 - _ease((_time - 0.9 - _hold) / 1.3))


func _apply(smile: float, lids: float) -> void:
	_apply_brow_ink()
	lids = lerpf(lids, stare_lids, _stare_mix)
	smile_weight = smile
	lid_weight = lids
	mouth.set_expression("smile", smile)
	eyes.expression_closure = lids


static func _ease(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
