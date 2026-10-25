extends RefCounted
const CONTROLS := preload("res://world/ai/speech_controls.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
## Data only. Never turn model text into method names, code, paths or coordinates.
const TYPES := ["look_at", "approach", "call_pony", "send_pony", "follow", "go_to", "step", "lead", "stay", "cancel", "resume_routine", "sit", "stand", "lie_down", "fly_to", "hover", "land", "loop_de_loop", "barrel_roll", "circle_over", "sonic_rainboom", "sit_on_seat", "go_home", "air_show", "relationship_offer", "relationship_answer", "request_space", "buck_player", "cuddle", "kiss_player", "wake_up", "teleport_to_ponyville", "send_letter", "give_house"]
const SPEECH_LIMIT := 2880
const STEP_DIRECTIONS := ["forward", "back", "left", "right", "away", "aside"]
const STEP_SPELLINGS := {"forwards": "forward", "ahead": "forward", "backward": "back", "backwards": "back", "backward_s": "back",
	"back_up": "back", "behind": "back", "sideways": "aside", "out_of_the_way": "aside", "out_of_way": "aside", "to_the_side": "aside",
	"side": "aside", "away_from_player": "away", "away_from_you": "away"}
const FIELDS := {
	"teleport_to_ponyville": [], "give_house": [],
	"call_pony": ["pony_id"], "send_pony": ["pony_id", "target_id"],
	"request_space": [], "buck_player": [], "cuddle": [], "kiss_player": [], "wake_up": [], "send_letter": [], "relationship_offer": ["kind", "activity", "location_id"], "relationship_answer": ["offer_id", "accept"],
	"look_at": ["target_id", "duration_s"], "approach": ["target_id", "distance_m"],
	"follow": ["target_id", "formation", "distance_m"], "go_to": ["location_id", "pace"],
	"step": ["direction", "distance_m"],
	"lead": ["target_id", "location_id", "wait_distance_m"],
	"stay": ["duration_s", "until_cancel"], "cancel": ["action_id"], "resume_routine": [], "sit": [], "stand": [], "lie_down": [], "fly_to": ["location_id"], "hover": ["duration_s"], "land": [], "loop_de_loop": [], "barrel_roll": [], "circle_over": ["target_id"], "sonic_rainboom": [], "sit_on_seat": [], "go_home": [], "air_show": ["moves", "target_id"]}
## Air show figures (pony_flight.gd SHOW_MOVES) and the tag spellings that name one. A reply with
## [air_show: loop, dive, ...] or with several trick tags ([loop_de_loop] [dive] [barrel_roll])
## becomes one air_show action: one takeoff, the figures in order, one landing.
const SHOW_MOVES := ["loop", "barrel_roll", "aileron_roll", "spiral_climb", "dive", "figure_eight", "immelmann", "split_s", "hammerhead", "flyby", "circle"]
const SHOW_TAGS := {"loop": "loop", "loop_de_loop": "loop", "loopdeloop": "loop", "barrel_roll": "barrel_roll", "barrelroll": "barrel_roll",
	"aileron_roll": "aileron_roll", "roll": "aileron_roll", "spiral_climb": "spiral_climb", "spiral": "spiral_climb", "corkscrew": "spiral_climb",
	"dive": "dive", "swoop": "dive", "figure_eight": "figure_eight", "figure_8": "figure_eight", "figure8": "figure_eight",
	"immelmann": "immelmann", "immelman": "immelmann", "split_s": "split_s", "splits": "split_s", "hammerhead": "hammerhead",
	"stall_turn": "hammerhead", "flyby": "flyby", "fly_by": "flyby", "fly_past": "flyby", "circle": "circle", "circle_over": "circle"}
const SHOW_LIMIT := 8

## Tag replies (dev 2026-10-02: "harden the ai action calling system into tags so even a dumb ai
## model can understand its options and output the correct structure like ponyponyparadise"):
## the reply is the spoken line; square-bracket tags in it are never spoken:
##   [face:happy] Sure, let's go! [follow: player]
## Action tags are [type] or [type: arg, arg] with arguments in SIGNATURES order; missing ones take
## their default, numbers are clamped into range, spellings are forgiven (ALIASES), and a tag that
## still cannot be used is dropped (listed in "dropped") while the line is spoken. Feelings:
## [mood: happy] [friendship: +1] [romance: 0] [thought: ...]. [silence] says nothing.
## JSON replies (the old envelope) are still accepted.
## Per type: [field, default]; a default of null means required.
const SIGNATURES := {
	"call_pony": [["pony_id", null]], "send_pony": [["pony_id", null], ["target_id", null]],
	"look_at": [["target_id", null], ["duration_s", 3.0]], "approach": [["target_id", null], ["distance_m", 1.2]],
	"follow": [["target_id", null], ["formation", "right"], ["distance_m", 1.5]], "go_to": [["location_id", null], ["pace", "walk"]],
	"step": [["direction", "aside"], ["distance_m", 1.5]],
	"lead": [["target_id", null], ["location_id", null], ["wait_distance_m", 6.0]], "cancel": [["action_id", "current"]],
	"fly_to": [["location_id", null]], "hover": [["duration_s", 10.0]], "circle_over": [["target_id", "player"]],
	"relationship_offer": [["kind", null], ["activity", "walk"], ["location_id", ""]], "relationship_answer": [["offer_id", null], ["accept", null]]}
const PLAYER_NAMES := ["me", "you", "anon", "him", "the player", "anonymous"]
const RANGES := {"duration_s": [0.2, 600.0], "distance_m": [1.0, 6.0], "wait_distance_m": [3.0, 15.0]}
const ALIASES := {"lookat": "look_at", "look": "look_at", "goto": "go_to", "walk_to": "go_to", "go": "go_to", "flyto": "fly_to",
	"summon": "call_pony", "call": "call_pony", "send": "send_pony", "go_to_pony": "approach",
	"wait": "stay", "hold": "stay", "hold_position": "stay", "stay_here": "stay", "wait_here": "stay",
	"fly": "fly_to", "loop": "loop_de_loop", "loopdeloop": "loop_de_loop", "loop_the_loop": "loop_de_loop", "barrelroll": "barrel_roll",
	"roll": "barrel_roll", "circle": "circle_over", "circle_around": "circle_over", "fly_around": "circle_over", "rainboom": "sonic_rainboom",
	"sonicrainboom": "sonic_rainboom", "lay_down": "lie_down", "lie": "lie_down", "laydown": "lie_down", "liedown": "lie_down",
	"sitdown": "sit", "sit_down": "sit", "standup": "stand", "stand_up": "stand", "wake": "wake_up", "wakeup": "wake_up",
	"home": "go_home", "gohome": "go_home", "resume": "resume_routine", "stop": "cancel", "seat": "sit_on_seat", "bench": "sit_on_seat",
	"kiss": "kiss_player", "buck": "buck_player", "hug": "cuddle", "space": "request_space",
	"letter": "send_letter", "send_a_letter": "send_letter", "write_letter": "send_letter", "letter_to_celestia": "send_letter", "send_letter_to_celestia": "send_letter", "fire_letter": "send_letter",
	"give_home": "give_house", "grant_house": "give_house", "grant_home": "give_house", "assign_house": "give_house", "house_grant": "give_house",
	"airshow": "air_show", "show": "air_show", "stunts": "air_show", "stunt_show": "air_show", "aerobatics": "air_show", "flying_show": "air_show",
	"move": "step", "step_aside": "step", "move_aside": "step", "make_way": "step", "scoot": "step", "shift": "step"}
## One line per command for the prompt: the exact tag and what it does.
const TAG_HELP := {
	"teleport_to_ponyville": "[teleport_to_ponyville] Twilight takes you both out of the Everfree to Ponyville for shelter at Golden Oak; only available during the active forest rescue; finish explaining first, then regroup beside the newcomer before casting if separated",
	"call_pony": "[call_pony: PONY_ID] ask a nearby pony who can hear you to come to you; no remote summons",
	"send_pony": "[send_pony: PONY_ID, TARGET] ask a nearby pony who can hear you to go to a nearby pony or player; a request is not arrival",
	"look_at": "[look_at: TARGET] look at someone for a moment (optional seconds: [look_at: player, 5])",
	"approach": "[approach: TARGET] walk up close to someone and stop there",
	"follow": "[follow: TARGET] go along with someone (optional side and metres: [follow: player, left, 2])",
	"go_to": "[go_to: LOCATION] walk to a place (optional pace: [go_to: LOCATION, trot])",
	"step": "[step: DIRECTION] take a few steps where you are: forward, back, left, right, away (from the player) or aside (out of someone's way, e.g. when you block a doorway or path); optional metres 1–6: [step: back, 2]",
	"lead": "[lead: TARGET, LOCATION] take someone to a place, waiting for them",
	"stay": "[stay: SECONDS] hold position for 0.5–600 seconds; [stay] waits 30 seconds",
	"cancel": "[cancel] stop what you are doing",
	"resume_routine": "[resume_routine] go back to your day",
	"sit": "[sit] sit down", "stand": "[stand] stand up", "lie_down": "[lie_down] lie down",
	"fly_to": "[fly_to: LOCATION] fly to a place", "hover": "[hover: SECONDS] hover in the air here",
	"land": "[land] land", "loop_de_loop": "[loop_de_loop] a quick flight with a loop-de-loop, for fun or showing off",
	"barrel_roll": "[barrel_roll] a quick flight with a barrel roll, for fun or showing off",
	"circle_over": "[circle_over: TARGET] fly a lap over someone and land beside them",
	"sonic_rainboom": "[sonic_rainboom] climb high, burst past the speed of sound with a rainbow ring, and come back",
	"air_show": "[air_show: MOVE, MOVE, ...] one flight that chains up to 8 figures for whoever watches, then lands: loop, barrel_roll, aileron_roll, spiral_climb, dive, figure_eight, immelmann, split_s, hammerhead, flyby, circle (e.g. [air_show: loop, dive, figure_eight, flyby])",
	"sit_on_seat": "[sit_on_seat] walk to the nearest free bench or seat and sit on it",
	"wake_up": "[wake_up] wake up, or get up out of a bed or off a couch",
	"go_home": "[go_home] go home to rest a while (say goodbye first)",
	"relationship_offer": "[relationship_offer: KIND, ACTIVITY] ask Anon for a relationship step (ACTIVITY walk/fishing/orchard/meal/visit, or place plus a LOCATION)",
	"relationship_answer": "[relationship_answer: OFFER_ID, yes] or no: answer Anon's invitation",
	"request_space": "[request_space] ask Anon to give you some space", "buck_player": "[buck_player] buck Anon away (only real, lasting anger at unwelcome contact)",
	"cuddle": "[cuddle] cuddle up to Anon", "kiss_player": "[kiss_player] kiss Anon",
	"send_letter": "[send_letter] write a quick note on a scroll and send it to Princess Celestia with your green fire",
	"give_house": "[give_house] officially make a free Ponyville house Anon's own home, for good (the empty one he is in or beside, else the nearest free one); only when you give it, never just to talk about houses; works alongside one other action"}

## Turns a model's tag name into a TYPES entry ("" when it is not an action).
static func action_type(raw: String) -> String:
	var name := raw.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	if name in TYPES: return name
	return str(ALIASES.get(name, ALIASES.get(name.replace("_", ""), "")))

## A tag reply: speech without its action and feeling tags (face/gesture tags stay for
## pony_dialogue_tags.gd), validated actions, the impression and the dropped tags with reasons.
static func decode_tags(text: String, actor: String, turn: int, context: Dictionary) -> Dictionary:
	if text.length() > 8192: return {"error": "Response exceeds 8192 characters"}
	var tags := RegEx.new()
	tags.compile("\\[\\s*([A-Za-z][A-Za-z _-]{1,40}?)\\s*(?:[:=]\\s*([^\\]\\r\\n]*?))?\\s*\\]")
	var actions: Array = []
	var dropped: Array = []
	var impression := {}
	var silent := false # [silence] alone: nothing is spoken
	var speech := CONTROLS.sanitize(text, true)
	var channels: Array = []
	for span: Dictionary in CONTROLS.spans(text):
		if not span.complete: dropped.append("Malformed control tag (ignored)"); continue
		var found := tags.search(str(span.tag))
		if found == null: dropped.append("Unrecognized control tag (ignored)"); continue
		var raw := found.get_string(1)
		var name := raw.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
		var value := found.get_string(2).strip_edges()
		var type := action_type(raw)
		# Air show: a figure tag joins the reply's show (or starts one); two trick tags chain.
		var figure: String = SHOW_TAGS.get(name, "") if type in ["", "loop_de_loop", "barrel_roll", "air_show"] else ""
		if type == "air_show" or figure != "":
			var show_at := -1
			for i in actions.size():
				if actions[i].type in ["air_show", "loop_de_loop", "barrel_roll"]: show_at = i
			var moves: Array = []
			var audience := "player"
			if type == "air_show":
				for part in value.split(",", false):
					var item := part.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
					if SHOW_TAGS.has(item): moves.append(SHOW_TAGS[item])
					elif item in PLAYER_NAMES or item == "player": audience = "player"
					elif context.get("targets", {}).has(item): audience = item
				if moves.is_empty(): moves = ["loop", "barrel_roll", "dive"]
			else: moves = [figure]
			if show_at >= 0:
				var joined: Dictionary = actions[show_at]
				if joined.type != "air_show":
					joined.moves = [SHOW_TAGS[joined.type]]; joined.type = "air_show"; joined.target_id = "player"
					joined.id = "t%d-%d-air_show" % [turn, show_at]
				for move in moves: if joined.moves.size() < SHOW_LIMIT: joined.moves.append(move)
				continue
			if type in ["loop_de_loop", "barrel_roll"]: pass   # alone, the classic trick
			else:
				var show := {"id": "t%d-%d-air_show" % [turn, actions.size()], "type": "air_show", "moves": moves.slice(0, SHOW_LIMIT), "target_id": audience}
				var show_error := validate(show, context)
				if show_error == "" and "movement" in channels: show_error = "Only one movement per reply"
				if show_error != "": dropped.append("%s (%s)" % [found.get_string(0), show_error]); continue
				channels.append("movement"); actions.append(show)
				continue
		# Face, gesture and voice-emotion tags stay in the line for pony_dialogue_tags.gd and TTS.
		if type.is_empty() and name not in ["silence", "friendship", "romance", "mood", "thought"]:
			if not CONTROLS.presentation_tag(str(span.tag)): dropped.append("Unrecognized control tag (ignored)")
			continue
		if name == "silence": silent = true; continue
		if name in ["friendship", "romance"]:
			if value.trim_prefix("+").is_valid_float(): impression[name] = int(round(float(value.trim_prefix("+"))))
			continue
		if name == "mood": impression.mood = value.to_lower(); continue
		if name == "thought": impression.thought = value; continue
		if type == "teleport_to_ponyville" and not value.is_empty():
			dropped.append("teleport_to_ponyville takes no arguments"); continue
		var action := _tag_action(type, value, turn, actions.size())
		# A house grant moves nopony: it may come with her walk or follow.
		var channel := "gaze" if type == "look_at" else ("grant" if type == "give_house" else "movement")
		var error := validate(action, context)
		if error == "" and channel in channels: error = "Only one %s per reply" % ("look_at" if channel == "gaze" else "movement")
		if error == "" and actions.size() >= 2: error = "At most two actions per reply"
		if error != "":
			dropped.append("%s (%s)" % [found.get_string(0), error]); continue
		channels.append(channel)
		actions.append(action)
	speech = speech.replace("  ", " ").strip_edges()
	if speech.length() > SPEECH_LIMIT: return {"error": "Speech exceeds 2880 characters; use complete sentences within the limit"}
	for action: Dictionary in actions:
		if action.type in ["relationship_offer", "relationship_answer", "request_space", "buck_player", "cuddle", "teleport_to_ponyville", "give_house"] and CONTROLS.sanitize(speech).is_empty():
			return {"error": "This action requires spoken words before it can finish"}
	return {"speech": speech, "actions": actions, "impression": preload("res://world/ai/impressions/pony_impressions.gd").sanitize(impression),
		"dropped": dropped, "tags": true, "control_only": not silent and actions.is_empty() and CONTROLS.sanitize(speech).is_empty() and not text.strip_edges().is_empty()}

static func _tag_action(type: String, value: String, turn: int, index: int) -> Dictionary:
	var action := {"id": "t%d-%d-%s" % [turn, index, type], "type": type}
	var args: Array = []
	for part in value.split(",", false):
		var item := part.strip_edges()
		if not item.is_empty(): args.append(item)
	if type == "stay":
		var seconds := str(args[0]).trim_suffix("s").strip_edges() if not args.is_empty() else ""
		if seconds.is_valid_float(): action.duration_s = clampf(float(seconds), 0.5, 600.0)
		else: action.duration_s = 30.0
		return action
	# Forgiving shapes: [follow] and [lead: PLACE] mean the player; "me"/"anon" name him too.
	var lone_place: bool = type == "lead" and args.size() == 1 and str(args[0]).to_lower() not in PLAYER_NAMES + ["player"]
	if type in ["follow", "lead"] and (args.is_empty() or lone_place): args.push_front("player")
	if type in ["follow", "lead", "approach", "look_at", "circle_over"] and not args.is_empty() and str(args[0]).to_lower() in PLAYER_NAMES: args[0] = "player"
	var fields: Array = SIGNATURES.get(type, [])
	for i in fields.size():
		var field: String = fields[i][0]
		var fallback: Variant = fields[i][1]
		var given := str(args[i]) if i < args.size() else ""
		if given.is_empty():
			if fallback == null or (fallback is String and fallback.is_empty()): continue
			action[field] = fallback
			continue
		if RANGES.has(field) or field.ends_with("_s") or field.ends_with("_m"):
			var number := given.trim_suffix("m").trim_suffix("s").strip_edges()
			var bounds: Array = RANGES.get(field, [0.0, 600.0])
			action[field] = clampf(float(number), bounds[0], bounds[1]) if number.is_valid_float() else fallback
		elif field == "accept":
			action[field] = given.to_lower() in ["yes", "true", "accept", "y", "ok", "sure"]
		else:
			action[field] = given.to_lower().replace(" ", "_") if field.ends_with("_id") or field in ["formation", "pace", "kind", "activity", "direction"] else given
	if type == "hover": action.duration_s = clampf(float(action.get("duration_s", 10.0)), 1.0, 60.0)
	if type == "look_at": action.duration_s = clampf(float(action.get("duration_s", 3.0)), 0.2, 30.0)
	if type == "follow" and action.get("formation") not in ["behind", "left", "right", "loose"]: action.formation = "right"
	if type == "step": action.direction = STEP_SPELLINGS.get(str(action.get("direction", "aside")), str(action.get("direction", "aside")))
	if type == "go_to" and action.get("pace") not in ["walk", "trot"]: action.pace = "walk"
	return action

## The FORMAT RULES block for one speaker: only her commands, targets and places.
static func tag_rules(capabilities: Array, targets: Array, places: String, include_bindings := true) -> String:
	var lines: Array = ["REPLY FORMAT (plain text, never JSON):",
		"Write only what you say out loud. Put tags in square brackets anywhere in the line; tags are never spoken.",
		"Example: [face:happy] Sure, let's go! [follow: player]"]
	var commands: Array = []
	for type: String in TYPES:
		if type in capabilities and TAG_HELP.has(type): commands.append("- " + str(TAG_HELP[type]))
	if not commands.is_empty():
		lines.append("THINGS YOU CAN DO NOW (at most one, plus one [look_at: ...]):")
		lines.append_array(commands)
		if include_bindings:
			lines.append("TARGETS (who TARGET can be): " + (", ".join(targets) if not targets.is_empty() else "(none)"))
			lines.append("LOCATIONS (what LOCATION can be, nearest first; use the id before the =):")
			lines.append(places)
	lines.append("FEELINGS (optional, never spoken): after your complete spoken words you may add [mood: happy] [friendship: +1] [romance: 0] [thought: a short private thought]. Omit unchanged feelings. Never begin your answer with private metadata. Use [silence] to say nothing.")
	return "\n".join(lines)

static func decode(text: String, actor: String, turn: int, context: Dictionary, bind_request := false) -> Dictionary:
	text = text.strip_edges()
	if text.length() > 8192: return {"error": "Response exceeds 8192 characters"}
	if text.begins_with("```"):
		# Providers sometimes omit the closing Markdown fence even when the JSON is
		# complete. Strip only the wrapper; JSON.parse still rejects truncated data.
		text = text.substr(3).strip_edges()
		if text.to_lower().begins_with("json"): text = text.substr(4).strip_edges()
		if text.ends_with("```"): text = text.left(-3).strip_edges()
		if not text.begins_with("{"): return {"error": "Expected JSON inside response fence"}
	if not text.begins_with("{"):
		# Malformed JSON is never spoken; everything else is a tag reply.
		if "\"actions\"" in text or "\"schema_version\"" in text or "\"speech\"" in text:
			return {"error": "Malformed structured response"}
		return decode_tags(text, actor, turn, context)
	var parser := JSON.new()
	if parser.parse(text) != OK: return {"error": "Invalid response JSON"}
	var value: Variant = parser.data
	if not value is Dictionary: return {"error": "Invalid response JSON"}
	if not _keys(value, ["schema_version", "actor_id", "turn_id", "listener_id", "speech", "actions", "impression"]): return {"error": "Unknown response fields"}
	# Called only after the director checks the actual request generation.
	if bind_request:
		value.turn_id=turn;value.actor_id=actor;value.listener_id="player"
	if not _number(value.get("schema_version"), 1, 1) or value.get("actor_id") != actor or not _number(value.get("turn_id"), turn, turn):
		return {"error": "Wrong version, actor or conversation turn"}
	if value.get("listener_id") != "player": return {"error": "Group speech is not available yet"}
	if not value.get("speech") is String or value.speech.length() > SPEECH_LIMIT: return {"error": "Invalid speech field (maximum 2880 characters)"}
	var raw_speech: String = value.speech
	value.speech = CONTROLS.sanitize(raw_speech, true)
	if not value.get("actions") is Array or value.actions.size() > 2: return {"error": "At most two actions per reply"}
	var ids: Array = []
	var channels: Array = []
	for action in value.actions:
		var error := validate(action, context)
		if error != "": return {"error": error}
		if action.id in ids: return {"error": "Duplicate action IDs in reply"}
		if action.type in ["relationship_offer","relationship_answer","request_space","buck_player","cuddle","teleport_to_ponyville","give_house"] and CONTROLS.sanitize(value.speech).is_empty():return {"error":"This action requires spoken words before it can finish"}
		ids.append(action.id)
		var channel := "gaze" if action.type == "look_at" else ("grant" if action.type == "give_house" else "movement")
		if channel in channels: return {"error": "One intention per channel per reply"}
		channels.append(channel)
	return {"speech": value.speech, "actions": value.actions.duplicate(true), "impression":preload("res://world/ai/impressions/pony_impressions.gd").sanitize(value.get("impression")),
		"control_only": value.actions.is_empty() and not raw_speech.strip_edges().is_empty() and raw_speech.strip_edges() != "[silence]" and CONTROLS.sanitize(value.speech).is_empty()}

static func validate(action: Variant, context: Dictionary) -> String:
	if not action is Dictionary or not action.get("type") is String or action.type not in TYPES: return "Unsupported action"
	if not _id(action.get("id")): return "Invalid action ID"
	if action.type not in context.get("capabilities", []): return "Capability unavailable: " + action.type
	var allowed: Array = ["id", "type"] + FIELDS[action.type]
	if not _keys(action, allowed): return "Unknown action fields"
	# Linky is the existing Shoeshine identity. Canonicalize the name before
	# ordinary target/hearing validation; an alias never grants availability.
	for field: String in ["target_id", "pony_id"]:
		if field not in FIELDS[action.type] or not action.get(field) is String: continue
		var name_id: String = str(action[field]).strip_edges().to_lower().replace(" ", "_")
		if name_id in ["linky", "linky_(shoeshine)"]: action[field] = "shoeshine"
	if "target_id" in FIELDS[action.type]:
		if not _id(action.get("target_id")) or not context.get("targets", {}).has(action.target_id): return "Unknown target"
	if action.type in ["call_pony", "send_pony"]:
		if not _id(action.get("pony_id")) or action.pony_id not in context.get("callable_ponies", []): return "Pony is not nearby or cannot hear you"
		if action.type == "send_pony" and action.pony_id == action.target_id: return "A pony cannot be sent to herself"
	if "location_id" in FIELDS[action.type] and (action.type != "relationship_offer" or action.has("location_id")):
		if not action.get("location_id") is String: return "Unknown mapped location"
		if action.location_id not in context.get("locations", []):
			# A free-form name ("Sugarcube Corner", "the balloon") becomes the listed id it means.
			var matched := PLACES.match_name(str(action.location_id), context.get("locations", []), context.get("place_labels", {}))
			if matched.is_empty(): return "Unknown mapped location"
			action.location_id = matched
	match action.type:
		"relationship_offer":
			if action.get("kind") not in context.get("relationship",{}).get("offers",[]): return "Relationship milestone not eligible"
			if action.get("activity") not in ["walk","fishing","orchard","meal","visit","place"]: return "Unknown shared activity"
			if (action.get("activity") == "place") != action.has("location_id"): return "A place outing needs its location_id, and only a place outing takes one"
			if not context.get("relationship",{}).get("pending",{}).is_empty(): return "Answer or finish the existing invitation first"
		"relationship_answer":
			var pending: Dictionary=context.get("relationship",{}).get("pending",{})
			if pending.is_empty() or pending.get("by")!="player" or pending.get("id")!=action.get("offer_id"): return "No matching player invitation"
			if not action.get("accept") is bool: return "Invitation answer must be boolean"
		"hover":
			if not _number(action.get("duration_s"), 1, 60): return "Hover duration must be 1–60 seconds"
		"air_show":
			var moves: Variant = action.get("moves")
			if not moves is Array or moves.is_empty() or moves.size() > SHOW_LIMIT: return "An air show needs 1–8 figures"
			for move in moves: if str(move) not in SHOW_MOVES: return "Unknown air show figure: " + str(move)
		"look_at":
			if not _number(action.get("duration_s"), .2, 30): return "Look duration must be 0.2–30 seconds"
		"approach", "follow":
			if not _number(action.get("distance_m"), 1.0, 6.0): return "Distance must be 1–6 metres"
			if action.type == "follow" and action.get("formation") not in ["behind", "left", "right", "loose"]: return "Unknown formation"
		"go_to":
			if action.get("pace") not in ["walk", "trot"]: return "Pace must be walk or trot"
		"step":
			if action.get("direction") not in STEP_DIRECTIONS: return "Direction must be forward, back, left, right, away or aside"
			if not _number(action.get("distance_m"), 1.0, 6.0): return "Distance must be 1–6 metres"
		"lead":
			if not _number(action.get("wait_distance_m"), 3, 15): return "Lead waiting distance must be 3–15 metres"
		"stay":
			if action.has("until_cancel") or not _number(action.get("duration_s"), .5, 600): return "Stay duration must be 0.5–600 seconds"
		"cancel":
			if not _id(action.get("action_id")): return "Invalid cancellation target"
	return ""

static func _keys(value: Dictionary, allowed: Array) -> bool:
	for key in value:
		if key not in allowed: return false
	return true

static func _number(value: Variant, low: float, high: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value >= low and value <= high

static func _id(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > 96: return false
	for c in value:
		if c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-": return false
	return true
