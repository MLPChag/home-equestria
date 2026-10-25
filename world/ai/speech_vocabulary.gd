extends RefCounted
## Pony and place names for speech recognition (playtester 2026-10-20: Whisper wrote "Minuet" for
## Minuette, and the pony then corrected his spelling; Mayor Mare likewise). prompt() is the
## recognizer's initial prompt: the core cast, a few home places and the ponies nearest Anon, which
## biases Whisper towards their spellings. correct() respells a capitalized near-miss of a known
## name ("Minuet" -> "Minuette", "Mayor Mair" -> "Mayor Mare") before the line is routed, so
## addressing and the pony both see the real name. Names come from the AI profiles (name, aliases),
## world_layout.json regions and the map's landmarks.
const ADDRESSEE := preload("res://world/ai/addressee.gd")
## The first two folders are the core cast, always named in the prompt.
const PROFILE_DIRS := ["res://world/ai/characters", "res://world/characters/princesses", "res://world/characters/background/ai"]
const LAYOUT := "res://world/world_layout.json"
const LANDMARKS := "res://world/ui/named_map_places.json"
const PROMPT_PLACES := ["Ponyville", "Canterlot", "Cloudsdale", "Sweet Apple Acres", "Everfree Forest", "Sugarcube Corner"]
## Whisper keeps only the last ~224 prompt tokens; this keeps the whole prompt near 100.
const NEARBY_LIMIT := 16
## A one-letter slip is respelled only for keys this long (shorter ones collide with ordinary words).
const FUZZY_MIN := 7

static var _core: Array[String] = []
## Sound key -> canonical spelling; "" when two different names share a key.
static var _known: Dictionary = {}
static var _regex: RegEx


