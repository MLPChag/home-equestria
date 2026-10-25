extends RefCounted
## Hoofsteps for clip-tier (NEAR) ponies, on the baked footfalls (docs/HOOFSTEPS_2026_10_22.md).
##
## tools/audio/bake_hoof_plants.gd measures, in every solver-baked gait clip, the normalised clip time at
## which each hoof plants (sole at its lowest and still in the world) and lifts, with the sole's
## skeleton-space position at both. A NEAR pony compares her clip's previous and current
## normalised time against those phases every physics step and emits the pony's own
## `hoof_planted(world_position)` for each one crossed, at that sole carried through her skeleton,
## so the ambience plays it exactly like a HERO plant. Playing backwards (backing up), a lift is
## what touches down. Only while the listening camera is within AUDIBLE_DISTANCE (checked on the
## 20 Hz logic beat); otherwise a step costs one bool test. No allocation per step.

const PATH := "res://world/characters/locomotion/hoof_plants.json"
const VERSION := 1
const BAKED_GAITS := preload("res://world/characters/locomotion/baked_gaits.gd")
const PLAYER_VIEW := preload("res://world/player_view.gd")
## env_hoofstep carries 18 m; a little margin for a pony walking toward the listener.
const AUDIBLE_DISTANCE := 20.0
## HERO (full solver): the contact model loads a hoof (weight past 0.7) one to three ticks before
## the shown hoof gets there, because the IK target eases onto the ground over ~20-45 ms
## (contact_response). tools/audio/test_hoof_plant_timing.gd measured those plants 20-45 ms
## before the visible touchdown in the trot and gallop, up to 133 ms in the walk. The plant now
## waits until the IK target is within HERO_HEIGHT of the ground and slower than HERO_SPEED plus
## HERO_SPEED_SHARE of the body's speed (a fast gait's loaded hoof still skids a little under its
## lock limit), or HERO_WAIT at most. A hoof that lifts again first sounds as it lifts, so a
## short gallop stance is never silent.
const HERO_HEIGHT := 0.006
const HERO_SPEED := 0.35
const HERO_SPEED_SHARE := 0.4
const HERO_WAIT := 0.15

## layout key -> {&"baked/<gait>": [plants, lifts, plant soles, lift soles]}, built once per run.
static var _tables := {}
static var _loaded := false

var audible := false
var _table: Dictionary = {}
var _bound: AnimationLibrary
var _clip := &""
var _plants := PackedFloat32Array()
var _lifts := PackedFloat32Array()
var _plant_soles := PackedVector3Array()
var _lift_soles := PackedVector3Array()
var _previous := -1.0
var _pending := PackedByteArray([0, 0, 0, 0])
var _pending_at := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
var _waited := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _last_target := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
## HERO plants sounded by HERO_WAIT or by a lift rather than by the hoof arriving (tests read it).
var hero_forced := 0


## Footfalls of one baked layout (empty when the bake is missing or stale).
static func table(key: String) -> Dictionary:
	if not _loaded:
		_loaded = true
		_load()
	return _tables.get(key, {})


