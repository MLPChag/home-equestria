extends Node3D
## Hand-only collision over a mare's whole body, and petting (dev 2026-09-25: "add hand collision
## for every part of a mare's body so I can pet them"; "only my hands collide so I can still grab
## them easily").
##
## Shapes: convex hulls fitted to her own skinned meshes in their bind pose, covering the neck,
## withers, back, barrel and belly, rump, flanks, every leg segment down to the hooves, the folded
## wings on pegasi, the mane and the tail. Each deforming bone gets a hull for
## the coat it dominates, plus a hull per neighbouring bone for the coat they share (so a hull
## follows a bend); neighbouring buckets overlap so the union has no cracks. Each hull is placed
## where linear blend skinning puts its vertices' centroid, rotated by its two main bones. The
## loaded head, eyes, ears and horn also receive fitted hulls; the Snoot retains boop sensing. Fits are cached per identity and built on a worker thread the first
## time a hand comes within FIT_REACH.
##
## Collision: every hull is its own kinematic physics-server body on the face layer (value 4)
## with mask 0, the layer only the physics hands scan (hybrid_boop.arm). Nothing else collides
## with them: not the player's body or head, other ponies, the world or held items. The hands
## stop scanning the pony layer (2), whose upright 0.19 m capsule held them 8-20 cm off her coat
## and kept them from her hooves. The hulls never push her; a hand's push still reaches her through
## apply_body_impulse, as it did on the capsule. One body per hull: moving shapes inside one
## compound body made Jolt rebuild it on every move (4.2 ms per pony per tick).
##
## Grabbing uses controller-space targets; visible and physical hands remain outside the coat.
##
## Cost: two distance checks per pony per physics tick while the hands are far. Within WAKE the
## hulls follow her bones in skeleton_updated (the modified pose); hulls more than NEAR_HULL from
## both hands only every FAR_EVERY ticks.

const CROWD_PROFILE := preload("res://tools/crowd_cpu_profile.gd")
const GESTURE := preload("res://world/characters/hybrid_mare/pet_stroke_gesture.gd")
const LAYER := 4          # hybrid_boop.FACE_LAYER: the physics hands' contact layer
const PONY_LAYER := 2     # her capsule; the hands no longer scan it
## Soft parts (dev 2026-09-28: hitboxes to the skin, like real life). Mane, tail and ear hulls
## stood 4-6 cm off the hair on average and up to 16 cm (tools/measure_contact_fit.gd): hands
## hit air. They no longer collide; hands sink into the hair, and a sense query on this layer
## still reports where she is petted.
const SENSE_LAYER := 1 << 21
## Hands within WAKE * body scale + WAKE_PAD metres of her root wake the hulls.
const WAKE := 1.5
const WAKE_PAD := 1.0
const SLEEP_MARGIN := 0.3
## A hand this far out already starts the (threaded, cached) fit for her identity.
const FIT_REACH := 8.0
const NEAR_HULL := 0.5
const FAR_EVERY := 4
const DIRECTIONS := 96
const MIN_POINTS := 12
const BLEND_MIN_POINTS := 30
const HULL_MARGIN := 0.004
const FRICTION := 0.0     # a stroking hand glides over her coat (dev 2026-09-28: hands caught)
## Petting reaction per region: smile, half-lidded eyes, blush level (belly is shy).
const REACTIONS := {
	"head": Vector3(.7,.5,.35), "neck": Vector3(.8, .55, .45), "mane": Vector3(.75, .5, .4), "withers": Vector3(.85, .6, .45),
	"back": Vector3(.7, .5, .4), "shoulder": Vector3(.65, .45, .4), "chest": Vector3(.6, .4, .5),
	"barrel": Vector3(.55, .35, .4), "belly": Vector3(.35, .15, .9), "rump": Vector3(.4, .2, .65),
	"flank": Vector3(.45, .25, .6), "leg": Vector3(.3, .1, .35), "tail": Vector3(.35, .15, .6),
	"wing": Vector3(.6, .45, .6)}
## Petting sessions: a new one after SESSION_GAP quiet seconds; the conversation director hears
## about at most one every EMIT_COOLDOWN seconds.
const SESSION_GAP := 3.0
const EMIT_COOLDOWN := 20.0
const NOT_TOUCHING := {}   # read-only; the per-tick call used to allocate a fresh {}

static var _fits: Dictionary = {}   # identity key -> Array of fit entries
static var _jobs: Dictionary = {}   # identity key -> {"task": int, "result": Array}

static func discard_pending() -> void:
	for job: Dictionary in _jobs.values():
		WorkerThreadPool.wait_for_task_completion(job.task)
	_jobs.clear()

var mare: Node3D
var active := false
## Off: no hulls and the hands pass through her (tests compare grabs with and without).
var enabled := true
var pets := 0          # petting sessions
var strokes := 0       # qualifying strokes over all hands
var petting := false
var pet_region := ""
var hand_region := {}  # side -> region under the hand while in contact
var _entries: Array = []  # one per hull: see _build_shapes
var _by_rid := {}         # hull body RID -> entry
var _rigs: Array = []     # body, hair, head skeletons
var _key := ""
var _installed_key := ""
var _armed: Dictionary = {}     # hands whose masks were adjusted
var _excepted := {}
var _gestures := {}
var _synced := [-1, -1, -1]
var _rescale_count := [0, 0, 0]
var _pet_quiet := INF
var _last_emit := -INF
var _connected := false
var _callbacks: Array[Callable] = []
## Desktop contextual contact has its own intent; it never feeds the tracked gesture detector.
var _desktop_eye := Vector3.INF
var _desktop_until := 0
var _desktop_pet_until := 0
var _desktop_pet_region := ""
## FAR (PonyCrowd tier 2, 30 m and out) and idle: the physics tick is off. The tier change
## (hybrid_mare.set_sim_tier) and the desktop offer/pet wake it; nothing else can reach her there.
var _parked := false
var _parked_msec := 0


