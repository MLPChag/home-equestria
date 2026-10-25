extends Node
## World-local activity outcomes. Called only by the existing day tick/contact beats.
## No persistence: a newly loaded Game starts fresh, including the same saved world.
signal changed(spot_id: String, state: Dictionary)
signal touched(spot_id: String, amount: float)
const SPOTS := preload("res://world/props/ponyville_kit/kit_spots.gd")
const META := &"kit_activity_state"
const GARDEN := ["rose_bed", "flowering_shrub", "bush_round_small", "bush_round_medium", "bush_cluster_large"]
var _world: Node
var _day := -2147483648
var _serial := 0
var _leases: Dictionary = {}
var _spots: Dictionary = {}
var _outcomes: Dictionary = {}
var _water: Dictionary = {}

static func install(world: Node) -> Node:
	if world.has_meta(META):
		var existing: Variant = world.get_meta(META)
		if is_instance_valid(existing): return existing
	var state: Node = load("res://world/props/ponyville_kit/kit_state.gd").new()
	state.name = "KitActivityState"
	state._world = world
	world.add_child(state)
	world.set_meta(META, state)
	return state

## Ancestry, never a global first-in-group lookup across two overlapping worlds.
static func for_node(node: Node) -> Node:
	while is_instance_valid(node):
		if node.has_meta(META):
			var state: Variant = node.get_meta(META)
			if is_instance_valid(state) and not state.is_queued_for_deletion(): return state
		node = node.get_parent()
	return null

## Runner calls once each existing 0.5 s pass. No iteration unless its day changes.
## Use the runner's schedule day (before 05:00 belongs to yesterday, including -1).
func advance_day(day: int) -> void:
	if day == _day: return
	for lease: Dictionary in _leases.values(): touched.emit(str(lease.id), 0.0)
	_day = day
	_leases.clear()
	_water.clear()
	_outcomes.clear()
	for id: String in _spots:
		var prior: Dictionary = _spots[id]
		_spots[id] = _fresh(str(prior.kind))
		changed.emit(id, snapshot(id))

func _fresh(kind: String) -> Dictionary:
	return {"kind": kind, "day": _day, "mail_pending": kind == "mailbox",
		"watered": false, "source_well": "", "split_count": 0}

func snapshot(id: String) -> Dictionary:
	if not _spots.has(id):
		var spot: Dictionary = SPOTS.by_id(id)
		if spot.is_empty(): return {}
		_spots[id] = _fresh(str(spot.kind))
	return (_spots[id] as Dictionary).duplicate(true)

## Handler identity is weak: abandoned actions cannot hold a prop forever.
## Caller acquires before taking day navigation ownership, then owns() must pass
## before any work beat. The same action can reacquire its same spot idempotently.
func acquire(id: String, actor: Node3D, handler: RefCounted, day: int, step_key: String) -> int:
	if day != _day or step_key.is_empty() or not is_instance_valid(actor) or not actor.is_inside_tree(): return 0
	if not is_instance_valid(handler) or for_node(actor) != self or snapshot(id).is_empty(): return 0
	for token: int in _leases.keys():
		var old: Dictionary = _leases[token]
		if str(old.id) != id: continue
		if not _alive(old):
			_release(token, true)
			continue
		return token if old.handler.get_ref() == handler and old.actor.get_ref() == actor and str(old.step) == step_key else 0
	_serial += 1
	_leases[_serial] = {"id": id, "actor": weakref(actor), "handler": weakref(handler),
		"day": day, "step": step_key, "collected": false}
	return _serial

func _alive(lease: Dictionary) -> bool:
	var actor: Variant = lease.actor.get_ref()
	return int(lease.day) == _day and is_instance_valid(lease.handler.get_ref()) and is_instance_valid(actor) and actor.is_inside_tree() and not actor.is_queued_for_deletion()

