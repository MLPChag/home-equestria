extends Node
## Anon sleeps (dev 2026-09-29: "sleep mechanic", "sleeping in other ponys beds").
## Lying on any bed or couch, hold A (VR) or Space (desktop) for SLEEP_HOLD seconds: the eyes grow
## heavy and he picks when to wake (world/life/wake_picker.gd), then the screen fades out and back
## in within five seconds.
## Residents' nights run on (night_rest.gd
## wakes them properly after a clock jump), and the game autosaves on waking.
## A bed in somepony else's house is fine; the household hears about it (a world event they
## remember), and a partner in that house simply joins him (the existing bed cuddle).
## faint(): too much cider knocks him out; he wakes at 07:00 in his own bed (the arrival story's
## house), else the Golden Oak guest bed.
## At night, holding Space/A in the picker asks for Luna's dream (world/life/luna_dream.gd) before
## the morning; dreams never come uninvited.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const PICKER := preload("res://world/life/wake_picker.gd")
const COVER := preload("res://world/ui/sleep_cover.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
const SLEEP_HOLD := 1.5
const FAINT_WAKE := 7.0
const SLEEP_HOURS := 9.0
const TRANSITION_SECONDS := 5.0
const VISITOR_PREPARE_MSEC := 1700   # hidden loading runs during the two-second fade
var game: Node
var sleeping := false
## The wake picker is open (before the night begins).
var picking := false
var _shared_body: Node
var _sleep_body: Node
var _sleep_cover: Node
var _was_locked := false
var _sleep_serial := 0
var _visitors: Node

func setup(host: Node) -> void:
	game = host
	add_to_group("player_sleep")

## SLEEP_HOURS later, including day rollover (dev 2026-10-20: "sleep needs to be like 9 hours").
func target_after(day: int, hours: float) -> Array:
	return _after_hours(day, hours, SLEEP_HOURS)

func _after_hours(day: int, hours: float, duration: float) -> Array:
	var later := hours + duration
	return [day + floori(later / 24.0), fposmod(later, 24.0)]

## Held A / Space while lying down (xr_grounded_body.gd, desktop_player.gd). Never inside a Luna
## dream: that dream is already this night's sleep. (The arrival story's old "overnight" wake at
## 08:00 is gone: that stage is never entered any more, so the guest bed picks like any other.)
func sleep() -> void:
	if sleeping or picking or game == null: return
	var dream: Node = get_tree().get_first_node_in_group("luna_dream")
	if dream != null and bool(dream.get("active")): return
	var body: Node = game.player.get_node("Body") if game.xr_active else game.player
	var cover: Node = COVER.new(); cover.name = "SleepCover"; game.add_child(cover); cover.setup(game)
	var picker: Node = PICKER.new(); picker.name = "WakePicker"; add_child(picker)
	picking = true
	var was_locked := bool(body.get("controls_locked"))
	if "controls_locked" in body: body.controls_locked = true
	body.set_meta("sleep_picking", true)
	var choice: Dictionary = await picker.pick(game, cover)
	picking = false
	if is_instance_valid(picker): picker.queue_free()
	if is_instance_valid(body):
		body.remove_meta("sleep_picking")
		if "controls_locked" in body: body.controls_locked = was_locked
	if choice.is_empty() or not is_instance_valid(body) or not is_inside_tree():
		if is_instance_valid(cover):
			await cover.open_eyes(0.4)
			if is_instance_valid(cover): cover.queue_free()
		return
	await _pass_night(choice.target, "", true, bool(choice.luna), cover)

## Sleep without the picker, as if `hours` had been chosen (scripts, tests and the world smoke; the
## player always gets the picker through sleep()).
func sleep_for(hours := SLEEP_HOURS, luna := false) -> void:
	if sleeping or picking or game == null: return
	var dream: Node = get_tree().get_first_node_in_group("luna_dream")
	if dream != null and bool(dream.get("active")): return
	var clock := get_node_or_null("/root/TimeOfDay")
	await _pass_night(_after_hours(int(clock.day), float(clock.hours), hours), "", true, luna)

## Too much cider (world/life/player_needs.gd): wake at home in bed at 07:00.
func faint(message: String) -> void:
	if sleeping or game == null: return
	var clock := get_node_or_null("/root/TimeOfDay")
	var day := int(clock.day) + (1 if float(clock.hours) >= FAINT_WAKE else 0)
	var body: Node3D = game.player.get_node("Body") if game.xr_active else game.player
	if body.has_method("stand_up") and body.get("seat") != null: body.stand_up()
	var bed := _home_bed()
	if bed != null and not is_instance_valid(body.get("seat")): _place_beside(bed)
	await _pass_night([day, FAINT_WAKE], message, false)

func _pass_night(target: Array, message: String, in_bed: bool, luna := false, cover: Node = null) -> void:
	var transition_began := Time.get_ticks_msec()
	sleeping = true
	_sleep_serial += 1
	var serial := _sleep_serial
	var context: Node = game.get("world_context")
	var epoch: int = int(context.get("epoch")) if context != null else -1
	game.player_sleeping = true
	if not is_instance_valid(cover):
		cover = COVER.new(); cover.name = "SleepCover"; game.add_child(cover); cover.setup(game)
	cover.hide_picker()
	_sleep_cover = cover
	cover.show_text(message)
	var body: Node = game.player.get_node("Body") if game.xr_active else game.player
	_sleep_body = body
	_was_locked = bool(body.get("controls_locked"))
	if in_bed and body.get_meta("couch_sleeping", false):
		_shared_body = body
		body.set_meta("shared_rest_sleeping", true)
	if in_bed and body is Node3D:
		preload("res://world/audio/interaction_sounds.gd").play_at(body, "prop_blanket")
	if "controls_locked" in body: body.controls_locked = true
	var clock := get_node_or_null("/root/TimeOfDay")
	var before := float(clock.day) * 24.0 + float(clock.hours)
	var visit_plan := {}
	var people: Node = game.get("population")
	_visitors = people.get("overnight_visitors") if is_instance_valid(people) else null
	if in_bed and is_instance_valid(_visitors):
		visit_plan = _visitors.plan(int(clock.day), int(target[0]))
		_visitors.prepare(visit_plan, Time.get_ticks_msec() + VISITOR_PREPARE_MSEC)
	await cover.close_eyes()
	if not _sleep_current(context, epoch, serial):
		_end_sleep(serial)
		return
	if in_bed: _note_bed()
	var dream: Node = get_tree().get_first_node_in_group("luna_dream")
	if in_bed and dream != null and dream.requested(luna):
		cover = await dream.visit(cover)
		if serial == _sleep_serial: _sleep_cover = cover
		# Loading a checkpoint may detach this world while the dream awaits a frame.
		if not _sleep_current(context, epoch, serial) or not is_instance_valid(cover):
			if serial != _sleep_serial and is_instance_valid(cover): cover.queue_free()
			_end_sleep(serial)
			return
		# An interactive dream has its own duration; its final fade remains gradual.
		transition_began = Time.get_ticks_msec() - int(COVER.FADE_OUT_SECONDS * 1000.0)
	clock.day = int(target[0]); clock.hours = float(target[1])
	var slept := float(clock.day) * 24.0 + float(clock.hours) - before
	var needs: Node = get_tree().get_first_node_in_group("player_needs")
	if needs != null:
		needs.pass_time(maxf(0.0, slept))
		if not in_bed: needs.recover_from_faint()
	if not visit_plan.is_empty() and is_instance_valid(_visitors):
		await _visitors.commit(visit_plan, cover)
	# Ordinary bed sleep never moves the streaming anchor. Fainting can move to a
	# distant house, so retain its required safety barrier rather than reveal unloaded ground.
	if not in_bed: await ZoneManager.wait_until_idle()
	if not _sleep_current(context, epoch, serial):
		_end_sleep(serial)
		return
	_clear_shared_sleep()
	var remaining := TRANSITION_SECONDS - float(Time.get_ticks_msec() - transition_began) * .001
	await cover.open_eyes(clampf(remaining, .15, COVER.FADE_IN_SECONDS))
	if not _sleep_current(context, epoch, serial):
		_end_sleep(serial)
		return
	_end_sleep(serial)
	print("[sleep] slept %.1f h, woke day %d %.2f" % [slept, int(clock.day), float(clock.hours)])
	if is_instance_valid(game.get("saves")) and game.saves.ready_to_save:
		game.saves.save_to(game.saves.directory.path_join("autosave.json"), "Autosave")

func _sleep_current(context: Node, epoch: int, serial: int) -> bool:
	return serial == _sleep_serial and sleeping and not SHUTDOWN.active and is_inside_tree() and not is_queued_for_deletion() and is_instance_valid(game) and is_instance_valid(_sleep_body) and (epoch < 0 or (is_instance_valid(context) and int(context.get("epoch")) == epoch))

## One owner releases its input/cover state on wake, cancellation and tree exit.
## A detached coroutine must never release a later sleep after reattachment.
func _end_sleep(serial: int) -> void:
	if serial != _sleep_serial: return
	if is_instance_valid(_visitors): _visitors.cancel_preparation()
	_visitors = null
	_clear_shared_sleep()
	if is_instance_valid(_sleep_cover): _sleep_cover.queue_free()
	_sleep_cover = null
	if is_instance_valid(_sleep_body) and "controls_locked" in _sleep_body:
		_sleep_body.controls_locked = _was_locked
	_sleep_body = null
	if sleeping and is_instance_valid(game): game.player_sleeping = false
	sleeping = false
	_sleep_serial += 1

## Sleeping in another household's bed: they remember it.
func _note_bed() -> void:
	var camera: Camera3D = game._find_camera(game.player)
	var house: Node3D = HOUSE.at(get_tree(), camera.global_position)
	if house == null or not is_instance_valid(game.get("population")): return
	var arrival: Node = game.get("arrival")
	if arrival != null and str(arrival.data.get("home", "")) == house.place_id(): return
	var residents: Array = game.population.residents_of(house.place_id())
	if residents.is_empty() or game.world_context == null: return
	game.world_context.record("home", "Anon slept the night in a bed in your house.", residents, residents)

## His own bed: the arrival story's house, else the Golden Oak guest bed.
func _home_bed() -> Node3D:
	var arrival: Node = game.get("arrival")
	var place: String = str(arrival.data.get("home", "")) if arrival != null else ""
	for node: Node in get_tree().get_nodes_in_group("house_interiors"):
		if place != "" and node.place_id() == place and is_instance_valid(node.get("bed")): return node.bed
	for node: Node in get_tree().get_nodes_in_group("house_interiors"):
		# Dedicated interiors own their furniture through an adapter. Looking for
		# any exposed guest dictionary selected Rainbow's cloud home instead.
		if node.place_id() == "house:golden_oak_library" and node.has_method("ensure_bed"):
			return node.ensure_bed("guest")
	return null

func _place_beside(bed: Node3D) -> void:
	var body: Node3D = game.player.get_node("Body") if game.xr_active else game.player
	var camera: Camera3D = game._find_camera(game.player)
	var feet: Vector3 = bed.global_position + bed.global_basis.x.normalized() * 1.0 + Vector3.UP * 0.1
	var eye_feet := Vector3(camera.global_position.x, body.global_position.y, camera.global_position.z)
	body.global_position += feet - eye_feet
	if "velocity" in body: body.velocity = Vector3.ZERO
	if is_instance_valid(WorldTerrain.instance): WorldTerrain.instance.focus(feet)

func _clear_shared_sleep() -> void:
	if is_instance_valid(_shared_body) and _shared_body.has_meta("shared_rest_sleeping"):
		_shared_body.remove_meta("shared_rest_sleeping")
		# Save only the waking state; the company's next physics tick would be too late.
		var seat_value: Variant = _shared_body.get("seat") if "seat" in _shared_body else null
		var seat: Node = seat_value if is_instance_valid(seat_value) else null
		var surface_value: Variant = seat.get_meta("couch") if seat != null and seat.has_meta("couch") else null
		var surface: Node = surface_value if is_instance_valid(surface_value) else null
		var companion: Node = surface.partner(seat) if is_instance_valid(surface) and surface.has_method("partner") else null
		var company: Node = companion.get_node_or_null("SharedNapCompany") if is_instance_valid(companion) else null
		if company != null and company.partner == _shared_body: company.player_woke()
	_shared_body = null

func _exit_tree() -> void:
	_end_sleep(_sleep_serial)