func wake_tick() -> void:
	if _parked:
		_parked = false
		_pet_quiet += (Time.get_ticks_msec() - _parked_msec) / 1000.0   # the quiet time it skipped
		set_physics_process(true)


func _park() -> void:
	_parked = true
	_parked_msec = Time.get_ticks_msec()
	set_physics_process(false)


func desktop_offer(origin: Vector3, end: Vector3) -> Dictionary:
	if not enabled or not origin.is_finite() or not end.is_finite() or mare.is_held(): return {}
	wake_tick()
	_desktop_eye = origin
	_desktop_until = Time.get_ticks_msec() + 250
	_key = _fit_key()
	if _installed_key != _key: _poll_fit()
	if _entries.is_empty(): return {}
	if not active: _set_active(true)
	for rig in _rigs.size():
		if _synced[rig] != Engine.get_physics_frames(): _unprofiled_sync(rig, true)
	# Physical goods (17) and orchard fruit (8) occlude a social target too.
	var query := PhysicsRayQueryParameters3D.create(origin, end, 1 | 8 | (1 << 17) | LAYER | SENSE_LAYER)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty(): return {}
	if is_instance_valid(mare.boop_node) and hit.get("collider") == mare.boop_node.snoot:
		return {"target": mare, "point": hit.position, "normal": hit.normal,
			"region": "head", "collider": mare.boop_node.snoot, "visible_pick": true}
	if not _by_rid.has(hit.rid): return {}
	var entry: Dictionary = _by_rid[hit.rid]
	return {"target": mare, "point": hit.position, "normal": hit.normal,
		"region": _refine(entry, hit.normal), "entry": entry, "collider": self, "visible_pick": true}


func desktop_pet(region: String) -> void:
	if not REACTIONS.has(region): return
	wake_tick()
	_desktop_pet_region = region
	_desktop_pet_until = Time.get_ticks_msec() + 120


func desktop_pet_end() -> void:
	_desktop_pet_until = 0
	_desktop_pet_region = ""


func _desktop_touching() -> Dictionary:
	return {"desktop": _desktop_pet_region} if Time.get_ticks_msec() < _desktop_pet_until else {}


func setup(target: Node3D) -> void:
	mare = target
	name = "TouchBody"
	_key = _fit_key()


## Tests and tools: the fit for her identity, blocking.
func fit_now() -> void:
	if not _fits.has(_key):
		_fits[_key] = _fit(_gather())
	if _entries.is_empty() or _installed_key!=_key: _build_shapes(_fits[_key])


func entries() -> Array:
	return _entries


func is_petting() -> bool:
	return petting


func _fit_key() -> String:
	var identity: Resource = mare.get("identity")
	var model: String = mare.model_scene.resource_path if mare.get("model_scene") != null else ""
	return "%s|%s|%s|%s" % [identity.id if identity != null else "", model, identity.hair_scene if identity != null else "", "open" if _wings_open() else "folded"]

func _wings_open()->bool:
	return mare.flight!=null and mare.flight.wings!=null and mare.flight.wings.opened


func _hands() -> Dictionary:
	var boop: Node = mare.get(&"boop_node")
	return boop._hands if boop != null else {}


func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_physics_process(delta)
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("touch_body", started)


func _unprofiled_physics_process(delta: float) -> void:
	var hands := _hands()
	var desktop_near: bool = Time.get_ticks_msec() < _desktop_until and _desktop_eye.is_finite()
	if hands.is_empty() and not desktop_near and not active and not petting:
		if mare.get(&"sim_tier") == 2: _park()
		return
	var nearest := INF
	if desktop_near: nearest = _desktop_eye.distance_squared_to(mare.global_position)
	for side in hands:
		var hand: Node3D = hands[side]
		if not is_instance_valid(hand): continue
		if not _armed.has(hand.get_instance_id()): _arm(hand)
		nearest = minf(nearest, hand.global_position.distance_squared_to(mare.global_position))
		# Visible hands follow tracking even while the physics hand catches up.
		# Its lag must not hide the hulls that stop that visible palm at the coat.
		var controller:Node3D=mare.boop_node._controllers.get(side) as Node3D
		if is_instance_valid(controller) and (not controller.has_method("get_has_tracking_data") or controller.get_has_tracking_data()):
			nearest=minf(nearest,controller.global_position.distance_squared_to(mare.global_position))
	var scale_factor: Variant = mare.get(&"body_scale")
	var wake: float = WAKE * (1.0 if scale_factor == null else float(scale_factor)) + WAKE_PAD + (SLEEP_MARGIN if active else 0.0)
	if nearest < FIT_REACH * FIT_REACH:
		_key=_fit_key()
		if _installed_key!=_key:_poll_fit()
	# Held, her hulls rest: the carried body moves with the hands every step, so its hulls would
	# only shove the physics hands. She passes through Anon's hands and arms (dev 2026-09-28).
	var want: bool = enabled and not mare.is_held() and nearest < wake * wake and not _entries.is_empty() and mare.get(&"sim_tier") != 2
	if want != active: _set_active(want)
	_report_off(want, nearest)
	if not active:
		if not _excepted.is_empty(): _clear_exceptions()
		_advance_petting(delta, _desktop_touching())
		if not petting and not desktop_near and mare.get(&"sim_tier") == 2: _park()
		return
	# A settled clip-tier rest freezes her skeletons: no skeleton_updated, so read them directly.
	var tick := Engine.get_physics_frames()
	for rig in _rigs.size():
		if _synced[rig] < tick - 1: _unprofiled_sync(rig, true)
	var touching: Dictionary = _update_hands(delta, hands)
	touching.merge(_desktop_touching())
	_advance_petting(delta, touching)


