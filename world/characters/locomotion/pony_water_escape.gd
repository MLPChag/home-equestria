extends RefCounted
## Rare rescue path for accidental river entry. Normal routes still avoid water.
const WATER := preload("res://world/water/water_contact.gd")
const SWIMMING := preload("res://player/player_swimming.gd")
var active := false
var _sample_wait := 0.0
var _search_wait := 0.0
var _search_index := 0
var _surface := -INF
var _shore := Vector3.INF
## The shore aimed at is dry ground below the water level (past the end of the water, at the
## foot of its bank); any shore at the level is preferred over it.
var _shore_low := false
var _dry := Vector3.INF
var _swim := SWIMMING.new()
## The AnonPony's stick/WASD direction this tick (player/pony_form.gd); consumed by update().
var steer := Vector3.ZERO
var _lost := 0.0

func reset() -> void:
	active = false; _swim.climbing = false; _swim.active = false
	_sample_wait = 0.0; _shore = Vector3.INF; _shore_low = false; steer = Vector3.ZERO; _lost = 0.0

func update(pony: CharacterBody3D, delta: float) -> bool:
	if pony._held or pony.motion_paused or (pony.thrown != null and pony.thrown.active()) or (pony.flight != null and pony.flight.active()):
		reset(); return false
	_sample_wait -= delta
	if _sample_wait<=0.0:
		_sample_wait = .5
		_surface = WATER.surface_above(pony.get_world_3d().direct_space_state,pony.global_position)
		if not is_finite(_surface) and not active and pony.grounded(): _dry = pony.global_position
	var wet: bool = is_finite(_surface) and _surface-pony.global_position.y>pony.profile.hip_height*.45
	if not wet and not _swim.climbing:
		if active:
			active = false
			pony.reset_motion(pony.global_transform)
		# Wading, or out of the water's footprint but still below its level beside it (a dry
		# strip at the foot of a steep bank): the player pushing there still climbs out or is
		# rescued, as Anon is (player_swimming.gd remembers the water level for a few metres).
		var pushed := steer
		steer = Vector3.ZERO
		if pushed.length_squared()<=.01: return false
		_swim.active = false; _swim.surface = _surface
		if not _swim.bank_exit(pony,pony.global_position,pony.profile.hip_height*1.5,pushed,false,delta): return false
		if not _swim.climbing: _sample_wait = 0.0 # moved: re-read the water at the new spot now
		return true
	if not active:
		active = true; _shore = Vector3.INF; _shore_low = false; _search_index = 0; _search_wait = 0.0
		if "sleeping" in pony: pony.sleeping = false
		pony.set_sim_tier(0,0) # restore her physical capsule before swimming/climbing
		pony.reset_motion(pony.global_transform)
		var nav: Node = pony.get_node_or_null("Navigator")
		if nav != null: nav.stay(); nav.wander_enabled = true
	_search_wait -= delta
	if _search_wait<=0.0 and not _swim.climbing:
		_search_wait = .25
		_find_shore(pony)
	var direction := Vector3.ZERO
	if _shore.is_finite():
		direction = _shore-pony.global_position; direction.y = 0.0; direction = direction.normalized()
	# The player's pony swims where the player pushes; with no input she heads for the shore.
	if steer.length_squared()>.01: direction = Vector3(steer.x,0,steer.z).normalized()
	steer = Vector3.ZERO
	# No shore found in reach (walled canal, cliffs): the shared dry-ground rescue.
	_lost = _lost+delta if direction.is_zero_approx() and not _swim.climbing else 0.0
	if _lost>=SWIMMING.RESCUE_AFTER:
		_lost = 0.0
		_swim.surface = _surface
		if _swim.rescue(pony,pony.global_position,Vector3.ZERO):
			if not _swim.climbing: _sample_wait = 0.0 # moved: re-read the water at the new spot now
			return true
	_swim.active = true; _swim.surface = _surface
	if _swim.bank_exit(pony,pony.global_position,pony.profile.hip_height*1.5,direction,true,delta):
		if not _swim.climbing: _sample_wait = 0.0
		return true
	var target_y: float = _surface-pony.profile.hip_height*.65
	pony.velocity = direction*1.3
	pony.velocity.y = clampf((target_y-pony.global_position.y)*3.0,-.6,1.5)
	pony.move_and_slide()
	if not direction.is_zero_approx(): pony.rotation.y = rotate_toward(pony.rotation.y,atan2(-direction.x,-direction.z),delta*2.0)
	return true

func _find_shore(pony: CharacterBody3D) -> void:
	# Two bounded probes per search tick, preferring the bank she came from.
	var space := pony.get_world_3d().direct_space_state
	for attempt in 2:
		var candidate := _dry if _search_index==0 and _dry.is_finite() and _dry.distance_to(pony.global_position)<48.0 else Vector3.INF
		if not candidate.is_finite():
			var index := _search_index%32
			var radius := 4.0*pow(2.0,floorf(index/8.0))
			var angle := float(index%8)*TAU/8.0
			candidate = pony.global_position+Vector3(cos(angle),0,sin(angle))*radius
		_search_index += 1
		# Banks up to 4 m high, and dry ground just past the edge of the water below its level.
		var ray := PhysicsRayQueryParameters3D.create(Vector3(candidate.x,_surface+4.0,candidate.z),Vector3(candidate.x,_surface-4.5,candidate.z),pony.floor_mask,[pony.get_rid()])
		var hit := space.intersect_ray(ray)
		if hit.is_empty() or hit.normal.y<maxf(.7,cos(pony.floor_max_angle)+.02): continue
		var goal: Vector3 = hit.position+Vector3.UP*.04
		if WATER.surface_above(space,goal)>goal.y: continue
		var low := goal.y<_surface-.3
		if low and _shore.is_finite() and not _shore_low: continue
		if not _shore.is_finite() or (_shore_low and not low) or goal.distance_squared_to(pony.global_position)<_shore.distance_squared_to(pony.global_position):
			_shore = goal; _shore_low = low
