extends RefCounted
## Local dice and a temporary navigation claim; language is requested only on arrival.
const OWNER := "social:player_greeting"
var rng := RandomNumberGenerator.new()
var clock := 0.0
var next_roll := 90.0
var cooldowns: Dictionary = {}
var id := ""
var nav: Node
var actor: Node3D
var region := ""
var player_start := Vector3.ZERO
var deadline := 0.0
var talking := false
var lingering := false
## dev 2026-09-25: "ponies that come up to anon just walk away after a few seconds without even
## so much as a 'hello?' ... 'anooon?'". After her greeting she waits; if the player has not
## answered after NUDGE_AFTER seconds she tries once more, then says a puzzled goodbye.
const NUDGE_AFTER := 7.0
const GIVE_UP_AFTER := 12.0
const NUDGE := "[Observed situation, not player speech] You walked up to Anon and said something a few seconds ago, but he has not answered or reacted at all. Check whether he is listening, in character: a short 'Hello?', his name, a wave, or a playful poke at him ignoring you. One short sentence; no action tags needed."
const GIVE_UP := "Anon has not answered you at all, even after you tried again. Say a short, slightly puzzled or teasing goodbye in character and head off."
var nudged := false
var said_at := 0.0   # director clock when her last line finished
var previous: Dictionary = {}
var _tick := 0.0

func _init() -> void: rng.randomize()
func active() -> bool: return not id.is_empty()

func player_region(player: Node3D) -> String:
	return str(WorldLayout.nearest(player.global_position).get("id", ""))

func nearby(d: Node, pony: Node3D, radius: float, required_region: String) -> bool:
	if not is_instance_valid(pony) or not pony.is_inside_tree() or not pony.is_visible_in_tree(): return false
	if not is_instance_valid(d.player_head) or not d.player_head.is_inside_tree(): return false
	if pony.has_method("action_interruption_reason") and pony.action_interruption_reason() != "": return false
	if pony.has_method("is_held") and pony.is_held(): return false
	var flight: Variant = pony.get("flight")
	if flight != null and flight.active(): return false
	var offset: Vector3 = pony.global_position - d.player_head.global_position
	if offset.length() > radius or absf(offset.y) > 3.0: return false
	var here := str(pony.get_meta("navigation_region", WorldLayout.nearest(pony.global_position).get("id", "")))
	return not required_region.is_empty() and here == required_region

func eligible(d: Node, who: String, here: String, radius: float) -> bool:
	var pony: Node3D = d.characters[who].node
	if clock < float(cooldowns.get(who, 0.0)) or not nearby(d, pony, radius, here): return false
	if pony.has_method("is_speaking") and pony.is_speaking(): return false
	if d._now() - float(d.characters[who].get("chat_last", -1e9)) < 120.0: return false
	var company: Dictionary = pony.get_meta("social_group", {})
	if company.get("members", []).size() > 1 or str(company.get("id", "")).begins_with("rail:"): return false
	var navigator := pony.get_node_or_null("Navigator")
	return navigator != null and not is_instance_valid(navigator.get("_follow_target")) and (navigator.command_owner.is_empty() or navigator.command_owner.begins_with("life:"))

