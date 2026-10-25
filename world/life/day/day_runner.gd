extends Node
## Runs the day cards (world/life/day/day_planner.gd; docs/DAY_PLANS.md). Every morning each
## resident gets a card; when a step's hour comes she does it through its handler
## (world/life/day/actions/<handler>.gd), which owns her navigator as "day:<id>" while it runs.
## Between steps she is free: the living world takes her back for wandering, friends, company and
## invitations. A step that comes while she is already out with friends may wait (sidetracked)
## until its deadline, and is dropped after that. Bedtime (NightRest) wins over any step; night
## owls (NightRest's roll) get steps until their late bedtime.
##
## Unloaded residents keep their plans (dev 2026-09-26: "their MODEL should unload but their
## essence ... continues to live"): their steps run on the living world record instead
## (world/life/essence.gd), walking it to the place, staying, and moving on. A pony who streams
## in mid-step picks the step up with her body; one who streams out carries on as essence.

const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
const PLANNER := preload("res://world/life/day/day_planner.gd")
const ACTION := preload("res://world/life/day/day_action.gd")
const ESSENCE := preload("res://world/life/essence.gd")
const ACTION_DIR := "res://world/life/day/actions/"
const NIGHT_REST := preload("res://world/life/night_rest.gd")
const KIT_STATE := preload("res://world/props/ponyville_kit/kit_state.gd")
const CHECK := 0.5
const FIDGETS := preload("res://world/life/day/pony_fidgets.gd")
## Idle fidget pickers by resident id (pony_fidgets.gd), ticked on the same half-second beat.
var _fidgets: Dictionary = {}
## Chat stops between free wanderers who meet (chat_stops.gd), same beat.
var chats: RefCounted = preload("res://world/life/day/chat_stops.gd").new()

var population: Node
var night_rest: Node
var clock: Node
var cards := {}          # id -> {"day", "steps", "index", "action", "ctx", "sidetracked", "essence", "shown_on"}
## Residents a town event holds for now, body or essence (show_audience.gd: walking to or
## watching Trixie's show): her day plan waits and carries on once she is let go.
var held: Dictionary = {}
var _timer := 0.0
static var _handlers := {}
static var _traits_cache := {}

func setup(people: Node, rest: Node) -> void:
	population = people
	night_rest = rest
	clock = get_node_or_null("/root/TimeOfDay")
	add_to_group("day_runner")

func life() -> Node:
	return get_parent().get("life") if get_parent() != null else null

## The hour on the card's own clock: past midnight counts on from 24 until 05:00.
func _card_hours() -> float:
	var h := float(clock.hours)
	return h + 24.0 if h < 5.0 else h

func _day_key() -> int:
	return int(clock.day) - (1 if float(clock.hours) < 5.0 else 0)

func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(delta)
	if started > 0: CPU_PROFILE.record("day_runner", started)