func _arm(hand: Node3D) -> void:
	_armed[hand.get_instance_id()] = true
	if hand is CollisionObject3D:
		var body := hand as CollisionObject3D
		body.collision_mask = (body.collision_mask | LAYER) & ~PONY_LAYER
	if hand is RigidBody3D:
		(hand as RigidBody3D).contact_monitor = true
		(hand as RigidBody3D).max_contacts_reported = maxi((hand as RigidBody3D).max_contacts_reported, 8)


func _set_active(on: bool) -> void:
	active = on
	for e: Dictionary in _entries: PhysicsServer3D.body_set_collision_layer(e.rid, (SENSE_LAYER if _soft(e) else LAYER) if on else 0)
	if _callbacks.is_empty(): _callbacks = [_sync.bind(0), _sync.bind(1), _sync.bind(2)]
	if on and not _connected:
		for rig in _rigs.size():
			if is_instance_valid(_rigs[rig]): _rigs[rig].skeleton_updated.connect(_callbacks[rig])
		_connected = true
		_rescale_count = [0, 0, 0]
		for rig in _rigs.size(): _unprofiled_sync(rig, true)
	elif not on and _connected:
		for rig in _rigs.size():
			if is_instance_valid(_rigs[rig]) and _rigs[rig].skeleton_updated.is_connected(_callbacks[rig]):
				_rigs[rig].skeleton_updated.disconnect(_callbacks[rig])
		_connected = false
	if not on:
		for side in _gestures: _gestures[side].reset()
		hand_region.clear()


func _sync(rig: int) -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_sync(rig, false)
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("touch_body_sync", started)


## Hulls follow the modified pose: called inside each rig's skeleton_updated. A hull's centre
## goes where linear blend skinning takes its vertices' centroid (the bucket's mean weight on up
## to three bones); its rotation is the slerp of its two main bones.
func _unprofiled_sync(rig: int, every: bool) -> void:
	var skeleton: Skeleton3D = _rigs[rig]
	if not is_instance_valid(skeleton): return
	var tick := Engine.get_physics_frames()
	_synced[rig] = tick
	# Proportions (filly neck/head, pony size) change rarely: check the scales once a second.
	_rescale_count[rig] -= 1
	var rescale: bool = _rescale_count[rig] <= 0
	if rescale: _rescale_count[rig] = 60
	var near := PackedVector3Array()
	for side in _hands():
		var hand: Node3D = _hands()[side]
		if is_instance_valid(hand): near.append(hand.global_position)
	var g := skeleton.global_transform
	var poses := {}
	var index := 0
	for e: Dictionary in _entries:
		if e.rig != rig: continue
		index += 1
		if not every and (tick + index) % FAR_EVERY != 0:
			var close := false
			for p in near: close = close or p.distance_squared_to(e.world.origin) < NEAR_HULL * NEAR_HULL
			if not close: continue
		var bones: PackedInt32Array = e.bones
		var fit: Dictionary = e.fit
		var binds: Array = fit.binds
		var anchors: PackedVector3Array = fit.anchors
		var weights: PackedFloat32Array = fit.weights
		var origin := Vector3.ZERO
		var first := Transform3D.IDENTITY
		var second := Transform3D.IDENTITY
		for i in bones.size():
			if not poses.has(bones[i]): poses[bones[i]] = g * skeleton.get_bone_global_pose(bones[i])
			var m: Transform3D = poses[bones[i]] * binds[i]
			origin += (m * anchors[i]) * weights[i]
			if i == 0: first = m
			elif i == 1: second = m
		var rotation: Basis
		var s: Vector3
		var twist: float = fit.twist
		if twist > 0.0:
			rotation = Basis(first.basis.get_rotation_quaternion().slerp(second.basis.get_rotation_quaternion(), twist))
			if rescale: s = first.basis.get_scale().abs().lerp(second.basis.get_scale().abs(), twist)
		else:
			rotation = first.basis.orthonormalized()
			if rescale: s = first.basis.get_scale().abs()
		if rescale and (s - e.scale).length() > 0.01 * s.length(): _rescale(e, s)
		e.world = Transform3D(rotation, origin)
		PhysicsServer3D.body_set_state(e.rid, PhysicsServer3D.BODY_STATE_TRANSFORM, e.world)


