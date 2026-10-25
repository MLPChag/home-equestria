extends RefCounted
## Spike sits, lies down and stands up through the same requests a pony's posture takes
## (pony_posture.gd): request("sit" | "lie_down" | "stand"), settled(), active(), reset(), and the
## fields other systems read (kind, requested, progress, refusal, phase). His body plays the clip
## for the state (spike.gd); progress is the clip crossfade, so a request settles in about half a
## second. Asleep he only lies; on a seat (meta "seated") his sit is the chair clip.

const SECONDS := 0.5
var pony: CharacterBody3D
var requested := "stand"
var kind := "sit"
var progress := 0.0
var rate := 0.0
var refusal := ""
var ready := true
var phase := "stand"
var seated_seconds := 0.0
## After sitting this long with nothing to do he lies down on his own, as ponies do.
var lie_after_seconds := 45.0
var automatic_rest := true
var intentional_rest := false

func bind(actor: CharacterBody3D) -> void:
	pony = actor

func active() -> bool: return progress > 0.0 or requested != "stand"

func settled() -> bool: return (progress == 1.0 and requested == kind) or (progress == 0.0 and requested == "stand")

func rescale(_relative: float) -> void: pass

func request(value: String) -> bool:
	refusal = ""
	if value not in ["sit", "lie_down", "stand"]: refusal = "Unknown posture"; return false
	if pony.get("sleeping") == true and value != "lie_down": refusal = "Asleep until waking"; return false
	if value == "stand" and pony.has_meta("cuddle_session"):
		var cuddle: Node = pony.get_meta("cuddle_session")
		if cuddle.enabled or cuddle.blend > 0.0: cuddle.end()
	if value == "stand": intentional_rest = false; requested = value; return true
	if pony._held or pony.carry.blend > 0.0: refusal = "Cannot lower while held"; return false
	if not pony.grounded(): refusal = "No ground support"; return false
	if pony.actual_speed > .05: refusal = "Wait until stopped"; return false
	if not active() or kind != value:
		# Changing between sit and lie goes through the crossfade directly (no stand in between).
		kind = value
		phase = "enter"
	requested = value
	seated_seconds = 0.0
	pony.stop()
	return true

func reset(_retain_limits := false) -> void:
	intentional_rest = false
	seated_seconds = 0.0
	requested = "stand"; phase = "stand"; progress = 0.0; rate = 0.0

## The lie-down flop a pony does after a hard landing.
func impact_flop() -> void:
	kind = "lie_down"; requested = kind; progress = 1.0; phase = "hold"

func update(delta: float) -> void:
	var goal := 1.0 if requested != "stand" else 0.0
	var before := progress
	progress = move_toward(progress, goal, delta / SECONDS)
	rate = (progress - before) / maxf(delta, 1e-4)
	if progress == 0.0: phase = "stand"
	elif progress == 1.0: phase = "hold"
	elif goal > 0.0: phase = "enter"
	else: phase = "exit"
	if requested == "sit" and progress == 1.0:
		seated_seconds += delta
		if automatic_rest and not intentional_rest and seated_seconds > lie_after_seconds and not pony.has_meta("seated") \
				and not is_instance_valid(pony.get("conversation_target")):
			request("lie_down")
	elif requested != "sit":
		seated_seconds = 0.0

## The body clip for this posture right now ("" when standing).
func clip() -> String:
	if progress <= 0.0 and requested == "stand": return ""
	if kind == "lie_down": return "sleep" if pony.get("sleeping") == true else "lie"
	return "sit_chair" if pony.has_meta("seated") else "sit"
