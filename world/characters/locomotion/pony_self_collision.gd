extends RefCounted
## Bounded self-collision between the legs and the belly.
##
## Shapes are deliberately simpler than the mesh: a sphere per hoof, a capsule
## per forearm/cannon segment, and one belly capsule in the body frame. Sizes
## come from the smooth mare's rest-pose vertex extents (tools/probe_body_radii.gd)
## and are slightly under the true silhouette, so the authored trot -- whose
## same-side hooves pass 9.8 cm apart horizontally while the other is 10 cm up
## -- is never touched. Pushes move contact *targets*; the existing IK and joint
## limits then decide how far the leg can actually follow. Nothing here
## translates or stretches a bone.

const HOOF_RADIUS := 0.055
## Sphere centre above the sole point; the sole sits under the hoof's bulk.
const HOOF_LIFT := 0.035
const SEGMENT_RADIUS := 0.045
## The belly is only checked against hooves and cannons: forearms and gaskins
## legitimately join the body, so a capsule that excluded them would have to be
## smaller than the belly actually is.
const BELLY_RADIUS := 0.08
const BELLY_FROM := Vector3(0.0, 0.45, 0.02)
const BELLY_TO := Vector3(0.0, 0.45, 0.25)
const MAX_PUSH := 0.08
const SEGMENT_NAMES := ["upper", "cannon"]
## Contact labels by id (the native measure reports ids in this order).
const LABELS := ["hoof-hoof", "hoof-upper", "hoof-cannon", "upper-upper", "upper-cannon",
	"cannon-upper", "cannon-cannon", "hoof-belly", "cannon-belly"]

var hoof_radius := HOOF_RADIUS
var segment_radius := SEGMENT_RADIUS
var belly_radius := BELLY_RADIUS
## Smoothed push per leg, in world metres. Diagnostics read these.
var pushes: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
## Deepest overlap seen this tick per leg, before resolution.
var penetration := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var max_penetration := 0.0
## Human-readable overlaps from the last measure, deepest first. Diagnostics, formatted
## only when read.
var contacts: Array:
	get: return _format_contacts()
## PonySolverNative (docs/NATIVE_SOLVER_2026_09_25.md) or null for the GDScript measure.
var native: RefCounted
## Overlaps from the last measure in detection order: [depth, label id, i, j] each
## (GDScript), or the native measure's flat PackedFloat64Array of the same.
var _records: Variant = []
var _native_bones := PackedInt32Array()
var _native_profile: Resource
var _pending: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]


func reset() -> void:
	for i in 4:
		pushes[i] = Vector3.ZERO
		_pending[i] = Vector3.ZERO
		penetration[i] = 0.0
	max_penetration = 0.0


## Measures overlaps in the given world-space forward kinematics and returns
## the raw push each leg wants, before smoothing. `feet` supplies contact
## weights: a loaded hoof yields less than an airborne one.
func measure(profile: Resource, fk: Array[Transform3D], feet: Array[Dictionary],
		frame: Transform3D, forward: Vector3) -> Array[Vector3]:
	var wanted: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	if native != null:
		return _measure_native(profile, fk, feet, frame, forward)
	for i in 4:
		penetration[i] = 0.0
	max_penetration = 0.0
	_records = []
	var hooves: Array[Vector3] = []
	var segments: Array = []
	var mobility: Array[float] = []
	for i in 4:
		var leg: Dictionary = profile.legs[i]
		var sole: Vector3 = fk[leg.leaf] * Vector3(feet[i].dynamic_sole)
		hooves.append(sole + Vector3.UP * HOOF_LIFT)
		segments.append([[fk[leg.middle].origin, fk[leg.leaf].origin], [fk[leg.leaf].origin, sole]])
		mobility.append(1.0 - clampf(float(feet[i].weight), 0.0, 1.0))
	var belly_a := frame * BELLY_FROM
	var belly_b := frame * BELLY_TO
	for i in 4:
		for j in range(i + 1, 4):
			var share_i := _share(mobility[i], mobility[j])
			var share_j := 1.0 - share_i
			# Hoof against hoof.
			_separate(wanted, i, j, hooves[i], hooves[j], hoof_radius * 2.0, share_i, share_j, forward, 0)
			# Hoof against the other leg's segments, both ways.
			for k in 2:
				var q := _closest_on_segment(hooves[i], segments[j][k][0], segments[j][k][1])
				_separate(wanted, i, j, hooves[i], q, hoof_radius + segment_radius, share_i, share_j, forward, 1 + k)
				q = _closest_on_segment(hooves[j], segments[i][k][0], segments[i][k][1])
				_separate(wanted, j, i, hooves[j], q, hoof_radius + segment_radius, share_j, share_i, forward, 1 + k)
			# Lower segments against each other (legs crossing mid-stride).
			for a in 2:
				for b in 2:
					var pair := _closest_between_segments(segments[i][a][0], segments[i][a][1], segments[j][b][0], segments[j][b][1])
					_separate(wanted, i, j, pair[0], pair[1], segment_radius * 2.0, share_i, share_j, forward, 3 + a * 2 + b)
	# Legs against the belly. The body never moves out of the way.
	for i in 4:
		var q := _closest_on_segment(hooves[i], belly_a, belly_b)
		_separate(wanted, i, -1, hooves[i], q, hoof_radius + belly_radius, 1.0, 0.0, forward, 7)
		var pair := _closest_between_segments(segments[i][1][0], segments[i][1][1], belly_a, belly_b)
		_separate(wanted, i, -1, pair[0], pair[1], segment_radius + belly_radius, 1.0, 0.0, forward, 8)
	return wanted


