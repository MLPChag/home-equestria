extends RefCounted
## Chat holds, goodbyes and lulls: who is engaged in a conversation, when she says bye, when she speaks first.
## Split out of conversation_director.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning conversation_director node; shared state stays there.


var host: Node
var _patience: Dictionary = {}      # id -> chat length (s) after which she wants to move on
## Goodbyes the director decides itself: the player went quiet, the chat ran long, or bedtime.
## Not when they are together at home (dev 2026-09-28: "we are together in our house. she
## shouldn't always literally leave"): there a lull just ends the chat and she stays.
var _farewell_wait := 0.0
## Mid-conversation lull: after 15–30 s after the last reply, a chance the pony
## speaks first (once per lull, only while the chat is live and she can hear the player).
var _lull_wait:=0.0
## A lull prompt costs a whole dialogue request (~12k tokens). One per pony per chat, and at most
## one per LULL_GAP_SECONDS across all ponies: in a group each pony used to get her own lull
## 14-19 s after another's (tester capture 2026-10-22).
const LULL_GAP_SECONDS := 60.0
var _lull_next_at := -1e9


func _init(owner_node: Node) -> void:
	host = owner_node


func participant_busy(id: String) -> bool:
	return host.state != "idle" and (id == host._current or (host.group.active() and id in host.group.members))


func engaged(id: String) -> bool:
	if not host.characters.has(id): return false
	# Speaking a transaction line must not evict its customer from the counter's
	# navigation lease. The shared voice channel still reports participant_busy.
	if not host._authored_active.is_empty() and id == host._current: return false
	if participant_busy(id) or (host.group.active() and id in host.group.members): return true
	var entry: Dictionary = host.characters[id]
	if not entry.has("chat_last") or host._now() - float(entry.chat_last) > host.CHAT_HOLD_SECONDS: return false
	# After her goodbye she is free until the player talks to her again.
	if float(entry.chat_last) <= float(host._released.get(id, -1e9)): return false
	var node: Variant = entry.node
	return is_instance_valid(node) and is_instance_valid(host.player_head) and node.is_inside_tree() \
		and host.awareness.can_hear(node, host.player_head, host._earshot(id))


## Engaged and not walking along with a talking group: stays where she is, no wandering.
func holds_in_place(id: String) -> bool:
	return engaged(id) and not host.movement_dialogue_allowed(id)


## She has somewhere to be: a short goodbye in her own words, then she is free to leave.
## Group exchanges are short and bounded; she stays for the end of one instead.
func request_farewell(id: String, reason: String) -> bool:
	if not engaged(id) or host._farewell.has(id) or (host.group.active() and id in host.group.members): return false
	if host._encounter_claimed(id): return false
	if host.state != "idle" or host.speech.state == "hearing": return false
	host._farewell[id] = host._now() + 15.0
	host._farewell_reason = reason
	host._on_physical_reaction("farewell", id)
	if host.state == "idle": _release(id)   # nothing could be said: just go
	return true


func _release(id: String) -> void:
	host._farewell.erase(id)
	_patience.erase(id)
	host._released[id] = host._now()
	if host.characters.has(id): host.characters[id].erase("chat_since")
	host._set_attention(id, null)


## Showing the player the way is a promise kept until they arrive or he walks off (the executor
## ends the lead then). A quiet walk, a long chat or the late hour must not end it in a goodbye:
## Twilight's tour after the intro, the longest chat of a new game, turned back halfway.
func _leading_player(id: String) -> bool:
	if not is_instance_valid(host.actions): return false
	var executor: Variant = host.actions.executors.get(id)
	if not is_instance_valid(executor): return false
	var movement: Dictionary = executor.movement
	return str(movement.get("type", "")) == "lead" and str(movement.get("target_id", "")) == "player"


func _together_at_home(id: String) -> bool:
	if not host.characters.has(id) or not is_instance_valid(host.player_head): return false
	var node: Variant = host.characters[id].node
	if not is_instance_valid(node): return false
	var runtime: Node = host.get_tree().get_first_node_in_group("player_relationships")
	var partner: bool = runtime != null and is_instance_valid(runtime.bonds) and str(runtime.bonds.record_for(id).stage) in ["dating", "engaged", "married"]
	var house: Node3D = preload("res://world/buildings/house_interior.gd").at(host.get_tree(), host.player_head.global_position)
	var same_house: bool = house != null and house == preload("res://world/buildings/house_interior.gd").at(host.get_tree(), (node as Node3D).global_position)
	return partner or same_house


func _check_farewells(delta: float) -> void:
	_farewell_wait -= delta
	if _farewell_wait > 0.0: return
	_farewell_wait = 1.0
	for id in host._farewell.keys():
		if host._now() > float(host._farewell[id]): _release(id)
	if host.state != "idle" or host.group.active(): return
	var hours: float = host.get_node("/root/TimeOfDay").hours if host.has_node("/root/TimeOfDay") else 12.0
	for id in host.characters:
		if not engaged(id) or host._farewell.has(id) or host.quiet_moment(id) or host._encounter_claimed(id): continue
		if _leading_player(id): continue
		var entry: Dictionary = host.characters[id]
		var quiet: float = host._now() - maxf(float(entry.chat_last), float(entry.get("last_spoken_at", -1e9)))
		var length: float = host._now() - float(entry.get("chat_since", entry.chat_last))
		if not _patience.has(id): _patience[id] = host._reaction_rng.randf_range(240.0, 540.0)
		var reason := ""
		if _together_at_home(id):
			# A partner, or anypony in the same house as him: a lull ends the chat, she stays put.
			if quiet > 90.0 or length > float(_patience[id]) * 2.0: _release(id)
			continue
		if hours >= 22.0 or hours < 5.0: reason = "It is late; bedtime is coming."
		elif quiet > 50.0: reason = "The player has gone quiet for a while."
		elif length > float(_patience[id]): reason = "You have been chatting a good while and may have other things to do today."
		if reason != "" and request_farewell(id, reason): return


func _maybe_contribute(delta:float)->void:
	_lull_wait-=delta
	if _lull_wait>0.0:return
	_lull_wait=0.5
	if host.state!="idle" or host.speech.state=="hearing" or host.group.active():return
	if host._now() < _lull_next_at: return
	# Filling a silence is the game's idea, not the player's: only with AI usage "full".
	if not preload("res://world/ai/ai_config.gd").background_allowed(host.get("config")): return
	for id in host.characters:
		if host._authored_holds(str(id)) or host.quiet_moment(str(id)): continue
		var entry:Dictionary=host.characters[id]
		if not entry.has("chat_last"):continue
		var quiet:float=host._now()-maxf(float(entry.chat_last), float(entry.get("last_spoken_at", -1e9)))
		if quiet>45.0 or float(entry.get("lull_used",-1.0))==float(entry.chat_last):continue
		if not entry.has("lull_after"):entry["lull_after"]=host._reaction_rng.randf_range(15.0,30.0)
		if quiet<float(entry.lull_after):continue
		entry["lull_used"]=entry.chat_last;entry.erase("lull_after")
		_lull_next_at = host._now() + LULL_GAP_SECONDS
		host._on_physical_reaction("quiet",id)
		return
