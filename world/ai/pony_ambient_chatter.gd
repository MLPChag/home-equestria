extends RefCounted
## Cheap per-pony dice; only a winning moment reaches the dialogue provider.
const HEARING := preload("res://world/ai/pony_group_conversation.gd").RANGE
## A pony this close to the one who starts talking is in the conversation, no dice: Twilight must not
## greet Lemon Hearts at her elbow as a lone remark that Lemon answers a minute later (dev 2026-10-14).
const FACE_TO_FACE := 4.0
## Command owners a conversation may pause: wandering, the living world, outings, chat stops.
const YIELDING_OWNERS := ["", "life:", "social:", "chat:"]
var rng := RandomNumberGenerator.new()
var next_opportunity: Dictionary = {}
var statistics := {"rolls":0, "reply_rolls":0, "attempts":0, "hearing_checks":0}

func _init() -> void:
	rng.randomize()

func eligible(node: Node3D, player: Node3D, radius: float) -> bool:
	if not is_instance_valid(node) or not node.is_inside_tree() or not node.is_visible_in_tree(): return false
	if node.get_meta("active_follow", false): return false
	if node.has_method("is_held") and node.is_held(): return false
	if node.get("sleeping") == true: return false
	if node.has_method("is_speaking") and node.is_speaking(): return false
	if node.has_method("action_interruption_reason") and node.action_interruption_reason() != "": return false
	if on_errand(node): return false
	return node.global_position.distance_squared_to(player.global_position) <= radius*radius

## Walking somewhere on a plan step or command a conversation cannot pause: she would talk over
## her shoulder and walk off. Standing at her task (a visit, tending) she may still chat.
static func on_errand(node: Node) -> bool:
	var nav: Node = node.get_node_or_null("Navigator")
	if nav == null or nav.get("_has_target") != true: return false
	var owner := str(nav.get("command_owner"))
	for prefix: String in YIELDING_OWNERS:
		if (prefix == "" and owner == "") or (prefix != "" and owner.begins_with(prefix)): return false
	return true

func choose(characters: Dictionary, player: Node3D, awareness: RefCounted, now: float,
		radius: float, chance: float, reply_chance: float, quiet_seconds: float) -> Array[String]:
	var candidates: Array[String] = []
	var winner := ""; var best_score := INF
	for id: String in characters:
		if now - float(characters[id].get("chat_last", -1e9)) < 120.0: continue
		var node: Node3D = characters[id].node
		if not eligible(node,player,radius): continue
		candidates.append(id)
		if now < float(next_opportunity.get(id,0.0)): continue
		statistics.rolls += 1
		if rng.randf() >= chance: continue
		# Prefer audible company when several opportunities coincide; distant life
		# remains eligible without monopolizing the single conversation channel.
		var weight := 4.0 if node.global_position.distance_squared_to(player.global_position) <= 30.0*30.0 else 1.0
		# Friends out together talk far more than ponies standing about alone (dev 2026-09-23).
		if _company(node).size() > 1: weight *= 4.0
		var score := -log(maxf(rng.randf(),.000001)) / weight
		if score < best_score: best_score = score; winner = id
	if winner == "": return []
	var result: Array[String] = [winner]
	var responders: Array[String] = []
	# A pony out with friends talks with them, not with whoever is standing nearby.
	var company := _company(characters[winner].node)
	var close: Array = []
	for id in candidates:
		if id == winner: continue
		if company.size() > 1 and id not in company: continue
		var gap: float = awareness.point(characters[id].node).distance_to(awareness.point(characters[winner].node))
		if gap > HEARING: continue
		if gap <= FACE_TO_FACE and reply_chance > 0.0: close.append({"id":id, "gap":gap}); continue
		statistics.reply_rolls += 1
		if rng.randf() < reply_chance: responders.append(id)
	# Shuffle with this scheduler's seeded RNG; all nearby ponies had a reply roll.
	for i in range(responders.size()-1,0,-1):
		var j := rng.randi_range(0,i); var temp: String = responders[i]
		responders[i] = responders[j]; responders[j] = temp
	# Face-to-face company first, nearest first, ahead of the shuffled rolls.
	close.sort_custom(func(a, b): return a.gap < b.gap)
	var ordered: Array = close.map(func(item): return str(item.id))
	ordered.append_array(responders)
	for id in ordered.slice(0,12):
		var compatible := true
		for member in result:
			statistics.hearing_checks += 1
			var hearing := HEARING
			if not awareness.can_hear(characters[id].node,characters[member].node,hearing): compatible=false;break
		if compatible: result.append(id)
		if result.size() == 3: break
	for id in result: next_opportunity[id] = now + quiet_seconds
	for id in next_opportunity.keys():
		if not characters.has(id) and float(next_opportunity[id]) <= now: next_opportunity.erase(id)
	statistics.attempts += 1
	return result

## Members of the living-world outing this pony is on (meta "social_group"), else [].
static func _company(node: Node) -> Array:
	if not is_instance_valid(node) or not node.has_meta("social_group"): return []
	var company: Variant = node.get_meta("social_group")
	return company.get("members", []) if company is Dictionary else []
