extends RefCounted
## Who the player is in a world (dev 2026-10-01, docs/ANONPONY_DESIGN_2026_10_01.md section 2):
## human Anon, or AnonPony with a chosen race, sex, age and eye colour. Everything else about
## AnonPony is fixed (green coat, messy black mane, question-mark cutie mark).
##
## Stored in the world context as state["player_form"]. An absent key is human: every world and
## save from before this change stays human. {"kind": "human"} means Anon was chosen in the
## creator (world/life/pony_creator.gd), which is then not shown again. No format or version
## bumps: valid() checks types only, so a world written by a later build (a new race or eye
## colour) still loads here, and saved() maps the values it does not know.
##
## Two readers: saved(state) is what the world says (persistence, whether to show the creator);
## active(tree) is what the player is right now, a pony only while player/pony_form.gd drives one
## (room-scale VR plays a pony world as Anon). Gameplay and text branches use active().
## Static only, no class_name: callers preload this file.
const KEY := "player_form"
const PONY_NOTICE := "Pony mode is underdeveloped. Playing as a human is the intended experience."
const RACES: Array[String] = ["earth", "unicorn", "pegasus"]
const SEXES: Array[String] = ["mare", "stallion"]
const AGES: Array[String] = ["adult", "young"]
## [id, colour, label] in the creator's order; the first is the default and the fallback.
const EYES := [["blue", Color("3b78d8"), "Blue"], ["teal", Color("2a9d8f"), "Teal"], ["green", Color("4f9d3a"), "Green"],
	["amber", Color("d08c2c"), "Amber"], ["violet", Color("8e5ad0"), "Violet"], ["grey", Color("7d8590"), "Grey"]]
const RACE_WORDS := {"earth": "earth pony", "unicorn": "unicorn", "pegasus": "pegasus"}
## player/pony_form.gd's group (kept here so this file needs no preload of it).
const PONY_FORM_GROUP := "player_pony_form"

static func human() -> Dictionary:
	return {"kind": "human"}

static func default_pony() -> Dictionary:
	return {"kind": "pony", "race": "earth", "sex": "mare", "age": "adult", "eyes": "blue"}

## Types only, never values against today's lists. Pure: it also runs on the context save
## worker through world_context._valid_state.
static func valid(value: Variant) -> bool:
	if not value is Dictionary: return false
	var form: Dictionary = value
	if not form.get("kind") is String: return false
	for key: String in ["race", "sex", "age", "eyes"]:
		if form.has(key) and not form[key] is String: return false
	return true

## The world's saved form, normalised: {} when there is none (or it is malformed); a kind other
## than "pony" is human(); a pony's unknown race, sex or age becomes earth, mare or adult; the eye
## id is kept as it is (eye_color() maps an unknown one). The stored dictionary is never rewritten.
static func saved(state: Dictionary) -> Dictionary:
	if not state.has(KEY) or not valid(state[KEY]): return {}
	var stored: Dictionary = state[KEY]
	if str(stored.get("kind", "")) != "pony": return human()
	var form := default_pony()
	for field: String in ["race", "sex", "age"]:
		var value := str(stored.get(field, ""))
		if value in _choices(field): form[field] = value
	if stored.has("eyes"): form.eyes = str(stored.eyes)
	return form

## Writes the choice and flushes the context at once, so a crash right after choosing loses
## nothing. A read-only context (a newer build's world) stores nothing; the choice still applies
## for the session.
static func store(game: Node, form: Dictionary) -> void:
	var context: Node = game.get("world_context") if is_instance_valid(game) else null
	if context == null or context.get("_read_only") == true: return
	var state: Dictionary = context.get("state")
	state[KEY] = form.duplicate(true)
	if context.has_method("_changed"): context._changed()
	if context.has_method("flush"): context.flush()

## What the player is right now: the form player/pony_form.gd is driving, else human (desktop and
## seated human, room-scale VR, and any world without a pony). Do not modify the result.
static func active(tree: SceneTree) -> Dictionary:
	var driver: Node = tree.get_first_node_in_group(PONY_FORM_GROUP) if tree != null else null
	if driver != null:
		var form: Variant = driver.get("form")
		if form is Dictionary and not (form as Dictionary).is_empty(): return form
	return human()

static func is_pony(form: Dictionary) -> bool:
	return str(form.get("kind", "")) == "pony"

static func is_young(form: Dictionary) -> bool:
	return is_pony(form) and str(form.get("age", "")) == "young"

static func eye_color(id: String) -> Color:
	var row := _eye_row(id)
	return row[1]

static func eye_label(id: String) -> String:
	var row := _eye_row(id)
	return row[2]

static func _eye_row(id: String) -> Array:
	for row: Array in EYES:
		if row[0] == id: return row
	return EYES[0]

static func _choices(field: String) -> Array[String]:
	match field:
		"race": return RACES
		"sex": return SEXES
		"age": return AGES
	var none: Array[String] = []
	return none

## Words for the player: {"subject", "object", "possessive", "noun", "partner"}. A pony of
## unknown sex reads as a mare, as saved() maps it.
static func pronouns(form: Dictionary) -> Dictionary:
	if not is_pony(form):
		return {"subject": "he", "object": "him", "possessive": "his", "noun": "human", "partner": "coltfriend"}
	var young := is_young(form)
	if str(form.get("sex", "")) == "stallion":
		return {"subject": "he", "object": "him", "possessive": "his", "noun": "colt" if young else "stallion", "partner": "coltfriend"}
	return {"subject": "she", "object": "her", "possessive": "her", "noun": "filly" if young else "mare", "partner": "marefriend"}

## "a light green unicorn mare with blue eyes, a messy black mane and a question-mark cutie
## mark", or "a human".
static func describe(form: Dictionary) -> String:
	if not is_pony(form): return "a human"
	var race: String = RACE_WORDS.get(str(form.get("race", "")), RACE_WORDS.earth)
	return "a light green %s %s with %s eyes, a messy black mane and a question-mark cutie mark" % [
		race, pronouns(form).noun, eye_label(str(form.get("eyes", ""))).to_lower()]

## Typed input from the command line: "human" or "pony:<race>,<sex>,<age>,<eyes>", strictly
## against today's lists; {} when it is anything else.
static func from_arg(text: String) -> Dictionary:
	var clean := text.strip_edges().to_lower()
	if clean == "human": return human()
	if not clean.begins_with("pony:"): return {}
	var parts := clean.trim_prefix("pony:").split(",")
	if parts.size() != 4: return {}
	var race := parts[0].strip_edges()
	var sex := parts[1].strip_edges()
	var age := parts[2].strip_edges()
	var eyes := parts[3].strip_edges()
	if not race in RACES or not sex in SEXES or not age in AGES: return {}
	if not EYES.any(func(row: Array) -> bool: return row[0] == eyes): return {}
	return {"kind": "pony", "race": race, "sex": sex, "age": age, "eyes": eyes}
