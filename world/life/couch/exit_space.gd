extends RefCounted
## Full upright capsule, real floor and a stored pre-seat fallback. Never leave collision off.
## Ponies (layer 2) do not count: the player's body never collides with them (hybrid_mare.gd
## contact rules), and a pony asleep beside you in a shared bed blocked every exit, leaving you
## stuck lying down (dev 2026-10-22).
const BLOCKING := 1 | 2048
static func clear_floor(body: CharacterBody3D, at: Vector3, height: float, radius: float) -> Vector3:
	var space := body.get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.45, at + Vector3.DOWN * 1.2, 1, [body.get_rid()])
	var hit := space.intersect_ray(ray)
	if hit.is_empty() or hit.normal.y < 0.85: return Vector3.INF
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = maxf(height, radius * 2.0)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = BLOCKING
	query.exclude = [body.get_rid()]
	query.transform = Transform3D(Basis.IDENTITY, hit.position + Vector3.UP * (height * 0.5 + 0.04))
	if not space.intersect_shape(query, 1).is_empty(): return Vector3.INF
	return hit.position + Vector3.UP * 0.04

static func find_exit(body: CharacterBody3D, seat: Node3D, fallback: Vector3, height: float, radius: float) -> Vector3:
	var source := seat.global_position if is_instance_valid(seat) else body.global_position
	var excludes: Array[RID] = [body.get_rid()]
	# The player climbs off their own furniture. Walls and other furniture still block.
	var furniture: Node = seat.get_parent() if is_instance_valid(seat) else null
	for owner: Node in [body, furniture]:
		if owner == null: continue
		if owner is CollisionObject3D and owner != body: excludes.append(owner.get_rid())
		for part: Node in owner.find_children("*", "CollisionObject3D", true, false): excludes.append(part.get_rid())
	if is_instance_valid(seat):
		var couch: Variant = (seat.get_meta("couch") if seat.has_meta("couch") else null)
		var ahead := seat.global_position - seat.global_basis.z.normalized() * (float(seat.get_meta("depth", 0.45)) * 0.5 + 0.55)
		if is_instance_valid(couch) and couch.opened: ahead = couch.approach(seat)
		for offset in [Vector3.ZERO, seat.global_basis.x.normalized() * 0.75, -seat.global_basis.x.normalized() * 0.75]:
			var floor_at := clear_floor(body, ahead + offset, height, radius)
			if floor_at.is_finite() and reachable(body, source, floor_at, height, radius, excludes): return floor_at
	# Also works when streamed furniture has already been freed.
	var old := clear_floor(body, fallback, height, radius)
	if old.is_finite() and reachable(body, source, old, height, radius, excludes): return old
	for distance in [0.75, 1.5, 2.25]:
		for direction in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]:
			var near := clear_floor(body, fallback + direction * distance, height, radius)
			if near.is_finite() and reachable(body, source, near, height, radius, excludes): return near
	# Standing on the mattress is preferable to crossing a wall. If even that is
	# blocked, keep the existing rest and let the caller retry after space clears.
	var here := clear_floor(body, source, height, radius)
	return here if here.is_finite() and reachable(body, source, here, height, radius, excludes) else Vector3.INF

static func reachable(body: CharacterBody3D, source: Vector3, destination: Vector3, height: float, radius: float, excludes: Array[RID]) -> bool:
	var space := body.get_world_3d().direct_space_state
	var centre := destination + Vector3.UP * (height * .5 + .04)
	var start := Vector3(source.x, centre.y, source.z)
	# A sweep ignores initial overlaps. This ray also rejects a thin wall already
	# touching the starting capsule, rather than allowing a jump through it.
	var ray := PhysicsRayQueryParameters3D.create(start, centre, BLOCKING, excludes)
	ray.hit_from_inside = true
	if not start.is_equal_approx(centre) and not space.intersect_ray(ray).is_empty(): return false
	var shape := CapsuleShape3D.new(); shape.radius = radius; shape.height = maxf(height, radius * 2.0)
	var query := PhysicsShapeQueryParameters3D.new(); query.shape = shape; query.collision_mask = ray.collision_mask; query.exclude = excludes
	query.transform = Transform3D(Basis.IDENTITY, start); query.motion = centre - start
	var travel := space.cast_motion(query)
	return travel.size() == 2 and travel[0] >= 1.0