func owns(token: int) -> bool:
	var lease: Dictionary = _leases.get(token, {})
	if lease.is_empty() or not _alive(lease): return false
	var actor: Node = lease.actor.get_ref()
	var nav: Node = actor.get_node_or_null("Navigator")
	return nav != null and str(nav.command_owner) == "day:" + str(lease.step).get_slice(":", 0)

func release(token: int) -> void:
	_release(token, false)

func _release(token: int, cancelled: bool) -> void:
	var lease: Dictionary = _leases.get(token, {})
	if lease.is_empty(): return
	touched.emit(str(lease.id), 0.0)
	if bool(lease.collected) and int(lease.day) == _day:
		# Undelivered letter returns to its mailbox on cancellation/removal.
		var state: Dictionary = _spots[lease.id]
		state.mail_pending = true
		changed.emit(str(lease.id), state.duplicate(true))
	if cancelled: _water.erase(str(lease.step))
	_leases.erase(token)

## Existing day-action beats drive a tiny plant response; no animation poll/timer.
func touch(token: int, amount: float) -> bool:
	if not owns(token) or not is_finite(amount): return false
	var lease: Dictionary = _leases[token]
	if str(_spots[lease.id].kind) not in GARDEN: return false
	touched.emit(str(lease.id), clampf(amount, -1.0, 1.0))
	return true

func cancel_step(step_key: String) -> void:
	_water.erase(step_key)
	for token: int in _leases.keys():
		if str(_leases[token].step) == step_key: _release(token, true)

func _commit(token: int, event: String) -> Dictionary:
	if not owns(token): return {}
	var lease: Dictionary = _leases[token]
	var key := "%s|%s|%s" % [lease.step, lease.id, event]
	if _outcomes.has(key): return {}
	_outcomes[key] = true
	return lease

func mark_water_drawn(token: int) -> bool:
	if not owns(token) or str(snapshot(str(_leases[token].id)).kind) != "well": return false
	# One transient receipt, not inventory. Redrawing after interrupted carry is
	# legitimate; repeated completion callbacks replace the same receipt.
	var lease: Dictionary = _leases[token]
	_water[str(lease.step)] = str(lease.id)
	return true

func mark_watered(token: int, source_well_id := "") -> bool:
	if not owns(token): return false
	var current: Dictionary = _leases[token]
	var state: Dictionary = _spots[current.id]
	if str(state.kind) not in GARDEN: return false
	if not source_well_id.is_empty() and str(_water.get(str(current.step), "")) != source_well_id: return false
	var lease := _commit(token, "water")
	if lease.is_empty(): return false
	state.watered = true
	state.source_well = source_well_id
	_water.erase(str(lease.step))
	changed.emit(str(lease.id), state.duplicate(true))
	return true

func collect_mail(token: int) -> bool:
	if not owns(token): return false
	var lease: Dictionary = _leases[token]
	var state: Dictionary = _spots[lease.id]
	if str(state.kind) != "mailbox" or not bool(state.mail_pending) or bool(lease.collected): return false
	lease.collected = true
	state.mail_pending = false
	changed.emit(str(lease.id), state.duplicate(true))
	return true

func deliver_mail(token: int) -> bool:
	if not owns(token) or not bool(_leases[token].collected): return false
	var lease := _commit(token, "mail")
	if lease.is_empty(): return false
	lease.collected = false
	return true

func split_log(token: int) -> bool:
	if not owns(token): return false
	var current: Dictionary = _leases[token]
	var state: Dictionary = _spots[current.id]
	if str(state.kind) != "log_pile" or int(state.split_count) >= 1: return false
	var lease := _commit(token, "split")
	if lease.is_empty(): return false
	state.split_count = int(state.split_count) + 1
	changed.emit(str(lease.id), state.duplicate(true))
	return true

func _exit_tree() -> void:
	if is_instance_valid(_world) and _world.has_meta(META) and _world.get_meta(META) == self:
		_world.remove_meta(META)
	_leases.clear()
	_water.clear()
	_outcomes.clear()
	_spots.clear()
