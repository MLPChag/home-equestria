extends Node
## Authoritative player relationships. Dialogue can offer/answer; only observed events progress trust.
signal changed(id: String)
signal boundary(id: String, level: float, kind: String)
const STAGES := ["acquaintance", "friend", "close_friend", "dating", "engaged", "married"]
const KINDS := ["outing", "date", "dating", "move_in", "engagement", "marriage", "kiss", "hug", "flank_touch", "break_up"]
## "place": time together at a mapped place she names (a lake, a landmark; dev 2026-09-28).
const ACTIVITIES := ["walk", "fishing", "orchard", "meal", "visit", "place"]
const ROMANTIC := ["date", "dating", "move_in", "engagement", "marriage", "kiss", "flank_touch"]
## AnonPony (world/life/player_form.gd): a young player (filly or colt) is offered no romance by
## anypony, and a mare player is a pony's marefriend, not her coltfriend.
const PERSONALITY := preload("res://world/relationships/friendship_personality.gd")
const REST_POLICY := preload("res://world/relationships/shared_rest_policy.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const ARRIVAL_CONTEXT := preload("res://world/ai/arrival_context.gd")
var context: Node
var data: Dictionary = {"records": {}, "serial": 0, "seen": {}}
var adults: Dictionary = {}
var _staged: Dictionary = {}

## Courtship (dev 2026-09-29: "the process of becoming officially marefriend and coltfriend
## triggered by the ai after sufficient time with rejection mechanics"). Time spent near her adds
## up (together_s). Once she could date him (eligible "dating"), is fond of him (romance 25+) and
## they have spent READY_TOGETHER_S together, her prompt tells her she wants to ask him to be her
## coltfriend, in her own words, when the moment is right. If he says no she is hurt (a romance
## dip, a sad mood), waits three game days, and after two refusals never asks again (he still
## can). If she says no to him, he has to wait a game day; asking again sooner annoys her.
const READY_TOGETHER_S := 3600.0
const REFUSED_WAIT_DAYS := 3.0
const TURNED_DOWN_WAIT_DAYS := 1.0
const ASKS := 2
var _together: Dictionary = {}

func add_together(id: String, seconds: float) -> void:
	if not adults.get(id, false): return
	_together[id] = float(_together.get(id, 0.0)) + seconds
	if float(_together[id]) < 30.0: return
	var r := record_for(id)
	r["together_s"] = float(r.get("together_s", 0.0)) + float(_together[id])
	_together[id] = 0.0
	_save(id, r)

func ready_to_ask(id: String) -> bool:
	var r := record_for(id)
	if not eligible(id, "dating") or int(r.get("asks_left", ASKS)) <= 0: return false
	if offer_on_cooldown(id, "dating"): return false
	return float(r.get("together_s", 0.0)) >= READY_TOGETHER_S and interest(id) >= 25

## Asked again while she still wants time: a little less trust, and she is annoyed.
func pestered(id: String) -> void:
	var r := record_for(id)
	r.trust = maxf(0.0, float(r.trust) - 2.0)
	_save(id, r)
	if context != null and is_instance_valid(context.impressions):
		context.impressions.commit(id, {"mood": "annoyed", "thought": "%s asked me again already. I told %s I need time." % [str(_player_words().subject).capitalize(), _player_words().object]}, "pester_%d" % Time.get_ticks_usec())

func bind(store: Node) -> void:
	context = store
	data = store.state.get("player_bonds", {"records": {}, "serial": 0}).duplicate(true)
	if not data.has("seen"): data.seen = {}
	# Who has actually met Anon, kept apart from the relationship stage (dev 2026-10-02 plan,
	# docs/plans/AI_CONTEXT_AND_INTERRUPTION_RESILIENCE_2026_10_02.md "First meetings"). A world
	# from before this record exists gets "unknown" for everypony without evidence, never a reset.
	if not data.has("knowledge"):
		data.knowledge = {}
		var events: Array = store.state.get("events", []) if store.state.get("events") is Array else []
		data.knowledge_legacy = not data.records.is_empty() or not events.is_empty()
		# Kept with the world from now on, so a later load tells a new world from an old one.
		if not store._read_only: store.state.player_bonds = data.duplicate(true)
	# Offers, permission and timed plans are session-local; loading never penalizes
	# someone for time spent outside the game or resurrects physical consent.
	for row: Dictionary in data.records.values():
		row.offer = {}; row.permissions = {}
		if not row.plan.is_empty(): row.plan.deadline = now() + 900.0
	_staged.clear()

func register(id: String, adult: bool) -> void:
	adults[id] = adult

func now() -> float:
	return Time.get_unix_time_from_system()

func day() -> float:
	var clock := get_node_or_null("/root/TimeOfDay")
	return float(clock.day) + float(clock.hours) / 24.0 if clock != null else 0.0

func record_for(id: String) -> Dictionary:
	return data.records.get(id, {"stage":"acquaintance", "familiarity":0.0, "trust":0.0,
		"experiences":{}, "dates":0, "dating_since":-1.0, "engaged_since":-1.0,
		"shared_home_id":"", "offer":{}, "plan":{}, "permissions":{}, "cooldowns":{},
		"anger":0.0, "anger_at":0.0, "last_contact":0.0, "last_buck":0.0,
		"last_visit_day":-1, "last_met":0.0, "promises":[]}).duplicate(true)

## "met": completed speech, or the arrival's confirmed physical meeting receipt;
## "knows_name": she heard his name from him. A glance or touch is not an introduction.
func knowledge(id: String) -> Dictionary:
	var known: Dictionary = (data.get("knowledge", {}) as Dictionary).get(id, {})
	var arrival: Dictionary = ARRIVAL_CONTEXT.meeting_for(context.state, id) if is_instance_valid(context) else {}
	if not arrival.is_empty() and not bool(known.get("met", false)):
		# Repair the view, not the save: meeting receipts grant neither name knowledge
		# nor familiarity, romance, or permission.
		var projected := known.duplicate()
		projected.erase("unknown")
		projected.merge(arrival, true)
		return projected
	if not known.is_empty(): return known
	if bool(data.get("knowledge_legacy", false)):
		# An older world: a record with shared experiences is evidence enough of a meeting.
		var r: Dictionary = data.records.get(id, {})
		if not r.is_empty() and (float(r.get("familiarity", 0.0)) > 0.0 or not (r.get("experiences", {}) as Dictionary).is_empty()):
			return {"met": true, "knows_name": true, "evidence": "earlier play"}
		return {"unknown": true}
	return {"met": false, "knows_name": false}

func mark_met(id: String) -> void:
	_know(id, "met")

func mark_name_known(id: String) -> void:
	_know(id, "knows_name")

func _know(id: String, key: String) -> void:
	if context == null or context._read_only or id.is_empty(): return
	var all: Dictionary = data.get("knowledge", {})
	var known: Dictionary = (all.get(id, {}) as Dictionary).duplicate()
	if bool(known.get(key, false)): return
	known.erase("unknown")
	known[key] = true
	if key == "met" and not known.has("first_met"): known.first_met = now()
	all[id] = known
	data.knowledge = all
	context.state.player_bonds = data.duplicate(true)
	context._changed()

## One plain line for her prompt: first meeting, met, or unknown, and whether she knows his name.
func knowledge_line(id: String) -> String:
	var known := knowledge(id)
	var w := _player_words()
	var name_line := "" if bool(known.get("knows_name", false)) else " You do not know %s name yet: \"Anon\" is only how these notes refer to %s, so do not call %s that unless %s tells you." % [w.possessive, w.object, w.object, w.subject]
	if bool(known.get("unknown", false)):
		return "- Anon and you: you may or may not have met before; do not invent shared history or a past friendship." + name_line
	if not bool(known.get("met", false)):
		return "- Anon and you: this is your first meeting. You share no past and no history; be as warm as is natural for you, but never claim to know %s already." % w.object + name_line
	if str(known.get("evidence", "")) == "arrival receipts" and not bool(known.get("spoken", false)):
		return "- Anon and you: you have physically met in the Everfree, but your first conversation has not yet finished." + name_line
	return "- Anon and you: you have met and spoken before." + name_line

func _save(id: String, row: Dictionary) -> void:
	if context == null or context._read_only: return
	data.records[id] = row.duplicate(true)
	context.state.player_bonds = data.duplicate(true)
	context._changed()
	changed.emit(id)

func interest(id: String) -> int:
	return int(context.impressions.profile(id).love) if context != null and is_instance_valid(context.impressions) else 0

## Anger is the pony's own AI mood (dev 2026-09-28): a fresh angry/annoyed impression, which
## lapses after five minutes. Contact never adds scripted anger; old "anger" save fields are unused.
func anger(id: String) -> float:
	if context == null or not is_instance_valid(context.impressions): return 0.0
	match str(context.impressions.profile(id).mood):
		"angry": return 70.0
		"annoyed": return 40.0
	return 0.0

func eligible(id: String, kind: String) -> bool:
	if not adults.has(id) or kind not in KINDS: return false
	if kind in ROMANTIC and (not adults[id] or _young_player()): return false
	var r := record_for(id)
	var rank := STAGES.find(r.stage)
	if kind == "break_up": return rank >= 3
	if kind in ["date","outing"] and not r.plan.is_empty():return false
	if anger(id) >= 35.0: return false
	match kind:
		"outing", "hug": return true
		"date": return rank >= 1 and r.trust >= 15 and interest(id) >= 5
		"dating": return rank in [1,2] and r.dates >= 1 and r.trust >= 20 and interest(id) >= 5
		"move_in": return rank >= 3 and r.trust >= 35
		"engagement": return rank == 3 and r.dates >= 3 and r.trust >= 50 and day() - r.dating_since >= 3.0
		"marriage": return rank == 4 and day() - r.engaged_since >= 1.0
		"kiss", "flank_touch": return rank >= 3
	return false

func available(id: String) -> Array:
	return KINDS.filter(func(kind: String) -> bool: return eligible(id, kind))

func pending(id: String) -> Dictionary:
	var offer: Dictionary = record_for(id).offer
	return offer if not offer.is_empty() and float(offer.expires) > now() else {}

## Game-day refusal waits survive sleeping and configurable day lengths. Older wall-clock
## cooldowns remain readable until they expire; brief accepted-offer cooldowns still use them.
func offer_on_cooldown(id: String, kind: String) -> bool:
	var cooldowns: Dictionary = record_for(id).cooldowns
	return now() < float(cooldowns.get("offer:" + kind, 0.0)) or (kind == "dating" and day() < float(cooldowns.get("dating_day", -1.0)))

func offer(id: String, kind: String, by: String, activity := "walk", home := "", place := "") -> String:
	if context._read_only or by not in ["player", "pony"] or not eligible(id, kind): return ""
	if activity not in ACTIVITIES or (activity == "place" and place.is_empty()): return ""
	if not pending(id).is_empty(): return ""
	if kind in ["date","outing"] and not record_for(id).plan.is_empty():return ""
	if kind == "move_in" and home.is_empty(): return ""
	var r := record_for(id)
	if offer_on_cooldown(id, kind): return ""
	if kind == "dating" and by == "pony" and int(r.get("asks_left", ASKS)) <= 0: return ""
	data.serial = int(data.serial) + 1
	var key := "bond_%d" % int(data.serial)
	r.offer = {"id":key, "kind":kind, "by":by, "activity":activity, "home":home, "place":place, "expires":now()+180.0}
	_save(id, r)
	return key

func answer(id: String, key: String, by: String, accept: bool) -> bool:
	if context._read_only: return false
	var p := pending(id)
	if p.is_empty() or p.id != key or p.by == by or by not in ["player", "pony"]: return false
	if accept and not eligible(id, p.kind): return false
	var r := record_for(id)
	r.offer = {}
	r.cooldowns["offer:" + p.kind] = now() + (60.0 if accept else 300.0)
	if accept:
		match p.kind:
			"outing", "date":
				r.plan = {"id":p.id, "activity":p.activity, "place":str(p.get("place","")), "date":p.kind=="date", "accepted_at":now(), "deadline":now()+900.0}
				r.promises.append({"id":p.id,"activity":p.activity,"status":"pending"})
				while r.promises.size() > 16: r.promises.pop_front()
			"dating": r.stage = "dating"; r.dating_since = day()
			"move_in": r.shared_home_id = p.home
			"engagement": r.stage = "engaged"; r.engaged_since = day()
			"marriage": r.stage = "married"
			"kiss", "hug", "flank_touch": r.permissions[p.kind] = {"until":now()+120.0,"uses":4 if p.kind=="flank_touch" else 1}
			"break_up":
				r.stage = "close_friend"; r.shared_home_id = ""; r.permissions = {}; r.plan = {}
	elif p.kind == "dating":
		if p.by == "pony":
			# He turned her down: it hurts, she waits, and she only asks so many times.
			r.cooldowns["offer:dating"] = 0.0
			r.cooldowns["dating_day"] = day() + REFUSED_WAIT_DAYS
			r["asks_left"] = maxi(0, int(r.get("asks_left", ASKS)) - 1)
			if is_instance_valid(context.impressions):
				var words := _player_words()
				context.impressions.commit(id, {"romance": -2, "mood": "sad", "thought": "I asked Anon to be my %s and %s said no. It hurts; I'll give %s some space." % [words.partner, words.subject, words.object]}, "refused_" + str(p.id))
		else:
			r.cooldowns["offer:dating"] = 0.0
			r.cooldowns["dating_day"] = day() + TURNED_DOWN_WAIT_DAYS
	_save(id, r)
	context.record("relationship", "You and Anon %s the %s invitation%s." % ["both accepted" if accept else "did not agree to", p.kind.replace("_"," "), " ("+p.activity+")" if p.kind in ["date","outing"] else ""], [id,"player"], [id,"player"])
	return true

func request_space(id: String) -> bool:
	if context._read_only or not adults.has(id):return false
	var row:=record_for(id)
	row.permissions={};row.cooldowns.boundary=now()+180.0
	_save(id,row)
	context.record("relationship","You asked Anon for space; physical affection is currently unwelcome.",[id,"player"],[id,"player"])
	return true

func break_up(id: String) -> bool:
	if context._read_only or not eligible(id,"break_up"):return false
	var r:=record_for(id)
	r.stage="close_friend";r.shared_home_id="";r.permissions={};r.plan={};r.offer={}
	_save(id,r)
	context.record("relationship","Your romantic relationship with Anon ended. Do not assume continued romantic permission.",[id,"player"],[id,"player"])
	return true

## For a future physical nap invitation: this reports existing closeness, never grants it.
func rest_closeness(id: String) -> String:
	if not adults.get(id, false) or context == null: return "none"
	var row: Dictionary = record_for(id)
	var blocked: bool = anger(id) >= 35.0 or now() < float(row.cooldowns.get("boundary", 0.0)) or (_young_player() and str(row.stage) in ["dating", "engaged", "married"])
	return REST_POLICY.closeness(str(row.stage), welcomes(id, "hug"), blocked)

func permitted(id: String, kind: String) -> bool:
	var permission: Dictionary = record_for(id).permissions.get(kind, {})
	return eligible(id, kind) and float(permission.get("until",0.0)) > now() and int(permission.get("uses",0)) > 0

func consume_permission(id: String, kind: String) -> bool:
	if not permitted(id, kind): return false
	var r := record_for(id)
	r.permissions[kind].uses -= 1
	_save(id, r)
	return true

## Grey, not strict (dev 2026-09-28: "the boundaries are too strict, it's unrealistic; she LOVES
## me, she WANTS to kiss"). A partner (dating or further) welcomes kisses and playful smacks unless
## she is angry at him or asked for space; a mare who is attracted to Anon (romance 25+) and
## trusts him a little may welcome them too, unless annoyed. Hugs: friends, or anyone fond of him.
func welcomes(id: String, kind: String) -> bool:
	if not adults.get(id, false): return false
	if kind in ROMANTIC and _young_player(): return false
	var r := record_for(id)
	if now() < float(r.cooldowns.get("boundary", 0.0)): return false
	var mood := str(context.impressions.profile(id).mood) if is_instance_valid(context.impressions) else "neutral"
	if mood == "angry": return false
	if permitted(id, kind): return true
	var partner := STAGES.find(r.stage) >= 3
	var fond: bool = interest(id) >= 25 and float(r.trust) >= 10.0
	if kind == "hug": return partner or fond or STAGES.find(r.stage) >= 1 or r.trust >= 10.0
	if partner: return true
	return fond and mood != "annoyed"

func contact(id: String, kind: String) -> bool:
	var r := record_for(id)
	# Repetition no longer turns welcome affection unwelcome: kissing her again and again is the
	# point of being together. Only a rapid flurry of smacks from a non-partner counts against it.
	var frequent: bool = kind == "flank_touch" and STAGES.find(r.stage) < 3 and now() - float(r.cooldowns.get("contact:"+kind, -1000.0)) < 4.0
	var accepted := welcomes(id, kind) and not frequent
	if permitted(id,kind) and accepted: r.permissions[kind].uses -= 1
	r.cooldowns["contact:"+kind] = now()
	_save(id,r)
	if not accepted: unwanted_contact(id,"flank_smack" if kind=="flank_touch" else kind)
	return accepted

func experience(id: String, kind: String, event_id: String) -> bool:
	if context._read_only or not adults.has(id) or kind not in ACTIVITIES + ["conversation", "gift"]: return false
	var r := record_for(id)
	if event_id.is_empty() or data.seen.has(id+":"+event_id) or now() < float(r.cooldowns.get(kind,0.0)): return false
	data.seen[id+":"+event_id] = true
	while data.seen.size() > 512: data.seen.erase(data.seen.keys()[0])
	r.cooldowns[kind] = now() + (120.0 if kind=="conversation" else 600.0)
	var gains: Dictionary = PERSONALITY.gains(id, kind, int(r.experiences.get(kind, 0)))
	r.experiences[kind] = int(r.experiences.get(kind,0)) + 1
	r.familiarity = minf(100.0, r.familiarity + float(gains.familiarity))
	r.trust = minf(100.0, r.trust + float(gains.trust))
	r.last_met = now()
	if r.stage in ["acquaintance","friend","close_friend"]:
		r.stage = "close_friend" if r.familiarity >= 60 and r.trust >= 30 and r.experiences.size() >= 3 else ("friend" if r.familiarity >= 20 and r.trust >= 10 else "acquaintance")
	var plan: Dictionary = r.plan
	if not plan.is_empty() and plan.activity == kind and float(plan.deadline) >= now():
		if plan.date: r.dates += 1
		r.trust = minf(100.0, r.trust + PERSONALITY.kept_plan_trust(id))
		for promise: Dictionary in r.promises:
			if promise.id == plan.id: promise.status = "kept"
		r.plan = {}
	_save(id, r)
	context.record("shared_player_activity", "You and Anon completed %s together%s." % [kind, " on your agreed date" if not plan.is_empty() and plan.get("date",false) and r.plan.is_empty() else ""], [id,"player"], [id,"player"], "bond-"+event_id)
	return true

func cancel_plan(id: String) -> void:
	if context == null or context._read_only: return
	var r := record_for(id)
	if r.plan.is_empty(): return
	for promise: Dictionary in r.promises:
		if promise.id == r.plan.id: promise.status = "cancelled"
	r.plan = {}
	_save(id, r)
	context.record("cancelled_plan", "The walk ended after Anon left walking range.", [id,"player"], [id,"player"])

func expire_plan(id: String) -> void:
	var r := record_for(id)
	if r.plan.is_empty() or float(r.plan.deadline) > now(): return
	for promise: Dictionary in r.promises:
		if promise.id == r.plan.id: promise.status = "missed"
	r.trust = maxf(0.0,r.trust-3.0)
	r.plan = {}
	_save(id,r)
	context.record("missed_plan", "Your agreed outing with Anon did not happen in time. You do not know why.",[id,"player"],[id,"player"])

## Bucking is a last resort (dev 2026-09-28): the first refused kiss or smack gets only her
## reaction; doing it again within half a minute of being refused is what earns the buck.
func refused_again(id: String, kind: String) -> bool:
	var r := record_for(id)
	var key := "refused:" + kind
	var again := now() - float(r.cooldowns.get(key, -1000.0)) < 30.0
	r.cooldowns[key] = now()
	_save(id, r)
	return again

## Unwelcome contact costs a little trust. How she feels about it is her AI reaction's call.
func unwanted_contact(id: String, kind: String) -> float:
	if context._read_only or not adults.has(id): return 0.0
	var r := record_for(id)
	r.last_contact = now()
	r.trust = maxf(0.0,r.trust-2.0)
	_save(id,r)
	boundary.emit(id,anger(id),kind)
	return anger(id)

func prompt_for(id: String) -> String:
	var r := record_for(id)
	var known := knowledge(id)
	var stage := str(r.stage)
	if not bool(known.get("met", false)) and not bool(known.get("unknown", false)): stage = "none yet (you have not met)"
	var result := "Your actual relationship with Anon: %s. Trust %.0f/100; familiarity %.0f/100. Completed dates: %d. Shared home: %s." % [stage,r.trust,r.familiarity,r.dates,r.shared_home_id if not r.shared_home_id.is_empty() else "separate homes"]
	# The fixed rules (romance is separate from friendship, declining is allowed, no blanket permission,
	# no scores aloud, no unconfirmed milestones) ride once in the dialogue prompt's fixed head
	# (director_prompts.gd RELATIONSHIP_RULES); this block is only her live record.
	result += "\nYour friendship temperament: " + PERSONALITY.prompt(id)
	if not r.experiences.is_empty() or not r.promises.is_empty():
		result += "\nMeaningful shared experiences: " + JSON.stringify(r.experiences) + ". Promises: " + JSON.stringify(r.promises)
	result += "\nEligible relationship offers: " + JSON.stringify(available(id)) + "."
	var p := pending(id)
	if not p.is_empty(): result += "\nPending explicit offer: " + JSON.stringify(p) + ". Only the other participant may answer it."
	if not r.plan.is_empty(): result += "\nYour agreed plan, not yet completed: " + JSON.stringify(r.plan)
	if ready_to_ask(id):
		var w := _player_words()
		result += "\nYou have fallen for Anon over the time you have spent together, and you want to ask %s to be your %s. When a quiet, happy moment comes, ask %s in your own words, as a relationship_offer of kind dating. %s may say no; that would hurt, but it is %s choice." % [w.object, w.partner, w.object, str(w.subject).capitalize(), w.possessive]
	elif r.stage in ["friend", "close_friend"] and int(r.get("asks_left", ASKS)) <= 0:
		result += "\nAnon has turned you down twice. You will not ask him again. He may still ask you; your answer is your own choice and requires explicit mutual agreement."
	return result

## True while the player is a young AnonPony. Outside the tree (tests) the player is human Anon.
func _young_player() -> bool:
	return is_inside_tree() and PLAYER_FORM.is_young(PLAYER_FORM.active(get_tree()))

## {"subject", "object", "possessive", "noun", "partner"} for the player: he/him/his and
## "coltfriend" for human Anon (world/life/player_form.gd pronouns).
func _player_words() -> Dictionary:
	return PLAYER_FORM.pronouns(PLAYER_FORM.active(get_tree()) if is_inside_tree() else PLAYER_FORM.human())

static func valid_save(value: Variant) -> bool:
	if not value is Dictionary or not value.get("records") is Dictionary or value.records.size()>256: return false
	if not value.get("serial") is int and not value.get("serial") is float: return false
	for id: Variant in value.records:
		var r: Variant = value.records[id]
		if not id is String or not r is Dictionary or r.get("stage") not in STAGES: return false
		for key: String in ["familiarity","trust","dates","dating_since","engaged_since","anger","anger_at","last_contact","last_buck","last_visit_day","last_met"]:
			if not r.get(key) is int and not r.get(key) is float: return false
			if not is_finite(float(r[key])): return false
		for key: String in ["experiences","offer","plan","permissions","cooldowns"]:
			if not r.get(key) is Dictionary: return false
		if not r.get("promises") is Array or r.promises.size()>16 or not r.get("shared_home_id") is String: return false
		if not r.offer.is_empty():
			if r.offer.get("kind") not in KINDS or r.offer.get("by") not in ["pony","player"]: return false
			if not r.offer.get("id") is String or not r.offer.get("activity") in ACTIVITIES or not r.offer.get("home") is String: return false
			if not r.offer.get("expires") is float and not r.offer.get("expires") is int: return false
		if not r.plan.is_empty():
			if r.plan.get("activity") not in ACTIVITIES or not r.plan.get("id") is String or not r.plan.get("date") is bool: return false
			for key: String in ["accepted_at","deadline"]:
				if not r.plan.get(key) is int and not r.plan.get(key) is float: return false
		for permission: Variant in r.permissions.values():
			if not permission is Dictionary or not (permission.get("until") is float or permission.get("until") is int) or not (permission.get("uses") is float or permission.get("uses") is int): return false
		for v: Variant in r.cooldowns.values():
			if not (v is float or v is int) or not is_finite(float(v)): return false
		for v: Variant in r.experiences.values():
			if not (v is float or v is int): return false
		for p: Variant in r.promises:
			if not p is Dictionary or not p.get("id") is String or p.get("activity") not in ACTIVITIES or p.get("status") not in ["pending","kept","missed","cancelled"]: return false
	return true