func _rescale(e: Dictionary, s: Vector3) -> void:
	e.scale = s
	var points := PackedVector3Array()
	for p: Vector3 in e.fit.points: points.append(p * s)
	(e.shape as ConvexPolygonShape3D).points = points
	e.a = e.fit.a * s
	e.b = e.fit.b * s
	e.r = e.fit.r * (s.x + s.y + s.z) / 3.0


func _poll_fit() -> void:
	if _fits.has(_key):
		_build_shapes(_fits[_key])
		return
	if not _jobs.has(_key):
		var job := {"result": null, "input": _gather()}
		job.task = WorkerThreadPool.add_task(_run_job.bind(job), false, "pony touch fit")
		_jobs[_key] = job
		return
	var job: Dictionary = _jobs[_key]
	if not WorkerThreadPool.is_task_completed(job.task): return
	WorkerThreadPool.wait_for_task_completion(job.task)
	_fits[_key] = job.result
	_jobs.erase(_key)
	_build_shapes(_fits[_key])


static func _run_job(job: Dictionary) -> void:
	job.result = _fit(job.input)


func _build_shapes(fits: Array) -> void:
	if not is_inside_tree() or (not _entries.is_empty() and _installed_key==_key):return
	if not _entries.is_empty():_free_shapes()
	_installed_key=_key
	var hair: Skeleton3D = mare.get("hair_skeleton")
	_rigs = [mare.skeleton, hair, mare.head.skeleton]
	var space := get_world_3d().space
	for fit: Dictionary in fits:
		var skeleton: Skeleton3D = _rigs[fit.rig]
		if not is_instance_valid(skeleton): continue
		var bones := PackedInt32Array()
		for bone_name: String in fit.influences: bones.append(skeleton.find_bone(bone_name))
		if bones.has(-1): continue
		var shape := ConvexPolygonShape3D.new()
		shape.margin = HULL_MARGIN
		var rid := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_KINEMATIC)
		PhysicsServer3D.body_set_collision_layer(rid, 0)   # asleep until a hand comes near
		PhysicsServer3D.body_set_collision_mask(rid, 0)
		PhysicsServer3D.body_set_param(rid, PhysicsServer3D.BODY_PARAM_FRICTION, FRICTION)
		PhysicsServer3D.body_attach_object_instance_id(rid, get_instance_id())
		var e := {"rig": fit.rig, "bones": bones, "bone_name": fit.bone, "region": fit.region, "fit": fit,
			"shape": shape, "rid": rid, "scale": Vector3.ZERO, "world": Transform3D.IDENTITY,
			"a": fit.a, "b": fit.b, "r": fit.r}
		_rescale(e, Vector3.ONE)
		PhysicsServer3D.body_add_shape(rid, shape.get_rid())
		PhysicsServer3D.body_set_space(rid, space)
		_entries.append(e)
		_by_rid[rid] = e


func _free_shapes() -> void:
	_clear_exceptions()
	if _connected: _set_active(false)
	for e: Dictionary in _entries: PhysicsServer3D.free_rid(e.rid)
	_entries.clear()
	_by_rid.clear()
	active = false


func _exit_tree() -> void:
	_free_shapes()