## The display names a profile answers to: "Linky (Shoeshine)" gives Linky and Shoeshine, plus aliases.
static func names_of(profile: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var raw: Array = Array(str(profile.get("name", "")).replace(")", "").split("("))
	var aliases: Variant = profile.get("aliases", [])
	if aliases is Array: raw.append_array(aliases)
	for value: Variant in raw:
		var name := str(value).strip_edges()
		if name != "" and name not in out: out.append(name)
	return out


## Comma list for the recognizer's initial prompt, nearest ponies last (Whisper keeps the end).
## `head`: the player's camera, or null/freed while the rig is rebuilt (then no nearby names).
static func prompt(characters: Dictionary, head: Variant, player_name := "") -> String:
	_load()
	var words: Array[String] = []
	for place: String in PROMPT_PLACES: _add(words, place)
	for name: String in _core: _add(words, name)
	if is_instance_valid(head) and head is Node3D and (head as Node3D).is_inside_tree():
		var nearby: Array = []
		for id: Variant in characters:
			var entry: Dictionary = characters[id]
			var node: Variant = entry.get("node")
			if not is_instance_valid(node) or not node is Node3D or not (node as Node3D).is_inside_tree(): continue
			var profile: Variant = entry.get("profile", {})
			if profile is Dictionary: nearby.append([(node as Node3D).global_position.distance_squared_to((head as Node3D).global_position), profile])
		nearby.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
		for row: Array in nearby.slice(maxi(0, nearby.size() - NEARBY_LIMIT)):
			for name: String in names_of(row[1]): _add(words, name)
	if player_name.strip_edges() != "": _add(words, player_name.strip_edges())
	return ", ".join(PackedStringArray(words)) + "."


static func _add(words: Array[String], name: String) -> void:
	for have: String in words:
		if have.to_lower() == name.to_lower(): return
	words.append(name)


## The transcript with capitalized near-misses of known names respelled. Exact names, lowercase
## words and anything ambiguous are left alone.
static func correct(text: String) -> String:
	_load()
	var matches: Array[RegExMatch] = _words().search_all(text)
	var edits: Array = []
	var i := 0
	while i < matches.size():
		var used := 1
		for n: int in [3, 2, 1]:
			if i + n > matches.size(): continue
			var found := _match(text, matches, i, n)
			if found.is_empty(): continue
			used = n
			if found.has("text"): edits.append(found)
			break
		i += used
	var out := text
	for k in range(edits.size() - 1, -1, -1):
		var edit: Dictionary = edits[k]
		out = out.left(int(edit.start)) + str(edit.text) + out.substr(int(edit.end))
	return out


## {} when the words are no known name; {"keep": true} for a name already right;
## {start, end, text} for a respelling.
static func _match(text: String, matches: Array[RegExMatch], first: int, count: int) -> Dictionary:
	for k in range(first, first + count - 1):
		if text.substr(matches[k].get_end(), matches[k + 1].get_start() - matches[k].get_end()) != " ": return {}
	var start := matches[first].get_start()
	var end := matches[first + count - 1].get_end()
	var heard := text.substr(start, end - start)
	var suffix := ""
	for tail: String in ["'s", "’s"]:
		if heard.length() > 4 and heard.ends_with(tail):
			heard = heard.left(heard.length() - tail.length()); suffix = tail
	var key := _key(heard)
	if key.length() < 4: return {}
	var canonical := str(_known.get(key, ""))
	if _known.has(key) and canonical == "": return {}
	var capitalized := heard.left(1) != heard.left(1).to_lower()
	# A slip is only trusted where Whisper capitalized a proper noun: mid-sentence, or every word of
	# a multi-word name ("Mayor Mair"). A sentence's capital first word is no evidence ("Soaring").
	if canonical == "" and capitalized and key.length() >= FUZZY_MIN and _proper(text, matches, first, count): canonical = _near_name(key)
	if canonical == "": return {}
	if heard.to_lower() == canonical.to_lower(): return {"keep": true}
	if not capitalized: return {}
	return {"start": start, "end": end, "text": canonical + suffix}


static func _proper(text: String, matches: Array[RegExMatch], first: int, count: int) -> bool:
	var gap := text.substr(matches[first - 1].get_end(), matches[first].get_start() - matches[first - 1].get_end()) if first > 0 else "."
	if not ("." in gap or "!" in gap or "?" in gap): return true
	if count < 2: return false
	for k in range(first, first + count):
		var word := matches[k].get_string()
		if word.left(1) == word.left(1).to_lower(): return false
	return true


## The one known name a single slip away; none when two are, or when it is only a plural.
static func _near_name(key: String) -> String:
	var found := ""
	for other: String in _known:
		if absi(other.length() - key.length()) > 1 or key == other + "s" or not ADDRESSEE._near(key, other): continue
		if found != "" or str(_known[other]) == "": return ""
		found = str(_known[other])
	return found


## Sound key: lowercase letters only, doubled letters collapsed, a final silent "e" dropped
## ("Minuette" and "Minuet" share "minuet").
static func _key(text: String) -> String:
	var out := ""
	for c: String in text.to_lower():
		var code := c.unicode_at(0)
		if code < 97 or code > 122 or out.ends_with(c): continue
		out += c
	if out.length() > 3 and out.ends_with("e"): out = out.left(out.length() - 1)
	return out


static func _words() -> RegEx:
	if _regex == null:
		_regex = RegEx.new()
		_regex.compile("[A-Za-z][A-Za-z'’\\-]*")
	return _regex


static func _load() -> void:
	if not _known.is_empty(): return
	for d in PROFILE_DIRS.size():
		var dir: String = PROFILE_DIRS[d]
		for file: String in DirAccess.get_files_at(dir):
			if not file.ends_with(".json"): continue
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(file)))
			if not parsed is Dictionary or not (parsed as Dictionary).has("prompt"): continue
			for name: String in names_of(parsed):
				if d < 2 and name not in _core: _core.append(name)
				_remember(name)
				# Distinctive parts on their own ("Heartstrings", "Lulamoon"), as the addressee rules use them.
				for part: RegExMatch in _words().search_all(name):
					var word := part.get_string()
					if word.length() >= 5 and word.to_lower() not in ADDRESSEE.COMMON_PARTS: _remember(word)
	var layout: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT)) if FileAccess.file_exists(LAYOUT) else null
	if layout is Dictionary and (layout as Dictionary).get("regions") is Array:
		for region: Variant in (layout as Dictionary).get("regions"):
			if region is Dictionary: _remember(str((region as Dictionary).get("name", "")))
	var map: Variant = JSON.parse_string(FileAccess.get_file_as_string(LANDMARKS)) if FileAccess.file_exists(LANDMARKS) else null
	if map is Dictionary and (map as Dictionary).get("places") is Array:
		for place: Variant in (map as Dictionary).get("places"):
			if place is Dictionary and str((place as Dictionary).get("kind", "")) != "house": _remember(str((place as Dictionary).get("name", "")))
	for place: String in PROMPT_PLACES: _remember(place)


static func _remember(name: String) -> void:
	var key := _key(name)
	if key.length() < 4: return
	var have: Variant = _known.get(key)
	if have == null: _known[key] = name
	elif str(have) != "" and str(have).to_lower() != name.to_lower(): _known[key] = ""
