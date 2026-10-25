extends RefCounted
## One bounded facial expression per spoken line. Tags are never spoken or remembered.
const NAMES := ["neutral", "happy", "amused", "relaxed", "shy", "sad", "annoyed", "angry", "surprised", "confused"]
const PROMPT := "Expression tags (optional, sparing, never spoken): a line may start with one face for that line, [face:NAME] with NAME neutral, happy, amused, relaxed, shy, sad, annoyed, angry, surprised or confused ([face:happy] Good to see you.), then optionally a voice emotion, usually omitted: [neutral] [happy] [sad] [angry] [annoyed] [fearful] [surprised] [calm] [shouting]. Occasionally, when a real pony would move while talking, one gesture as the line starts: [hoofraise] (or [hoofraise:left]/[hoofraise:right]) lifts a curled forehoof to make a point, greet, plead or emphasise; [excited] shows excitement (a pegasus spreads her wings, a unicorn's horn sparks, an earth pony kicks up a hind hoof); unicorns and alicorns only: [magic] lights the horn a moment; pegasi and alicorns only: [wings:spread] holds the wings open a few seconds, [wings:flutter] gives a quick excited open-and-shut."
## Spike's own gestures (wave, cheer, point, shrug, fire, eat) are explained in his prompt only
## (world/ai/prompts/spike.md), so the shared prompt above costs every pony nothing extra.
const GESTURES := ["hoofraise", "magic", "wings", "excited", "wave", "cheer", "point", "shrug", "fire", "eat"]

static func parse(text: String) -> Dictionary:
	var regex := RegEx.new()
	regex.compile("(?i)\\[face\\s*:\\s*([^\\]\\r\\n]*)\\]")
	var expression := ""
	for match_value in regex.search_all(text):
		var value := match_value.get_string(1).strip_edges().to_lower()
		if expression.is_empty() and value in NAMES: expression = value
	var gestures := RegEx.new()
	gestures.compile("(?i)\\[\\s*(hoofraise|magic|wings|excited|wave|cheer|point|shrug|fire|eat)\\s*(?::\\s*(left|right|spread|flutter)\\s*)?\\]")
	var gesture := ""
	var found := gestures.search(text)
	if found != null: gesture = found.get_string(1).to_lower() + (":" + found.get_string(2).to_lower() if found.get_string(2) != "" else "")
	var speech := gestures.sub(regex.sub(text, "", true), "", true)
	return {"speech":speech.strip_edges(), "face":expression, "gesture":gesture}