## The nearest hull by its capsule proxy: {entry, distance (to its surface), local, normal}.
func nearest(point: Vector3) -> Dictionary:
	var best := {}
	var best_distance := INF
	for e: Dictionary in _entries:
		var local: Vector3 = e.world.affine_inverse() * point
		var a: Vector3 = e.a; var b: Vector3 = e.b
		var ab := b - a
		var t := clampf((local - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
		var away := local - (a + ab * t)
		var d := away.length() - float(e.r)
		if d < best_distance:
			best_distance = d
			best = {"entry": e, "distance": d, "local": local, "normal": away.normalized() if away.length() > 1e-6 else Vector3.UP}
	return best


## The petting region of the hull nearest a point in the air above her coat (tests, tools).
func region_at(point: Vector3) -> String:
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.03
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, point)
	query.collision_mask = LAYER | SENSE_LAYER
	var rest := get_world_3d().direct_space_state.get_rest_info(query)
	if rest.is_empty() or not _by_rid.has(rest.rid): return ""
	return _refine(_by_rid[rest.rid], (point - Vector3(rest.point)).normalized())


## Torso hulls cover more than one petting region: top, side and underside, by the direction
## from the touched surface to the hand.
func _refine(e: Dictionary, outward: Vector3) -> String:
	var region: String = e.region
	if region.begins_with("head_"):return "head"
	if region not in ["back", "withers", "shoulder"]: return region
	var height := outward.dot(mare.global_basis.y.normalized())
	match region:
		"back": return "back" if height > 0.55 else ("belly" if height < -0.45 else "barrel")
		"withers": return "withers" if height > 0.35 else ("chest" if height < -0.2 else "barrel")
		"shoulder": return "withers" if height > 0.6 else ("chest" if height < -0.3 else "shoulder")
	return region


## This pony's hull under a hand, from the hand's own contacts: {entry, point}. Hair and wings
## lie over the coat and win; her body wins over a leg bulging beside it (a hand under her belly).
const CONTACT_PRIORITY := {"mane": 2, "tail": 2, "wing": 2, "leg": 0}
func _contact(hand: Node3D) -> Dictionary:
	var state := PhysicsServer3D.body_get_direct_state((hand as CollisionObject3D).get_rid())
	if state == null: return {}
	var best := {}
	for i in state.get_contact_count():
		if state.get_contact_collider_id(i) != get_instance_id(): continue
		var e: Variant = _by_rid.get(state.get_contact_collider(i))
		if e == null: continue
		if best.is_empty() or CONTACT_PRIORITY.get(e.region, 1) > CONTACT_PRIORITY.get(best.entry.region, 1):
			best = {"entry": e, "point": state.get_contact_collider_position(i)}
	# A full contact list may have left her out (a hand pressed into a doorway beside her
	# touches the frame and door too: dev 2026-09-28, "a mare walking into a door could not be
	# touched"). Then ask space directly for her hull under the palm.
	if best.is_empty() and hand is RigidBody3D and state.get_contact_count() >= (hand as RigidBody3D).max_contacts_reported:
		best = _hull_under(hand)
		if not best.is_empty(): crowded_hits += 1
	return best


## Touches found by _hull_under because the contact list was full (labs read it).
var crowded_hits := 0
## Her solid hull within a palm's reach of the hand centre: {entry, point}, or {}.
const PALM_REACH := 0.045
var _palm_shape := SphereShape3D.new()
var _palm_query := PhysicsShapeQueryParameters3D.new()
func _hull_under(hand: Node3D) -> Dictionary:
	_palm_shape.radius = PALM_REACH
	_palm_query.shape = _palm_shape; _palm_query.collision_mask = LAYER
	_palm_query.transform = Transform3D(Basis.IDENTITY, hand.global_position)
	var best := {}
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(_palm_query, 16):
		var e: Variant = _by_rid.get(hit.rid)
		if e == null: continue
		if best.is_empty() or CONTACT_PRIORITY.get(e.region, 1) > CONTACT_PRIORITY.get(best.entry.region, 1):
			best = {"entry": e, "point": hand.global_position}
	return best


## Log why a hand right beside her finds no hulls (dev 2026-09-28: a mare walking into a door
## could not be touched). At most once per five seconds per mare.
var _off_logged := -INF
func _report_off(on: bool, nearest_squared: float) -> void:
	if on or nearest_squared > 1.0 or Time.get_ticks_msec() - _off_logged < 5000.0: return
	_off_logged = Time.get_ticks_msec()
	var reason := "disabled" if not enabled else ("held" if mare.is_held() else ("no fit yet" if _entries.is_empty() else ("far tier" if mare.get(&"sim_tier") == 2 else "asleep")))
	print("[touch] %s: hand %.2f m from her root, hulls off (%s)" % [mare.get("identity").id if mare.get("identity") != null else mare.name, sqrt(nearest_squared), reason])


static func _soft(e: Dictionary) -> bool:
	return e.region in ["mane", "tail"] or str(e.region).begins_with("head_Ears")


## A hand inside her hair: the soft hull it overlaps, as a contact without a collision.
var _sense_shape := SphereShape3D.new()
var _sense_query := PhysicsShapeQueryParameters3D.new()
func _sense(hand: Node3D) -> Dictionary:
	_sense_shape.radius = .035
	_sense_query.shape = _sense_shape; _sense_query.collision_mask = SENSE_LAYER
	_sense_query.transform = Transform3D(Basis.IDENTITY, hand.global_position)
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(_sense_query, 8):
		var e: Variant = _by_rid.get(hit.rid)
		if e != null: return {"entry": e, "point": hand.global_position}
	return {}


func _except(hand: Node3D, on: bool) -> void:
	var rid := (hand as CollisionObject3D).get_rid()
	for e: Dictionary in _entries:
		if on:
			PhysicsServer3D.body_add_collision_exception(rid, e.rid)
			PhysicsServer3D.body_add_collision_exception(e.rid, rid)
		else:
			PhysicsServer3D.body_remove_collision_exception(rid, e.rid)
			PhysicsServer3D.body_remove_collision_exception(e.rid, rid)


## Contact and region sensing; grip state never disables collision.
func _update_hands(delta: float, hands: Dictionary) -> Dictionary:
	var result := {}
	# Closed hands still collide. Pickup/pose selection uses controller targets.
	for side in hands:
		var hand: Node3D = hands[side]
		if not is_instance_valid(hand) or not hand is PhysicsBody3D:
			continue
		if not _gestures.has(side): _gestures[side] = GESTURE.new()
		var gesture: RefCounted = _gestures[side]
		if _excepted.has(side) or hand.get_meta("pony_inspection", false) or hand.get_meta("inventory_busy", false):
			gesture.reset(); hand_region.erase(side)
			continue
		var hit := _contact(hand)
		if hit.is_empty(): hit = _sense(hand)
		var local := Vector3.INF; var normal := Vector3.UP; var frame_id := -1
		if not hit.is_empty():
			var e: Dictionary = hit.entry
			var outward: Vector3 = hand.global_position - hit.point
			outward = outward.normalized() if outward.length() > 1e-5 else (e.world.basis * nearest(hand.global_position).get("normal", Vector3.UP)).normalized()
			local = e.world.affine_inverse() * hand.global_position
			normal = e.world.basis.inverse() * outward
			frame_id = e.rid.get_id()
			hand_region[side] = _refine(e, outward)
		else:
			hand_region.erase(side)
		var before: int = gesture.strokes
		var on: bool = gesture.advance(delta, not hit.is_empty(), local, frame_id, normal, _reference(side, hand))
		strokes += gesture.strokes - before
		if on and hand_region.has(side): result[side] = hand_region[side]
	return result


## The hand's own travel: the tracked controller in tracking space (the physics hand is dragged
## by her coat, and the player's locomotion is not the hand moving).
func _reference(side: String, hand: Node3D) -> Vector3:
	var boop: Node = mare.get("boop_node")
	var controller: Node = boop._controllers.get(side) if boop != null else null
	if controller is Node3D and is_instance_valid(controller):
		return (controller as Node3D).position if controller.get_parent() is XROrigin3D else (controller as Node3D).global_position
	return hand.global_position


func _clear_exceptions() -> void:
	for side in _excepted:
		var hand = _excepted[side]
		if is_instance_valid(hand): _except(hand, false)
	_excepted.clear()


## Relaxed smile, half-lidded eyes and a light blush while petted; she stops walking. One
## physical_reaction("petted:<region>") per session for the conversation director.
func _advance_petting(delta: float, touching: Dictionary) -> void:
	var was := petting
	petting = not touching.is_empty()
	if not petting:
		_pet_quiet += delta
		if was: mare.expressions.release_touch("pet")
		return
	var region: String = touching.values()[0]
	for r: String in touching.values():
		if REACTIONS.get(r, Vector3.ZERO).x > REACTIONS.get(region, Vector3.ZERO).x: region = r
	pet_region = region
	var w: Vector3 = REACTIONS.get(region, Vector3(.5, .3, .4))
	mare.expressions.touch("pet", w.x, w.y)
	mare.boop_node.sustain_blush(w.z)
	if not mare.is_held(): mare.begin_touch(Vector3.ZERO, .5)
	if _pet_quiet > SESSION_GAP:
		pets += 1
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_emit >= EMIT_COOLDOWN and mare.get("sleeping") != true:
			_last_emit = now
			mare.physical_reaction.emit("petted:" + region)
	_pet_quiet = 0.0


func apply_body_impulse(world_impulse: Vector3) -> void:
	if mare.has_method("apply_body_impulse"): mare.apply_body_impulse(world_impulse)


# ---------------------------------------------------------------- fitting

## Main thread: the mesh arrays and bind poses, plus a snapshot of her standing pose for the
## mane filter. The worker does the rest.
func _gather() -> Dictionary:
	var identity: Resource = mare.get("identity")
	var input := {"meshes": []}
	var model: Node = mare.get("_model")
	var body: MeshInstance3D = model.find_child("MareBody", true, false) if model != null else null
	if body != null: input.meshes.append(_mesh_input(body, 0, "body"))
	# Fit the actual loaded head, including cheek width, filly scaling and ears.
	# The old Snoot hull alone did not cover the visible side of the face.
	if mare.head != null:
		for mi:MeshInstance3D in mare.head.model.find_children("*","MeshInstance3D",true,false):
			if String(mi.name) in ["Head","Eye","Ears1"] or (mi.name=="Unicorn Horn" and identity!=null and identity.has_horn()):
				input.meshes.append(_mesh_input(mi,2,"head_"+String(mi.name)))
	if identity != null and identity.has_wings() and model != null:
		for mi in model.find_children("wing open*" if _wings_open() else "wing folded*", "MeshInstance3D", true, false):
			input.meshes.append(_mesh_input(mi, 0, "wing"))
	var hair: Node = mare.get("hair")
	var hair_skeleton: Skeleton3D = mare.get("hair_skeleton")
	if hair != null and hair_skeleton != null and identity != null:
		var mane: MeshInstance3D = hair.find_child(identity.hair_prefix + "DevkitMane", true, false)
		var tail: MeshInstance3D = hair.find_child(identity.hair_prefix + "DevkitTail", true, false)
		if mane != null: input.meshes.append(_mesh_input(mane, 1, "mane"))
		if tail != null: input.meshes.append(_mesh_input(tail, 1, "tail"))
		var bone_world := {}
		for bone_name in ["mHead", "mNeck", "mChest"]:
			var bone := hair_skeleton.find_bone(bone_name)
			if bone >= 0: bone_world[bone_name] = hair_skeleton.global_transform * hair_skeleton.get_bone_global_pose(bone)
		input.mane_world = bone_world
		var boop: Node = mare.get("boop_node")
		if boop != null and boop.snoot != null:
			var head: Skeleton3D = boop.head_skeleton
			var frame: Transform3D = head.global_transform * head.get_bone_global_pose(boop._head_bone)
			input.skull = boop.skull_world()
			input.skull_radius = boop.SKULL_RADIUS * frame.basis.get_scale().abs().x
			# Native OpenPony head faces +Z: the back of her head is -Z.
			input.head_back = -frame.basis.z.normalized()
			input.world_scale = mare.skeleton.global_transform.basis.get_scale().abs().x
	return input


static func _mesh_input(mi: MeshInstance3D, rig: int, role: String) -> Dictionary:
	var binds := []
	var skin := mi.skin
	# A hidden rig mesh lends its skeleton path out while parked (hybrid_mare.set_rig_parking).
	var skeleton: Skeleton3D = mi.get_node_or_null(mi.get_meta(&"parked_skeleton", mi.skeleton)) as Skeleton3D
	for i in (skin.get_bind_count() if skin != null else 0):
		var bone_name := String(skin.get_bind_name(i))
		if bone_name == "" and skeleton != null: bone_name = skeleton.get_bone_name(skin.get_bind_bone(i))
		binds.append([bone_name, skin.get_bind_pose(i)])
	var surfaces := []
	for si in mi.mesh.get_surface_count():
		var arrays := mi.mesh.surface_get_arrays(si)
		if arrays[Mesh.ARRAY_BONES] == null: continue
		surfaces.append({"v": arrays[Mesh.ARRAY_VERTEX], "b": arrays[Mesh.ARRAY_BONES], "w": arrays[Mesh.ARRAY_WEIGHTS]})
	return {"rig": rig, "role": role, "binds": binds, "surfaces": surfaces}


static func region_for(role: String, bone: String) -> String:
	if role.begins_with("head_"):return role
	match role:
		"wing": return "wing"
		"tail": return "tail" if bone.begins_with("mTail") or bone == "mPelvis" else ""
		"mane": return "mane" if bone in ["mHead", "mNeck", "mChest"] else ""
	if bone.begins_with("pony_neck") or bone == "pony_head": return "neck"
	if bone == "pony_spine3": return "withers"
	if bone.begins_with("pony_shoulder"): return "shoulder"
	if bone in ["pony_spine1", "pony_spine2"]: return "back"
	if bone == "pony_hips": return "rump"
	if bone.begins_with("pony_flank"): return "flank"
	for part in ["upperArm", "lowerArm", "wrist", "hand_", "finger", "femur", "tibia", "legLower", "tarsal", "hoof"]:
		if part in bone: return "leg"
	if bone.begins_with("pony_foldedWing"): return "wing"
	return ""


## Worker thread, in her bind-pose mesh space. A vertex joins its dominant bone's hull, or, when
## it shares at least BLEND of its weight with a second bone, that pair's blend hull; near a class
## boundary it joins both (and a near 50/50 vertex joins the mirrored pair), so neighbouring hulls
## overlap instead of leaving cracks. The mane keeps only what lies behind her skull. Each bucket
## records how it is skinned (mean weight and weighted mean position per bone) so the runtime can
## put its hull where linear blend skinning puts its centroid.
const BLEND := 0.2
const OVERLAP := 0.08
static func _fit(input: Dictionary) -> Array:
	var buckets := {}
	for mesh_index in input.meshes.size():
		var m: Dictionary = input.meshes[mesh_index]
		var binds: Array = m.binds
		for s: Dictionary in m.surfaces:
			var vertices: PackedVector3Array = s.v
			var bones = s.b
			var weights = s.w
			if vertices.is_empty(): continue
			var stride: int = bones.size() / vertices.size()
			for i in vertices.size():
				var first := -1; var second := -1
				var w1 := 0.0; var w2 := 0.0; var total := 0.0
				for k in stride:
					var weight: float = weights[i * stride + k]
					var b: int = bones[i * stride + k]
					total += weight
					if weight > w1:
						second = first; w2 = w1
						first = b; w1 = weight
					elif weight > w2 and b != first:
						second = b; w2 = weight
				if first < 0 or first >= binds.size() or total <= 0.0: continue
				var bone: String = binds[first][0]
				var region := region_for(m.role, bone)
				if region == "": continue
				var v := vertices[i]
				if m.role in ["head_Ears1","head_Eye"]:region += "_left" if v.x < 0 else "_right"
				var other: String = binds[second][0] if second >= 0 and second < binds.size() else ""
				var t := w2 / (w1 + w2) if other != "" else 0.0
				var keys := []
				if t < BLEND + OVERLAP: keys.append("%d|%s|%s|" % [m.rig, region, bone])
				if t >= BLEND - OVERLAP and other != "": keys.append("%d|%s|%s|%s" % [m.rig, region, bone, other])
				var other_region := region_for(m.role, other) if other != "" else ""
				if t >= 0.5 - OVERLAP and other_region != "": keys.append("%d|%s|%s|%s" % [m.rig, other_region, other, bone])
				for key: String in keys:
					if not buckets.has(key): buckets[key] = {"points": PackedVector3Array(), "influence": {}}
					var bucket: Dictionary = buckets[key]
					bucket.points.append(v)
					for k in stride:
						var weight: float = weights[i * stride + k] / total
						var b: int = bones[i * stride + k]
						if weight <= 0.0 or b >= binds.size(): continue
						var ikey := "%d|%s" % [mesh_index, binds[b][0]]
						if not bucket.influence.has(ikey): bucket.influence[ikey] = [binds[b][0], binds[b][1], 0.0, Vector3.ZERO]
						bucket.influence[ikey][2] += weight
						bucket.influence[ikey][3] += v * weight
	# A blend bucket too small for its own hull joins its bone's pure hull.
	for key: String in buckets.keys():
		var parts := key.split("|")
		if parts[3] == "" or buckets[key].points.size() >= BLEND_MIN_POINTS: continue
		var pure := "%s|%s|%s|" % [parts[0], parts[1], parts[2]]
		if not buckets.has(pure): buckets[pure] = {"points": PackedVector3Array(), "influence": {}}
		buckets[pure].points.append_array(buckets[key].points)
		for ikey in buckets[key].influence:
			var from: Array = buckets[key].influence[ikey]
			if not buckets[pure].influence.has(ikey): buckets[pure].influence[ikey] = [from[0], from[1], 0.0, Vector3.ZERO]
			buckets[pure].influence[ikey][2] += from[2]
			buckets[pure].influence[ikey][3] += from[3]
		buckets.erase(key)
	var directions := _directions(DIRECTIONS)
	var fits := []
	for key: String in buckets:
		var points: PackedVector3Array = buckets[key].points
		if points.size() < MIN_POINTS: continue
		var parts := key.split("|")
		var centre := Vector3.ZERO
		for p in points: centre += p
		centre /= points.size()
		var local := PackedVector3Array()
		local.resize(points.size())
		for i in points.size(): local[i] = points[i] - centre
		var fit := _proxy(local)
		fit.points = _support(_reduce(local, Vector3.ZERO), directions)
		fit.rig = int(parts[0]); fit.region = parts[1]; fit.bone = parts[2]
		fit.centre = centre; fit.count = points.size()
		# Up to three bones by mean weight, renormalised; each with the weighted mean position of
		# the bucket's vertices (its anchor): sum(weight * skin(anchor)) is the skinned centroid.
		var influence: Dictionary = buckets[key].influence
		var order: Array = influence.keys()
		order.sort_custom(func(x, y): return influence[x][2] > influence[y][2])
		order = order.slice(0, 3)
		var kept := 0.0
		for ikey in order: kept += influence[ikey][2]
		fit.influences = []; fit.keys = []; fit.binds = []; fit.weights = PackedFloat32Array(); fit.anchors = PackedVector3Array()
		for ikey in order:
			var entry: Array = influence[ikey]
			fit.influences.append(entry[0]); fit.keys.append(ikey); fit.binds.append(entry[1])
			fit.weights.append(entry[2] / kept)
			fit.anchors.append(entry[3] / entry[2])
		fit.twist = fit.weights[1] / (fit.weights[0] + fit.weights[1]) if fit.weights.size() > 1 else 0.0
		fits.append(fit)
	return fits


## The mane that lies behind her skull and down her neck: the forelock and the hair over the
## skull crown stay with the Snoot, so head scratches still reach the skull.
static func _keep_mane(input: Dictionary, bone: String, q: Vector3) -> bool:
	if not input.has("skull") or not input.mane_world.has(bone): return true
	if bone != "mHead": return true
	var world: Vector3 = input.mane_world[bone] * q
	var behind: float = (world - input.skull).dot(input.head_back)
	return behind > input.skull_radius * 0.6 and world.distance_to(input.skull) < 0.45 * input.world_scale


static func _directions(count: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in count:
		var y := 1.0 - 2.0 * (i + 0.5) / count
		var r := sqrt(maxf(0.0, 1.0 - y * y))
		var phi := i * 2.399963229728653
		out.append(Vector3(cos(phi) * r, y, sin(phi) * r))
	return out


## Dense hair: one point per centimetre cell, the one farthest from the bucket centre.
static func _reduce(points: PackedVector3Array, centre: Vector3) -> PackedVector3Array:
	if points.size() <= 1500: return points
	var cells := {}
	for i in points.size():
		var p := points[i]
		var key := Vector3i(floori(p.x * 100.0), floori(p.y * 100.0), floori(p.z * 100.0))
		if not cells.has(key) or p.distance_squared_to(centre) > points[cells[key]].distance_squared_to(centre):
			cells[key] = i
	var out := PackedVector3Array()
	for key in cells: out.append(points[cells[key]])
	return out


static func _support(points: PackedVector3Array, directions: PackedVector3Array) -> PackedVector3Array:
	var chosen := {}
	for d in directions:
		var best := 0
		var best_dot := -INF
		for i in points.size():
			var dot := points[i].dot(d)
			if dot > best_dot:
				best_dot = dot
				best = i
		chosen[best] = true
	var out := PackedVector3Array()
	for i: int in chosen: out.append(points[i])
	return out


## Capsule proxy along the principal axis (for regions, the release test and reports).
static func _proxy(points: PackedVector3Array) -> Dictionary:
	var centre := Vector3.ZERO
	for p in points: centre += p
	centre /= points.size()
	var xx := 0.0; var xy := 0.0; var xz := 0.0; var yy := 0.0; var yz := 0.0; var zz := 0.0
	for p in points:
		var d := p - centre
		xx += d.x * d.x; xy += d.x * d.y; xz += d.x * d.z; yy += d.y * d.y; yz += d.y * d.z; zz += d.z * d.z
	var axis := Vector3(1, 1, 1).normalized()
	for i in 24:
		var next := Vector3(xx * axis.x + xy * axis.y + xz * axis.z, xy * axis.x + yy * axis.y + yz * axis.z,
			xz * axis.x + yz * axis.y + zz * axis.z)
		if next.length() < 1e-12: break
		axis = next.normalized()
	var low := INF; var high := -INF
	var radii := PackedFloat32Array()
	for p in points:
		var t := (p - centre).dot(axis)
		low = minf(low, t); high = maxf(high, t)
		radii.append(((p - centre) - axis * t).length())
	radii.sort()
	var r := radii[int(radii.size() * 0.6)]
	var half := maxf(0.0, (high - low) * 0.5 - r)
	var middle := centre + axis * (low + high) * 0.5
	return {"centre": centre, "a": middle - axis * half, "b": middle + axis * half, "r": r}