## measure() in PonySolverNative: same overlaps, pushes and penetrations bit for bit.
func _measure_native(profile: Resource, fk: Array[Transform3D], feet: Array[Dictionary],
		frame: Transform3D, forward: Vector3) -> Array[Vector3]:
	if _native_profile != profile:
		_native_profile = profile
		_native_bones.clear()
		for i in 4:
			_native_bones.append(int(profile.legs[i].middle))
			_native_bones.append(int(profile.legs[i].leaf))
	var soles := PackedVector3Array()
	var weights := PackedFloat64Array()
	for i in 4:
		soles.append(Vector3(feet[i].dynamic_sole))
		weights.append(float(feet[i].weight))
	var result: Array = native.measure_self_collision(fk, _native_bones, soles, weights, frame, forward,
		PackedFloat64Array([hoof_radius, segment_radius, belly_radius, HOOF_LIFT]), BELLY_FROM, BELLY_TO)
	var pushed: PackedVector3Array = result[0]
	penetration = result[1]
	max_penetration = result[2]
	_records = result[3]
	var wanted: Array[Vector3] = [pushed[0], pushed[1], pushed[2], pushed[3]]
	return wanted


## The batched pose solve's last measure (pony_solve_batch.gd): same fields as measure() sets.
func apply_native(native_penetration: PackedFloat32Array, native_max: float, records: PackedFloat64Array) -> void:
	penetration = native_penetration
	max_penetration = native_max
	_records = records


func _format_contacts() -> Array:
	var list: Array = []
	if _records is PackedFloat64Array:
		var flat: PackedFloat64Array = _records
		for n in range(0, flat.size(), 4):
			var depth := flat[n]
			list.append([depth, "%s %d/%d %.1f mm" % [LABELS[int(flat[n + 1])], int(flat[n + 2]), int(flat[n + 3]), depth * 1000.0]])
	else:
		for record: Array in _records:
			list.append([record[0], "%s %d/%d %.1f mm" % [LABELS[record[1]], record[2], record[3], record[0] * 1000.0]])
	list.sort_custom(func(a, b): return a[0] > b[0])
	return list


## Smooths the wanted pushes and reports whether any leg needs re-solving.
func integrate(wanted: Array[Vector3], feet: Array[Dictionary], delta: float) -> bool:
	var active := false
	for i in 4:
		var target := wanted[i].limit_length(MAX_PUSH)
		if float(feet[i].weight) > 0.7 and float(feet[i].get("planted", false)):
			# A loaded hoof may slide along the ground but never leave it.
			target.y = minf(target.y, 0.0)
		var response := 0.03 if target.length_squared() > pushes[i].length_squared() else 0.08
		pushes[i] = pushes[i].lerp(target, 1.0 - exp(-delta / response))
		if pushes[i].length() < 0.0005:
			pushes[i] = Vector3.ZERO
		else:
			active = true
	return active


func _share(mobility_a: float, mobility_b: float) -> float:
	var total := mobility_a + mobility_b
	if total < 0.05:
		return 0.5
	return mobility_a / total


func _separate(wanted: Array[Vector3], i: int, j: int, point_i: Vector3, point_j: Vector3,
		clearance: float, share_i: float, share_j: float, forward: Vector3, label: int) -> void:
	var d := point_i - point_j
	var distance := d.length()
	if distance >= clearance:
		return
	var depth := clearance - distance
	_records.append([depth, label, i, j])
	# Coincident points have no direction; the crossing that matters is fore/aft.
	var normal := d / distance if distance > 0.001 else forward
	penetration[i] = maxf(penetration[i], depth)
	max_penetration = maxf(max_penetration, depth)
	wanted[i] += normal * depth * share_i
	if j >= 0:
		penetration[j] = maxf(penetration[j], depth)
		wanted[j] -= normal * depth * share_j


static func _closest_on_segment(p: Vector3, a: Vector3, b: Vector3) -> Vector3:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
	return a + ab * t


static func _closest_between_segments(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> Array[Vector3]:
	# Ericson, Real-Time Collision Detection, 5.1.9.
	var d1 := q1 - p1
	var d2 := q2 - p2
	var r := p1 - p2
	var a := d1.length_squared()
	var e := d2.length_squared()
	var f := d2.dot(r)
	var s := 0.0
	var t := 0.0
	if a <= 1e-9 and e <= 1e-9:
		return [p1, p2]
	if a <= 1e-9:
		t = clampf(f / e, 0.0, 1.0)
	else:
		var c := d1.dot(r)
		if e <= 1e-9:
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b := d1.dot(d2)
			var denominator := a * e - b * b
			s = clampf((b * f - c * e) / denominator, 0.0, 1.0) if denominator > 1e-9 else 0.0
			t = (b * s + f) / e
			if t < 0.0:
				t = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif t > 1.0:
				t = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)
	return [p1 + d1 * s, p2 + d2 * t]
