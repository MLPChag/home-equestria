extends RefCounted
## Local choices only. Daylight alters outing frequency/cadence, never clip speed.
static func daylight(hours: float) -> float:
	return smoothstep(6.0, 8.0, hours) * (1.0 - smoothstep(17.0, 20.0, hours))

## Everyday walking speed window (m/s) inside the profile's walk band: unhurried at
## night, the brisker upper part of the same band by day.
static func walk_band(band: Vector2, activity: float) -> Vector2:
	var middle := lerpf(band.x, band.y, .55)
	return Vector2(band.x, middle).lerp(Vector2(middle, band.y), activity)

static func rest_span(base: Vector2, activity: float) -> Vector2:
	return base * lerpf(1.25, .55, activity)

static func seated_span(activity: float) -> Vector2:
	return Vector2(36, 72).lerp(Vector2(22, 40), activity)


static func rest_probability(base: float, activity: float) -> float:
	return clampf(base,0.0,1.0) * lerpf(1.0,.25,clampf(activity,0.0,1.0))

static func rest_kind(roll: float) -> String:
	return "lie_down" if roll < .33 else "sit"

## One physics ray when a rest begins, not a per-frame sun/shadow query.
static func sunny(actor: Node3D) -> bool:
	if not is_instance_valid(actor) or not actor.is_inside_tree(): return false
	var clock := actor.get_node_or_null("/root/TimeOfDay")
	if clock == null or not clock.has_method("sun_direction"): return false
	var toward: Vector3 = clock.sun_direction()
	if toward.y < .25: return false
	var start := actor.global_position+Vector3.UP*.7
	var query := PhysicsRayQueryParameters3D.create(start,start+toward*40.0,1)
	if actor is CollisionObject3D: query.exclude=[actor.get_rid()]
	return actor.get_world_3d().direct_space_state.intersect_ray(query).is_empty()
