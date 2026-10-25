extends RefCounted
## Closed-fist, tracking-space strike; locomotion, recovery and resting contact do not hit.
const WITHDRAWAL: float = .16
const CONTACT: float = .065
const MIN_SPEED: float = 1.2
var previous: Dictionary = {}
var armed: Dictionary = {}

func reset(side: String) -> void:
	previous.erase(side)
	armed.erase(side)

func sample(side: String, point: Vector3, reference: Transform3D, closed: bool,
		active: bool, delta: float, candidates: Array[Dictionary]) -> String:
	if not active or not point.is_finite() or not reference.is_finite() or absf(reference.basis.determinant()) < .001 or delta <= 0 or delta > .12:
		reset(side); return ""
	var motor: Vector3 = reference.affine_inverse() * point
	var prior: Dictionary = previous.get(side, {})
	previous[side] = {"point": point, "motor": motor}
	if prior.is_empty(): return ""
	var movement: Vector3 = point - Vector3(prior.point)
	var hand_motion: Vector3 = reference.basis * (motor - Vector3(prior.motor))
	if movement.length() > .5 or hand_motion.length() > .5:
		reset(side); return ""
	var ready: Dictionary = armed.get(side, {})
	armed[side] = ready
	var found: String = ""
	var earliest: float = 2.0
	for tree: Dictionary in candidates:
		var centre: Vector3 = tree.position
		var a: Vector3 = Vector3(prior.point) - centre
		var b: Vector3 = point - centre
		var radius: float = float(tree.radius) + CONTACT
		var from: Vector2 = Vector2(a.x, a.z)
		var to: Vector2 = Vector2(b.x, b.z)
		if from.length() > radius + WITHDRAWAL: ready[tree.id] = true
		if not closed or not ready.get(tree.id, false): continue
		var travel: Vector2 = to - from
		var aa: float = travel.length_squared()
		if aa < .0000001: continue
		var bb: float = 2.0 * from.dot(travel)
		var cc: float = from.length_squared() - radius * radius
		var discriminant: float = bb * bb - 4.0 * aa * cc
		if cc <= 0.0 or discriminant < 0.0: continue
		var t: float = (-bb - sqrt(discriminant)) / (2.0 * aa)
		if t < 0.0 or t > 1.0: continue
		ready.erase(tree.id) # A slow contact must withdraw too.
		var hit: Vector3 = a.lerp(b, t)
		if hit.y < .25 or hit.y > float(tree.height): continue
		var normal: Vector3 = Vector3(hit.x, 0, hit.z).normalized()
		if -movement.dot(normal) / delta < MIN_SPEED or -hand_motion.dot(normal) / delta < MIN_SPEED: continue
		if -movement.normalized().dot(normal) < .65: continue
		if t < earliest: earliest = t; found = str(tree.id)
	if not found.is_empty(): ready.clear()
	return found