static func _load() -> void:
	if not FileAccess.file_exists(PATH):
		push_warning("[hoofsteps] %s missing: clip-tier ponies stay silent; bake with tools/audio/bake_hoof_plants.gd" % PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not parsed is Dictionary or int((parsed as Dictionary).get("version", 0)) != VERSION \
			or int((parsed as Dictionary).get("baked_version", 0)) != BAKED_GAITS.VERSION:
		push_warning("[hoofsteps] %s is stale or unreadable: rebake with tools/audio/bake_hoof_plants.gd" % PATH)
		return
	var layouts: Dictionary = (parsed as Dictionary).get("layouts", {})
	for key: String in layouts:
		var gaits: Dictionary = layouts[key]
		var clips := {}
		for gait: String in gaits:
			var plants := PackedFloat32Array()
			var lifts := PackedFloat32Array()
			var plant_soles := PackedVector3Array()
			var lift_soles := PackedVector3Array()
			var events: Array = (gaits[gait] as Dictionary).get("events", [])
			for event: Array in events:
				if event.size() < 9: continue
				plants.append(float(event[1]))
				lifts.append(float(event[2]))
				plant_soles.append(Vector3(float(event[3]), float(event[4]), float(event[5])))
				lift_soles.append(Vector3(float(event[6]), float(event[7]), float(event[8])))
			clips[StringName(String(BAKED_GAITS.LIBRARY) + "/" + gait)] = [plants, lifts, plant_soles, lift_soles]
		_tables[key] = clips


## On the clip tiers' logic beat: whether this pony is close enough to the listener to report.
func logic(pony: Node3D, near: bool) -> void:
	var library: AnimationLibrary = pony._baked
	if library != _bound:
		_bound = library
		_table = table(String(library.get_meta(&"layout_key", ""))) if library != null else {}
		_clip = &""
	var was := audible
	audible = false
	if near and not _table.is_empty():
		var camera: Camera3D = PLAYER_VIEW.camera(pony)
		audible = camera != null and camera.global_position.distance_squared_to(pony.global_position) <= AUDIBLE_DISTANCE * AUDIBLE_DISTANCE
	if audible and not was:
		_previous = -1.0


## After the clip advanced this physics step.
func step(pony: Node3D, animation: AnimationPlayer, skeleton: Skeleton3D) -> void:
	if not audible:
		return
	var current := animation.current_animation
	if current != _clip:
		# A gait change keeps the stride's normalised phase (pony_locomotion.gd _clip_logic), so
		# the previous phase carries over; the stand and the hand-off have no footfalls.
		_clip = current
		var entry: Array = _table.get(current, [])
		if entry.is_empty():
			_plants = PackedFloat32Array()
			_previous = -1.0
			return
		_plants = entry[0]
		_lifts = entry[1]
		_plant_soles = entry[2]
		_lift_soles = entry[3]
	if _plants.is_empty():
		return
	var length := animation.current_animation_length
	if length <= 0.0:
		return
	var now := fposmod(animation.current_animation_position / length, 1.0)
	var before := _previous
	_previous = now
	if before < 0.0:
		return
	var forward := animation.get_playing_speed() >= 0.0
	var from := before if forward else now
	var to := now if forward else before
	var span := fposmod(to - from, 1.0)
	# Nothing moved, or a seek (more than half a cycle in one step): no footfall.
	if span <= 0.0 or span > 0.5:
		return
	var events := _plants if forward else _lifts
	for i in events.size():
		if fposmod(events[i] - from, 1.0) <= span and fposmod(events[i] - from, 1.0) > 0.0:
			pony.hoof_planted.emit(skeleton.global_transform * (_plant_soles[i] if forward else _lift_soles[i]))


## HERO: the contact model planted hoof `i` (its probe hit `at`); sound it once the shown hoof is down.
func plant(i: int, at: Vector3) -> void:
	if i < 0 or i >= 4:
		return
	_pending[i] = 1
	_pending_at[i] = at
	_waited[i] = 0.0


## A moving support carried the pony and her feet (pony_locomotion.gd _follow_moving_support):
## carry the waiting plants too, so they sound where the hoof now is and still see it arrive.
func carry(motion: Transform3D) -> void:
	for i in 4:
		_pending_at[i] = motion * _pending_at[i]
		_last_target[i] = motion * _last_target[i]


## The native contact pass reports positions only: each goes to the planted foot locked nearest it.
## Known gap: hoof_contacts.cpp records a plant before a gait switch can unplant the same foot,
## so such a plant goes to another planted hoof; returning hoof indices needs a native rebuild.
func plant_native(pony: Node3D, positions: PackedVector3Array) -> void:
	var feet: Array = pony.feet
	for at in positions:
		var hoof := -1
		var best := INF
		for i in feet.size():
			var foot: Dictionary = feet[i]
			if not bool(foot.planted): continue
			var lock: Vector3 = foot.lock
			var d := lock.distance_squared_to(at)
			if d < best:
				best = d
				hoof = i
		plant(hoof, at)


## HERO, after every contact pass: emit the waiting plants whose shown hoof has arrived.
func hero(pony: Node3D, delta: float) -> void:
	var feet: Array = pony.feet
	if feet.size() != 4:
		return
	var scale: float = pony.body_scale
	var drift: float = (HERO_SPEED * scale + HERO_SPEED_SHARE * float(pony.actual_speed)) * delta
	for i in 4:
		var foot: Dictionary = feet[i]
		var target: Vector3 = foot.target
		if _pending[i]:
			_waited[i] += delta
			var landing: Vector3 = foot.landing
			var arrived := target.y - landing.y <= HERO_HEIGHT * scale and delta > 0.0 \
				and target.distance_to(_last_target[i]) <= drift
			if arrived or not bool(foot.planted) or _waited[i] >= HERO_WAIT:
				if not arrived: hero_forced += 1
				_pending[i] = 0
				pony.hoof_planted.emit(_pending_at[i])
		_last_target[i] = target
