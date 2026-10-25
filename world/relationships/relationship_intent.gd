extends RefCounted
## Conservative grammar for deliberate requests; ambiguous conversation stays dialogue.
## Entire utterances must match. Quoting, reported speech and conditional wording never consent.
static func whitespace(raw: String) -> String:
	var spacing := RegEx.new()
	spacing.compile("[ \t]+")
	return spacing.sub(raw.strip_edges(), " ", true)

static func normalize(raw: String, name: String = "") -> String:
	var text: String = whitespace(raw).to_lower().replace("’", "'")
	if text.contains('"') or text.contains("“") or text.contains("”") or text.contains("‘") or text.contains("`") or text.contains("\n"): return ""
	for prefix: String in [name.to_lower() + ", ", "hey " + name.to_lower() + ", "]:
		if not name.is_empty() and text.begins_with(prefix): text = text.trim_prefix(prefix)
	while text.ends_with(".") or text.ends_with("!") or text.ends_with("?"):
		text = text.left(text.length() - 1).strip_edges()
	for word: String in ["if", "maybe", "perhaps", "hypothetically", "imagine", "suppose", "supposing", "quote", "quoted", "saying", "said", "asked", "wonder", "wondering", "might", "unless", "whether"]:
		if matches(text, "(^|[^a-z])" + word + "([^a-z]|$)"): return ""
	if text.contains("'") and (text.begins_with("'") or text.ends_with("'")): return ""
	return text

static func matches(text: String, pattern: String) -> bool:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK: return false
	return regex.search(text) != null

static func parse(raw: String, name: String = "", answer_allowed: bool = true) -> Dictionary:
	var text: String = normalize(raw, name)
	if text.is_empty(): return {}
	if answer_allowed:
		if matches(text, "^(yes(,)?( please| absolutely| of course| i'd love to)?|absolutely|of course|sure(,)?( i'd love to)?|i accept|i'd love to|i would love to|let's do it|i do|that sounds (lovely|great|wonderful))$"):
			return {"type": "answer", "accept": true}
		if matches(text, "^(no(,)?( thanks| thank you)?|not now(,)?( thanks)?|i decline|i'm not ready|i am not ready|i don't want to|i do not want to)$"):
			return {"type": "answer", "accept": false}
	# Negation must not fall through into a request. Answers above deliberately allow no.
	if matches(text, "(^|[^a-z])(not|never|don't|do not|wouldn't|would not|can't|cannot|won't|will not)([^a-z]|$)"): return {}
	for prefix: String in ["please, ", "please "]:
		text = text.trim_prefix(prefix)
	for suffix: String in [", please", " please", ", i'd really like that", ", i'd like that"]:
		text = text.trim_suffix(suffix)
	var patterns := {
		"dating": "^(will|would|could) you( like to)? be my (girlfriend|marefriend|coltfriend|boyfriend|romantic partner)$|^(can|could|shall) we (start dating|be (a couple|girlfriend and boyfriend|marefriend and coltfriend))$|^(would you like to|let's) (start dating|be a couple)$|^be my (girlfriend|marefriend|coltfriend|boyfriend)$",
		"engagement": "^(will|would) you marry me$",
		"marriage": "^(let's|shall we) get married$|^i'm ready for our wedding$",
		"move_in": "^(can|could) i move in with you$|^(let's|shall we) (move in|live) together$",
		"kiss": "^(may|can|could) i kiss you$",
		"hug": "^(may|can|could) i hug you$",
		"break_up": "^(we should|i want to|i need to) break up$",
	}
	for kind: String in patterns:
		if matches(text, patterns[kind]): return {"type": "offer", "kind": kind, "activity": "walk"}
	if matches(text, "^(would you like to|will you|do you want to) go on a date( with me)?$"):
		return {"type": "offer", "kind": "date", "activity": "walk"}
	if matches(text, "^(would you like to|do you want to|shall we|let's) (have a picnic|share a picnic|have a meal)( with me| together)?$|^would you like a picnic( with me)?$"):
		return {"type": "offer", "kind": "outing", "activity": "meal"}
	for activity: String in ["walk", "fishing", "orchard", "meal", "visit"]:
		if matches(text, "^(let's go on a|would you like a|can we have a) " + activity + " date$"):
			return {"type": "offer", "kind": "date", "activity": activity}
		if matches(text, "^(let's go " + activity + " together|would you like to go " + activity + " with me)$"):
			return {"type": "offer", "kind": "outing", "activity": activity}
	return {}