func _physics_step(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0 or population == null or clock == null: return
	_timer = CHECK
	var day := _day_key()
	var kit_state: Node = KIT_STATE.for_node(self)
	if kit_state != null: kit_state.advance_day(day)
	var hours := _card_hours()
	var live: Dictionary = {}
	var busy: Dictionary = {}
	for id: String in population.config.assignments.keys():
		var actor: Node3D = population.live.get(id, {}).get("actor")
		var alive := is_instance_valid(actor) and actor.is_inside_tree()
		if not alive and not ESSENCE.unloaded(population, id): continue   # visiting, on the train
		if held.has(id): continue
		var card: Dictionary = cards.get(id, {})
		if card.is_empty() or card.get("day", -1) != day:
			_end_card(id, card)
			card = {"day": day, "steps": PLANNER.roll(id, day, _info(id, actor if alive else null, day)), "index": 0,
				"action": null, "ctx": {}, "sidetracked": false, "essence": {}, "shown_on": null}
			card.index = mini(_resumed_index(id, day), card.steps.size())
			cards[id] = card
		if alive:
			if not card.essence.is_empty(): _essence_to_body(id, card)
			if card.shown_on != actor: _publish(id, actor, card)
			_step(id, actor, card, hours)
			var picker: RefCounted = _fidgets.get(id)
			if picker == null:
				picker = FIDGETS.new()
				_fidgets[id] = picker
			picker.tick(actor, id, CHECK, not _idle_ok(id, card))
			live[id] = actor
			if card.action != null: busy[id] = true
		else:
			if card.action != null: _body_to_essence(id, card)
			_step_essence(id, card, hours)
	chats.tick(live, busy, CHECK)
	for id: String in cards.keys():
		if not population.config.assignments.has(id):
			_end_card(id, cards[id])
			cards.erase(id)
			_fidgets.erase(id)

## Where each resident is in today's card, for the save (game_saves.gd "day_plans"). A step
## running at save time starts again on load; earlier ones are not redone.
func checkpoint() -> Dictionary:
	var result := {}
	var pending: Variant = population.get("resumed_plans") if population != null else null
	if pending is Dictionary: result = (pending as Dictionary).duplicate(true)
	for id: String in cards:
		var card: Dictionary = cards[id]
		if not card.is_empty(): result[id] = {"day": int(card.day), "index": int(card.index)}
	return result

## The step a loaded save had her on (pony_population.resumed_plans), when it is today's card.
func _resumed_index(id: String, day: int) -> int:
	var plans: Variant = population.get("resumed_plans")
	if not plans is Dictionary or not (plans as Dictionary).has(id): return 0
	var row: Dictionary = plans[id]
	(plans as Dictionary).erase(id)
	return int(row.index) if int(row.day) == day else 0

## A covered overnight move starts a fresh local day without retaining an old-town action.
func changed_residence(id: String) -> void:
	_end_card(id, cards.get(id, {}))
	cards.erase(id)
	_fidgets.erase(id)

func _end_card(id: String, card: Dictionary) -> void:
	if card.is_empty(): return
	if card.get("action") != null: card.action.stop(card.ctx)
	_cancel_step_state(card.get("ctx", {}))
	card.action = null
	card.essence = {}
	_set_busy(id, false)

## Cleanup still runs after a streamed/freed actor loses its Navigator.
func _cancel_step_state(ctx: Dictionary) -> void:
	var state: Node = ctx.get("kit_state") if is_instance_valid(ctx.get("kit_state")) else KIT_STATE.for_node(self)
	if state != null: state.cancel_step(str(ctx.get("step_key", "")))

func _set_busy(id: String, busy: bool) -> void:
	var resident := ESSENCE.record(population, id)
	if resident.is_empty(): return
	if busy: resident["day_busy"] = true
	else: resident.erase("day_busy")

func _info(id: String, actor: Node3D, day: int) -> Dictionary:
	var times: Vector2 = NIGHT_REST.bedtime(id, day)
	var bed := times.x + (24.0 if times.x < 12.0 else 0.0)
	var friends: Array = []
	var core = life().get("core") if life() != null else null
	if core != null and core.state.residents.has(id):
		var profile: Dictionary = core.state.residents[id].get("profile", {})
		var weights: Dictionary = profile.get("friends", {})
		for f in weights:
			if float(weights[f]) > 0.0 and population.config.assignments.has(f): friends.append(f)
	var others: Array = population.config.assignments.keys()
	var traits := _traits(id, actor)
	return {"spots": ACTION.SPOTS.available(population, id), "wings": traits.wings, "horn": traits.horn, "friends": friends, "others": others, "bed": bed, "wake": NIGHT_REST.bedtime(id, day - 1).y}

## Wings and horn from her identity: the live rig's, or read from her scene's identity file
## without loading the model (race and can_fly lines; absent = the script defaults, a pegasus
## who can fly).
func _traits(id: String, actor: Node3D) -> Dictionary:
	var identity = actor.get("identity") if actor != null else null
	if identity != null:
		var can_fly: bool = identity.get("can_fly") if identity.get("can_fly") != null else true
		_traits_cache[id] = {"wings": identity.has_wings() and can_fly, "horn": identity.has_method("has_horn") and identity.has_horn()}
	if _traits_cache.has(id): return _traits_cache[id]
	var result := {"wings": false, "horn": false}
	var scene: String = population.available.get(id, "")
	if FileAccess.file_exists(scene):
		var text := FileAccess.get_file_as_string(scene)
		var ref := RegEx.create_from_string("identity = ExtResource\\(\"([^\"]+)\"\\)").search(text)
		if ref != null:
			var res := RegEx.create_from_string("\\[ext_resource[^\\]]*path=\"([^\"]+)\"[^\\]]*id=\"" + ref.get_string(1) + "\"").search(text)
			if res != null and FileAccess.file_exists(res.get_string(1)):
				var tres := FileAccess.get_file_as_string(res.get_string(1))
				var race_match := RegEx.create_from_string("(?m)^race = (\\d+)").search(tres)
				var race := int(race_match.get_string(1)) if race_match != null else 1
				var grounded := RegEx.create_from_string("(?m)^can_fly = false").search(tres) != null
				result = {"wings": race in [1, 3] and not grounded, "horn": race in [2, 3]}
	_traits_cache[id] = result
	return result

func _step(id: String, actor: Node3D, card: Dictionary, hours: float) -> void:
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null:
		if card.get("action") != null:
			_end_card(id, card)
			card.index += 1
		return
	var running = card.get("action")
	if running != null:
		# Somepony or something else took her (bedtime, the player, a command): the step ends.
		if str(nav.command_owner) != "day:" + id:
			running.stop(card.ctx)
			_cancel_step_state(card.ctx)
			card.action = null
			card.index += 1
			_set_busy(id, false)
			_publish(id, actor, card)
			return
		var result: String = running.tick(card.ctx, CHECK)
		if result != "running":
			if result == "done": _remember(id, actor, card.steps[card.index])
			running.release(card.ctx)
			_cancel_step_state(card.ctx)
			card.action = null
			card.index += 1
			card.sidetracked = false
			_set_busy(id, false)
			_publish(id, actor, card)
		return
	if card.index >= card.steps.size(): return
	var step: Dictionary = card.steps[card.index]
	if hours > float(step.until):
		card.index += 1   # the moment passed (sidetracked, asleep, busy): let it go
		_publish(id, actor, card)
		return
	if hours < float(step.start) or not _free(actor, nav): return
	# Out with friends when the next thing comes up: sometimes she stays with them.
	var group: Dictionary = actor.get_meta("social_group", {})
	if group.get("members", []).size() > 1 and _sidetracked(id, card, step): return
	if str(step.handler) != "joyride" and not _in_home_town(id, _step_point(id, step)):
		card.index += 1
		_publish(id, actor, card)
		return
	var action: RefCounted = _handler(str(step.handler))
	if action == null:
		card.index += 1; return
	var ctx := {"id": id, "actor": actor, "nav": nav, "step": step, "runner": self, "population": population,
		"night_rest": night_rest, "tree": get_tree(), "kit_state": KIT_STATE.for_node(self),
		"day": int(card.day), "step_key": "%s:%d:%d" % [id, int(card.day), int(card.index)]}
	if action.start(ctx):
		card.action = action
		card.ctx = ctx
		_set_busy(id, true)
		actor.set_meta("life_intent", "Today's plan: " + _text(step))
	else:
		# A refused start may have taken a spot, prop or lease before refusing; stop() frees only
		# what this handler owns (exact "day:<id>" owner), so a newer owner keeps her.
		action.stop(ctx)
		card.index += 1
	_publish(id, actor, card)

## Handlers whose "stay" phase is only standing (or sitting) about at a place: she may fidget
## there (pony_fidgets.gd). Any other step works her body, or travels.
const IDLE_STAYS := ["go_to", "visit"]

## Free for idle fidgets: no step, or a step that is just spending time; never while the arrival
## story or a visit elsewhere holds her (population.visiting).
func _idle_ok(id: String, card: Dictionary) -> bool:
	var visiting: Variant = population.get("visiting")
	if visiting is Dictionary and (visiting as Dictionary).has(id): return false
	var running: RefCounted = card.get("action")
	if running == null: return true
	if card.index >= card.steps.size() or str(card.steps[card.index].get("handler", "")) not in IDLE_STAYS: return false
	return str(running.get("_phase")) == "stay"

## Rolled once per step: true when she stays with her friends for now (the step waits 45 game
## minutes, up to its deadline).
func _sidetracked(id: String, card: Dictionary, step: Dictionary) -> bool:
	if card.sidetracked: return false
	card.sidetracked = true
	var roll := float(absi(hash("%s:%d:%d:side" % [id, card.day, card.index])) % 1000) / 1000.0
	if roll < float(PLANNER.tables().get("day", {}).get("sidetrack_chance", 0.35)):
		step.start = minf(float(step.start) + 0.75, float(step.until))
		return true
	return false

## Free for a plan step: nopony holds her, no player/AI command, not asleep, not flying on
## another errand; the living world's own outings and wandering may be interrupted.
func _free(actor: Node3D, nav: Node) -> bool:
	if actor.get("_held") or (actor.get("hoof_hold") != null and actor.hoof_hold.active()): return false
	if actor.get("flight") != null and actor.flight.active(): return false
	if actor.get("sleeping"): return false
	if actor.has_method("action_interruption_reason") and not str(actor.action_interruption_reason()).is_empty(): return false
	var owner := str(nav.command_owner)
	return owner.is_empty() or owner.begins_with("life:") or owner.begins_with("social:")

# --- Unloaded residents -------------------------------------------------------------------------

func _step_essence(id: String, card: Dictionary, hours: float) -> void:
	var resident := ESSENCE.record(population, id)
	if resident.is_empty(): return
	if not card.essence.is_empty():
		# Bedtime took her (NightRest put her essence to bed): the step ends there.
		if resident.get("asleep", false):
			card.essence = {}
			card.index += 1
			_set_busy(id, false)
			return
		if _essence_tick(id, resident, card.essence) != "running":
			card.essence = {}
			card.index += 1
			card.sidetracked = false
			_set_busy(id, false)
		return
	if card.index >= card.steps.size(): return
	var step: Dictionary = card.steps[card.index]
	if hours > float(step.until):
		card.index += 1
		return
	if hours < float(step.start) or resident.get("asleep", false) or resident.get("paused", false): return
	var outing: Dictionary = life().core.state.activities.get(resident.activity, {}) if life() != null else {}
	if outing.get("members", []).size() > 1 and _sidetracked(id, card, step): return
	var run := _essence_run(id, resident, step)
	if run.is_empty() or (str(step.handler) != "joyride" and not _in_home_town(id, run.to)):
		card.index += 1   # nowhere known to go (its zone was never loaded), or out of her town
		return
	ESSENCE.leave_outing(population, id, "Off to " + _text(step))
	card.essence = run
	_set_busy(id, true)
	resident.last_reason = "Today's plan: " + _text(step)

## Where the step takes her essence and for how long: {"phase", "to", "host", "speed", "stay"}.
func _essence_run(id: String, resident: Dictionary, step: Dictionary) -> Dictionary:
	var here := ESSENCE.position(resident)
	var wings: bool = _traits(id, null).wings
	var run := {"phase": "travel", "host": "", "stay": ACTION.new().duration(float(step.minutes)), "left": 0.0}
	match str(step.handler):
		"joyride":
			run.to = here   # off flying loops somewhere nopony is looking
		"visit":
			run.host = str(step.target)
			run.to = _pony_position(run.host)
		_:
			run.to = _place(id, str(step.target))
	if not (run.to as Vector3).is_finite(): return {}
	var far := Vector2(run.to.x - here.x, run.to.z - here.z).length() > 120.0 or absf(run.to.y - here.y) > 15.0
	run.speed = ESSENCE.FLY_SPEED if wings and far else ESSENCE.WALK_SPEED
	return run

func _essence_tick(id: String, resident: Dictionary, run: Dictionary) -> String:
	var visiting := not str(run.host).is_empty()
	if visiting:
		var there := _pony_position(str(run.host))
		if not there.is_finite(): return "failed"   # she has gone somewhere nopony can follow
		run.to = there
	match run.phase:
		"travel":
			var goal: Vector3 = _beside(resident, run.to) if visiting else run.to
			if ESSENCE.walk(resident, goal, float(run.speed), CHECK):
				run.phase = "stay"
				run.left = float(run.stay)
				if visiting and life() != null: life().core.note_company([id, str(run.host)])
		"stay":
			# Keep her friend company when she wanders about.
			if visiting: ESSENCE.walk(resident, _beside(resident, run.to), ESSENCE.WALK_SPEED, CHECK)
			run.left = float(run.left) - CHECK
			if float(run.left) <= 0.0: return "done"
	return "running"

## A spot 1.6 m from the pony she is visiting, on her own side.
static func _beside(resident: Dictionary, host_at: Vector3) -> Vector3:
	var here := ESSENCE.position(resident)
	var away := Vector3(here.x - host_at.x, 0.0, here.z - host_at.z)
	away = away.normalized() if away.length() > .1 else Vector3.FORWARD
	return host_at + away * 1.6

## Another resident's position: her body when loaded, else her essence.
func _pony_position(id: String) -> Vector3:
	var actor: Node3D = population.live.get(id, {}).get("actor")
	if is_instance_valid(actor) and actor.is_inside_tree(): return actor.global_position
	return ESSENCE.position(ESSENCE.record(population, id))

## The step's places lie in or near her home region: the tables name Ponyville's places, and a
## Canterlot or Appleloosa resident does not trek across Equestria for a hay dog.
func _in_home_town(id: String, at: Vector3) -> bool:
	var region_id: String = population.residence_region(id) if population.has_method("residence_region") else str(population.config.assignments.get(id, ""))
	var region := WorldLayout.region(region_id)
	if region.is_empty() or not at.is_finite(): return false
	return WorldLayout.footprint(region).grow(300.0).has_point(Vector2(at.x, at.z))

## Where the step leads (her own spot for a joyride), for the home-town check.
func _step_point(id: String, step: Dictionary) -> Vector3:
	match str(step.handler):
		"joyride": return _pony_position(id)
		"visit": return _pony_position(str(step.target))
	return _place(id, str(step.target))

## A table target as a point, with or without its zone loaded (remembered from when it was).
func _place(id: String, target: String) -> Vector3:
	if target.begins_with("spot:"):
		var record := ACTION.SPOTS.resolve(population, id, target)
		return record.get("approach", Vector3.INF)
	if target == "home": return ESSENCE.home(population, id)
	var at := ACTION.PLACES.resolve(get_tree(), target)
	if at.is_finite():
		ESSENCE.remember(population, target, at)
		return at
	return ESSENCE.known(population, target)

## She streamed in mid-step: her body picks the step up for the time that is left.
func _essence_to_body(id: String, card: Dictionary) -> void:
	var run: Dictionary = card.essence
	card.essence = {}
	_set_busy(id, false)
	if card.index >= card.steps.size(): return
	var left: float = float(run.left) if run.phase == "stay" else float(run.stay)
	var step: Dictionary = card.steps[card.index]
	step.minutes = maxf(1.0, left / (ACTION.new().duration(60.0) / 60.0))

## Her body streamed out mid-step: the essence carries on to the same place for the time left.
func _body_to_essence(id: String, card: Dictionary) -> void:
	var action: RefCounted = card.action
	var step: Dictionary = card.steps[card.index] if card.index < card.steps.size() else {}
	action.stop(card.ctx)
	_cancel_step_state(card.ctx)
	card.action = null
	card.ctx = {}
	var resident := ESSENCE.record(population, id)
	if step.is_empty() or resident.is_empty(): _set_busy(id, false); return
	var run := _essence_run(id, resident, step)
	if run.is_empty():
		card.index += 1
		_set_busy(id, false)
		return
	if str(action.get("_phase")) == "stay":
		run.phase = "stay"
		run.left = maxf(CHECK, float(run.stay) - float(action.seconds))
	card.essence = run
	_set_busy(id, true)

func _handler(name: String) -> RefCounted:
	if not _handlers.has(name):
		var path := ACTION_DIR + name + ".gd"
		_handlers[name] = load(path) if ResourceLoader.exists(path) else null
	var script: Script = _handlers[name]
	return script.new() if script != null else null

func _text(step: Dictionary) -> String:
	return PLANNER.describe(step, func(t): return ACTION.label(get_tree(), str(t)))

## A finished step goes into the story journal (world_context -> story_memory): she and the
## ponies within 15 m saw it, so it is something to talk about later.
func _remember(id: String, actor: Node3D, step: Dictionary) -> void:
	var context: Node = get_parent().get("world_context") if get_parent() != null else null
	if context == null or not is_instance_valid(actor): return
	var witnesses: Array = [id]
	for other: String in population.live:
		var body: Node3D = population.live[other].get("actor")
		if other != id and is_instance_valid(body) and body.is_inside_tree() and not body.is_queued_for_deletion() and body.global_position.distance_squared_to(actor.global_position) < 225.0:
			witnesses.append(other)
	var who := id.replace("_", " ").capitalize()
	context.record("day", "%s finished: %s." % [who, _text(step)], witnesses, [id])

## Her plan for talk: the whole day, and what she is on now / up to next.
func _publish(id: String, actor: Node3D, card: Dictionary) -> void:
	var lines := PackedStringArray()
	for i in card.steps.size():
		var step: Dictionary = card.steps[i]
		var mark := "done" if i < card.index else ("now" if i == card.index and card.action != null else "later")
		lines.append("%s (%s, around %s)" % [_text(step), mark, _clock(float(step.start))])
	actor.set_meta("day_plan", "; ".join(lines))
	card.shown_on = actor

static func _clock(h: float) -> String:
	var hh := int(floor(h)) % 24
	return "%d:%02d" % [hh, int((h - floor(h)) * 60.0)]

## Debug: one resident's card (playtest bridge).
func debug_resident(id: String) -> Dictionary:
	var card: Dictionary = cards.get(id, {})
	if card.is_empty(): return {}
	var steps: Array = []
	for step: Dictionary in card.steps: steps.append({"text": _text(step), "start": step.start, "until": step.until})
	var essence := {}
	if not card.essence.is_empty():
		essence = {"phase": card.essence.phase, "to": card.essence.to, "left": card.essence.left,
			"at": ESSENCE.position(ESSENCE.record(population, id))}
	return {"day": card.day, "index": card.index, "running": card.action != null, "essence": essence, "steps": steps}

func _exit_tree() -> void:
	chats.clear()
