extends RefCounted
## Read-only projection of saved arrival receipts and current transport commitment. These facts survive recent-event
## eviction, but belong only to the participant who witnessed them or received the message.
const TWILIGHT := "twilight_sparkle"

static func _arrival(state: Dictionary) -> Dictionary:
	var value: Variant = state.get("arrival")
	if not value is Dictionary: return {}
	var arrival: Dictionary = value
	if arrival.has("skipped"): return {}
	return arrival

static func _welcomed(arrival: Dictionary) -> bool:
	# These later stages can only be entered after the delivered welcome. A bare
	# legacy done marker is not evidence: older worlds deliberately skip the story.
	var stage := str(arrival.get("stage", ""))
	if bool(arrival.get("welcome_said", false)): return true
	# A house a pony gave later (arrival_story.gd grant_home) is no evidence of Celestia's welcome.
	if not str(arrival.get("home_given_by", "")).is_empty(): return false
	return stage in ["to_home", "home", "key", "done"] and not str(arrival.get("home", "")).is_empty()

static func meeting_for(state: Dictionary, speaker: String) -> Dictionary:
	var arrival := _arrival(state)
	if arrival.is_empty(): return {}
	if speaker == TWILIGHT:
		var spoken: bool = bool(arrival.get("speech_found", false)) or bool(arrival.get("teleported", false)) or bool(arrival.get("shelter_explained", false)) or bool(arrival.get("celestia_briefed", false)) or _welcomed(arrival)
		if bool(arrival.get("forest_met", false)) or spoken:
			return {"met": true, "spoken": spoken, "evidence": "arrival receipts"}
	elif speaker == "celestia" and _welcomed(arrival):
		return {"met": true, "spoken": true, "evidence": "arrival receipts"}
	return {}

static func frame_for(state: Dictionary, speaker: String) -> String:
	var arrival := _arrival(state)
	if arrival.is_empty() or speaker not in [TWILIGHT, "celestia"]: return ""
	var facts: Array[String] = []
	var welcomed := _welcomed(arrival)
	if speaker == TWILIGHT:
		if not meeting_for(state, speaker).is_empty():
			facts.append("Twilight Sparkle: you found the confused newcomer alone in the Everfree Forest. At that meeting their origin was unknown; this establishes a meeting, not a friendship or knowledge of their name.")
		if bool(arrival.get("teleported", false)):
			facts.append("You already rescued the newcomer from the Everfree by teleporting both of you to Ponyville. Leaving the forest is completed history, not a future rescue or teleport still to perform.")
		elif str(arrival.get("stage", "")) == "found" and bool(arrival.get("transport_requested", false)):
			facts.append("You have already committed to teleport the newcomer to Golden Oak. Transport is still pending: come back beside them before casting. Do not forget this commitment, start walking to Ponyville instead, or claim you have arrived.")
		elif bool(arrival.get("shelter_explained", false)) or bool(arrival.get("celestia_briefed", false)) or welcomed:
			facts.append("You already brought the newcomer out of the Everfree to safety; the rescue is completed history.")
		if bool(arrival.get("shelter_explained", false)):
			facts.append("You sheltered the newcomer inside Golden Oak Library and offered its downstairs guest bed.")
		if bool(arrival.get("celestia_briefed", false)):
			facts.append("You sent Celestia a message about finding the newcomer in the Everfree and sheltering them at Golden Oak.")
		if welcomed:
			facts.append("Celestia already met and welcomed the newcomer and offered a permanent free Ponyville home, with no rent, debt or repayment. The welcome is completed, not a future appointment.")
		var home := str(arrival.get("home", ""))
		if not home.is_empty(): facts.append("The newcomer's assigned home is %s." % home)
		if not home.is_empty():
			facts.append("The home is freely usable: ponies do not lock their homes or use house keys.")
		if bool(arrival.get("done_explained", false)):
			facts.append("You explained the confirmed bed, furniture, welcome food and 50 bits already provided; the newcomer is free to choose their next activity.")
	else:
		if bool(arrival.get("celestia_briefed", false)) or welcomed:
			facts.append("Celestia: Twilight's message told you she found the confused newcomer in the Everfree and brought them to safety. You learned this from Twilight; you did not witness the forest encounter or perform the rescue.")
		if welcomed:
			facts.append("You already met and welcomed the newcomer and offered a permanent free Ponyville home, with no rent, debt or repayment. Your welcome is completed, not a future appointment.")
	if facts.is_empty(): return ""
	return "Participant %s's durable arrival knowledge (ONLY %s's own knowledge, usable in their own speech; other participants did not thereby witness or learn this past; saved completed facts take precedence over older encounter plans):\n- %s" % [speaker, speaker, "\n- ".join(facts)]