func tick(d: Node, delta: float) -> void:
	clock += delta; _tick -= delta
	if _tick > 0: return
	_tick = .5
	if not bool(d.config.get_value("player_approaches/enabled", true)) or not preload("res://world/ai/ai_config.gd").background_allowed(d.config):
		end(d); return
	if active():
		advance(d); return
	if clock < next_roll: return
	if d.state != "idle" or d.group.active() or d.speech.state == "hearing" or not d.ambient_budget.available(): return
	if not is_instance_valid(d.player_head) or not d.player_head.is_inside_tree(): return
	# Give an existing player conversation room, even between its spoken turns.
	for entry in d.characters.values():
		if d._now() - float(entry.get("chat_last", -1e9)) < 45.0: return
	next_roll = clock + 30.0 # Never replay missed rolls after a hitch.
	if rng.randf() >= clampf(float(d.config.get_value("player_approaches/chance", .2)), 0, 1): return
	var here := player_region(d.player_head)
	var radius := clampf(float(d.config.get_value("player_approaches/radius_m", 24.0)), 3, 40)
	var candidates: Array[String] = []
	for who: String in d.characters:
		if eligible(d, who, here, radius): candidates.append(who)
	# One pony wins the opportunity, independent of population density.
	if candidates.is_empty(): return
	var who: String = candidates[rng.randi_range(0, candidates.size()-1)]
	var pony: Node3D = d.characters[who].node
	var navigator: Node = pony.get_node("Navigator")
	if not navigator.command_target_visible(d.player_head): return
	var toward: Vector3 = pony.global_position - d.player_head.global_position; toward.y = 0
	if toward.length() < .1: return
	var goal: Vector3 = navigator.command_support(d.player_head.global_position + toward.normalized()*2.0)
	if not goal.is_finite() or absf(goal.y - pony.global_position.y) > 3.0: return
	id = who; actor = pony; nav = navigator; region = here; player_start = d.player_head.global_position
	previous = {"owner":nav.command_owner,"wander":nav.wander_enabled,"limit":nav.command_speed_limit,"pace":nav.command_pace_target}
	cooldowns[id] = clock + maxf(60, float(d.config.get_value("player_approaches/pony_cooldown_seconds", 900)))
	next_roll = clock + maxf(30, float(d.config.get_value("player_approaches/cooldown_seconds", 120)))
	deadline = clock + 35.0; talking = false
	nav.command_owner = OWNER; nav.wander_enabled = false
	nav.command_speed_limit = INF; nav.command_pace_target = -1.0
	if pony.has_method("request_posture"): pony.request_posture("stand")
	if not nav.command_destination(goal, "trot"): cancel()

func advance(d: Node) -> void:
	if not d.characters.has(id) or not is_instance_valid(d.player_head) or not nearby(d, actor, 28.0, region):
		end(d); return
	if player_region(d.player_head) != region or d.player_head.global_position.distance_to(player_start) > 5.0:
		end(d); return
	if lingering:
		# The player answered (or is answering): hand her to the conversation; engaged() keeps her.
		var answered: bool = float(d.characters[id].get("chat_last", -1e9)) > said_at + 0.5 \
			or d.speech.state == "hearing" or (d.state != "idle" and d._current == id and not d._proactive_turn)
		if answered: cancel(); return
		if d.state != "idle": return
		var quiet: float = d._now() - said_at
		if not nudged and quiet >= NUDGE_AFTER:
			nudged = true; lingering = false; talking = true
			if not d.begin_player_greeting(id, NUDGE): cancel()
			return
		if nudged and quiet >= GIVE_UP_AFTER:
			var who := id
			cancel()
			d.request_farewell(who, GIVE_UP)
			return
		if clock >= deadline: cancel()
		return
	if talking:
		if not d._proactive_turn or d.state == "idle": cancel()
		return
	if not is_instance_valid(nav) or nav.command_owner != OWNER or clock > deadline or d.state != "idle" or d.speech.state == "hearing":
		cancel(); return
	# State alone is not arrival: wait for actual proximity and unobstructed hearing.
	if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED, nav.State.INTERRUPTED]: cancel(); return
	var offset: Vector3 = actor.global_position - d.player_head.global_position
	if Vector2(offset.x, offset.z).length() > 2.8: return
	if not d.awareness.can_hear(actor, d.player_head, 4.0): cancel(); return
	nav.stay(); talking = true
	if not d.begin_player_greeting(id): cancel()

func finished(d: Node = null) -> void:
	if not active(): return
	talking = false; lingering = true; deadline = clock + 30.0
	said_at = d._now() if d != null else 0.0

func end(d: Node) -> void:
	if talking and d._proactive_turn and not d.speech_committed(): d.interrupt()
	cancel()

func cancel() -> void:
	if is_instance_valid(nav) and nav.command_owner == OWNER:
		nav.stay(); nav.command_owner = previous.owner; nav.wander_enabled = previous.wander
		nav.command_speed_limit = previous.limit; nav.command_pace_target = previous.pace
	id = ""; actor = null; nav = null; talking = false; lingering = false; nudged = false; previous.clear()
