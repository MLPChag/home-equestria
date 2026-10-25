extends RefCounted
## One bounded rewrite for repeated stylistic habits, based on speech that actually played.
const PET_NAMES := ["darling", "sugarcube", "dear", "sweetie", "honey"]
const PET_REASON := "Repeated term of address: "
## A pet name used as a term of address: set off by a comma or opening a sentence ("thank you,
## darling." / "Darling, you ..."). "A darling filly", "Sweetie Belle" and "honey cakes" are not.
const VOCATIVE_AFTER := "(?i),\\s*(?:my\\s+)?%s\\b(?=\\s*(?:[,.!?;:\\[]|\u2026|$))"
const VOCATIVE_OPENING := "(?i)(^|[.!?\u2026]\\s+|\\]\\s*)(?:my\\s+)?%s\\s*[,!]\\s*(\\p{L})"

static func _regex(pattern: String, pet: String) -> RegEx:
	return RegEx.create_from_string(pattern % pet)

static func vocative(text: String, pet: String) -> bool:
	return _regex(VOCATIVE_AFTER, pet).search(text) != null or _regex(VOCATIVE_OPENING, pet).search(text) != null

## The reply without its repeated term of address, or "" when the reason is something else or the
## pet name cannot be removed cleanly (the caller then asks the model to revise, as before).
static func local_fix(text: String, why: String) -> String:
	if not why.begins_with(PET_REASON): return ""
	var pet := why.trim_prefix(PET_REASON).strip_edges()
	if pet not in PET_NAMES: return ""
	var fixed := _regex(VOCATIVE_AFTER, pet).sub(text, "", true)
	var opening := _regex(VOCATIVE_OPENING, pet)
	var found := opening.search(fixed)
	while found != null:
		fixed = fixed.left(found.get_start()) + found.get_string(1) + found.get_string(2).to_upper() + fixed.substr(found.get_end())
		found = opening.search(fixed)
	return fixed.strip_edges() if fixed != text and not vocative(fixed, pet) else ""

static func words(text: String) -> PackedStringArray:
	var regex := RegEx.new()
	regex.compile("[^\\p{L}\\p{N}']+")
	return regex.sub(text.to_lower().replace("’", "'"), " ", true).strip_edges().split(" ", false)


## Stock lines every pony fell back on (dev 2026-10-22: "every pony when they sit down with another
## is like 'my hooves are tired.' 'agreed! let us sit down and commence.'"). Matched on the spoken
## words; a hit sends the one bounded rewrite like any other repeat.
const STOCK := ["(?i)\\bmy (?:poor |tired |aching )?hooves (?:are|feel) (?:so |really )?(?:tired|aching|sore|killing me)",
	"(?i)^\\W*(?:agreed|indeed|obviously|quite so)\\W*$", "(?i)^\\W*agreed[!.,]", "(?i)\\blet us (?:sit|rest|commence|begin)\\b",
	"(?i)\\b(?:shall we|let's) (?:sit|rest) (?:down )?(?:here|for a (?:bit|while|spell))\\b"]
static var _stock: Array[RegEx] = []

static func stock(text: String) -> String:
	if _stock.is_empty():
		for pattern in STOCK: _stock.append(RegEx.create_from_string(pattern))
	for regex in _stock:
		var found := regex.search(text.strip_edges())
		if found != null: return found.get_string().strip_edges()
	return ""


static func reason(candidate: String, spoken: Array, player_text := "") -> String:
	var tokens := words(candidate)
	if tokens.is_empty(): return ""
	var cliche := stock(candidate)
	if cliche != "": return "Stock line \"%s\"; say something real instead" % cliche
	var recent := spoken.slice(maxi(0, spoken.size() - 6))
	var quoted := words(player_text)
	# Detect repeated clauses inside a single generated reply too.
	var phrases := {}
	for i in maxi(0,tokens.size()-5):
		var phrase := " ".join(tokens.slice(i,i+6))
		if phrases.has(phrase): return "Repeated six-word clause within the reply"
		phrases[phrase]=true
	for pet: String in PET_NAMES:
		if pet not in tokens or pet in quoted or not vocative(candidate, pet): continue
		for line in recent.slice(maxi(0, recent.size() - 3)):
			if pet in words(str(line)): return PET_REASON + pet
	for line in recent:
		var previous := words(str(line))
		if tokens.size() >= 4 and tokens == previous: return "Repeated complete sentence"
		if previous.size() >= 8 and tokens.size() >= 8:
			var shared := 0
			for i in tokens.size()-5:
				if " ".join(tokens.slice(i,i+6)) in " ".join(previous): shared+=1
			if float(shared)/maxi(1,tokens.size()-5) > .65: return "Reply closely recycles recent wording"
	# A repeated opening is a habit only after two prior uses, not any shared word.
	if tokens.size() >= 3:
		var opener := " ".join(tokens.slice(0, 3))
		var count := 0
		for line in recent:
			var previous := words(str(line))
			if previous.size() >= 3 and " ".join(previous.slice(0, 3)) == opener: count += 1
		if count >= 2: return "Repeated three-word opening: " + opener
	return ""
