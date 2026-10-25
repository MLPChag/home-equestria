extends RefCounted
## Rainbow Dash's curved stair, landing and black wrought-iron railings (dev 2026-09-28).
## References (art/references/cloudominium-2026-09-28/): the entrance hall's black iron swirl
## stair rail and upper gallery ring; the living room's pale curved stair along the wall.
## Visible treads ride over one continuous ramp collider, the accepted Golden Oak method
## (separate tread hulls left capsule support gaps). Risers stay <= MAX_RISE and the ramp runs
## through each tread's middle, so hooves stay within half a riser of the stone.
## The low part of the flight is a closed curved base; the open flight above keeps HEADROOM
## under its soffit. The top tread is level and runs on into the landing. A flight standing off
## the hall wall (layout: outer edge inside the narrower bedroom wall) is railed on both sides.
const MESH := preload("res://world/buildings/cloudominium/architecture_mesh.gd")
const MAX_RISE := 0.18
const HEADROOM := 2.05
const RAIL_HEIGHT := 0.95
const BAY := 1.05 # target railing bay between posts

static func polar(radius: float, angle: float, y: float) -> Vector3:
	return Vector3(sin(angle) * radius, y, cos(angle) * radius)

## Horizontal direction of increasing angle (anticlockwise seen from above, up the stair).
static func along(angle: float) -> Vector3:
	return Vector3(cos(angle), 0.0, -sin(angle))

static func outward(angle: float) -> Vector3:
	return Vector3(sin(angle), 0.0, cos(angle))

## Stair numbers from the shell's layout, in radians and metres.
static func measure(layout: Dictionary) -> Dictionary:
	var stair: Dictionary = layout.get("stair", {})
	var hole: Dictionary = layout.get("stair_hole", {})
	var radius := float(layout.get("radius", 4.2))
	var ground := float(layout.get("ground_y", 0.0))
	var upper := float(layout.get("upper_y", 4.8))
	var under := float(layout.get("ground_ceiling_y", upper - 0.25))
	var start := deg_to_rad(float(stair.get("start_angle", 150.0)))
	var finish := start + fposmod(deg_to_rad(float(stair.get("end_angle", 290.0))) - start, TAU)
	var hole_start := start + fposmod(deg_to_rad(float(hole.get("start_angle", 215.0))) - start, TAU)
	var hole_end := hole_start + fposmod(deg_to_rad(float(hole.get("end_angle", 295.0))) - hole_start, TAU)
	var inner := float(stair.get("inner_radius", 2.7))
	var steps := ceili((upper - ground) / MAX_RISE)
	# Climb over all but the last few degrees: the top tread is level and the landing continues
	# flat to the far edge of the hole, the flat approach a capsule needs onto the floor.
	var climb_end := minf(finish - deg_to_rad(2.0), hole_end - deg_to_rad(4.0))
	var rise := (upper - ground) / steps
	var thickness := maxf(0.25, upper - under)
	var open_from := steps
	for k: int in steps:
		if rise * (k + 0.5) - thickness >= HEADROOM:
			open_from = k
			break
	var outer := minf(float(stair.get("outer_radius", 4.1)), radius - 0.02)
	var upper_radius := float(layout.get("upper_radius", radius))
	# A flight close to the wall is built out to it; one standing off the wall (so it arrives
	# inside a narrower upper storey) gets a second railing on its outer edge instead.
	var off_wall := radius - outer >= 0.15
	var s := {
		"radius": radius, "upper_radius": upper_radius, "ground": ground, "upper": upper, "under": under,
		"start": start, "climb_end": climb_end, "steps": steps, "step": (climb_end - start) / steps,
		"rise": rise, "thickness": thickness, "open_from": open_from,
		"inner": inner, "outer": outer, "outer_view": outer if off_wall else radius - 0.01, "outer_rail": off_wall,
		"hole_start": hole_start, "hole_end": hole_end,
		"hole_inner": float(hole.get("inner_radius", inner - 0.1)),
		"hole_outer": minf(float(hole.get("outer_radius", upper_radius)), upper_radius),
	}
	var clearance := under - ramp(s, hole_start)
	if clearance < 2.1:
		push_warning("Cloudominium stair: only %.2f m headroom under the upper floor edge" % clearance)
	return s

## Height of the walkable ramp at an angle: level with each tread's middle.
static func ramp(s: Dictionary, angle: float) -> float:
	var ground: float = s.ground
	return clampf(ground + float(s.rise) * ((angle - float(s.start)) / float(s.step) + 0.5), ground, float(s.upper))

## Builds visuals into `mesh`, bodies under `parent`. Returns spec, path, landing and foot.
static func build(parent: Node3D, mesh: MESH, layout: Dictionary) -> Dictionary:
	var s := measure(layout)
	_treads(mesh, s)
	_landing(mesh, s)
	_colliders(parent, s)
	var rails := make_body("IronRailings")
	_railings(mesh, rails, s)
	parent.add_child(rails)
	var path := _path(s)
	return {"spec": s, "path": path, "landing": path[path.size() - 1], "foot": path[0]}

static func _treads(mesh: MESH, s: Dictionary) -> void:
	var inner: float = s.inner
	var outer: float = s.outer_view
	var ground: float = s.ground
	var start: float = s.start
	var step: float = s.step
	var rise: float = s.rise
	var thickness: float = s.thickness
	var open_from: int = s.open_from
	for k: int in int(s.steps):
		var a := start + k * step
		var b := a + step
		var top := ground + (k + 1) * rise
		var below := ground + k * rise
		var solid := k < open_from
		var low_a := ground if solid else ramp(s, a) - thickness
		var low_b := ground if solid else ramp(s, b) - thickness
		var middle := (a + b) * 0.5
		mesh.quad("column", polar(inner, a, top), polar(outer, a, top), polar(outer, b, top), polar(inner, b, top), Vector3.UP)
		mesh.quad("column", polar(inner, a, below), polar(outer, a, below), polar(outer, a, top), polar(inner, a, top), -along(a))
		mesh.quad("column", polar(inner, a, low_a), polar(inner, b, low_b), polar(inner, b, top), polar(inner, a, top), -outward(middle))
		mesh.quad("column", polar(outer, a, low_a), polar(outer, b, low_b), polar(outer, b, top), polar(outer, a, top), outward(middle))
		if not solid:
			mesh.quad("ceiling", polar(inner, a, low_a), polar(outer, a, low_a), polar(outer, b, low_b), polar(inner, b, low_b), Vector3.DOWN)
		elif k == open_from - 1:
			# The closed base ends in a flat face toward the open space under the upper flight.
			var end_top := ramp(s, b) - thickness
			mesh.quad("column", polar(inner, b, ground), polar(outer, b, ground), polar(outer, b, end_top), polar(inner, b, end_top), along(b))

## Level landing from the top tread to the far edge of the upper floor's stair hole.
static func _landing(mesh: MESH, s: Dictionary) -> void:
	var upper: float = s.upper
	var bottom := upper - float(s.thickness)
	var hole_inner: float = s.hole_inner
	var hole_outer := maxf(float(s.hole_outer), float(s.outer_view))
	var top_tread := float(s.start) + (int(s.steps) - 1) * float(s.step)
	var climb_end: float = s.climb_end
	# Strips beside the level top tread, out to the hole's edges.
	var strips: Array[Vector2] = [Vector2(hole_inner, float(s.inner))]
	if hole_outer - float(s.outer_view) > 0.02:
		strips.append(Vector2(float(s.outer_view), hole_outer))
	for strip: Vector2 in strips:
		_level_block(mesh, top_tread, climb_end, strip.x, strip.y, bottom, upper)
		mesh.quad("column", polar(strip.x, top_tread, bottom), polar(strip.y, top_tread, bottom), polar(strip.y, top_tread, upper), polar(strip.x, top_tread, upper), -along(top_tread))
	# Full width on to the hole's end, flush with the shell's floor beyond it.
	_level_block(mesh, climb_end, float(s.hole_end), hole_inner, hole_outer, bottom, upper)

static func _level_block(mesh: MESH, from: float, to: float, near: float, far: float, bottom: float, top: float) -> void:
	var angles := _arc(from, to)
	for i: int in angles.size() - 1:
		var a := angles[i]
		var b := angles[i + 1]
		mesh.quad("column", polar(near, a, top), polar(far, a, top), polar(far, b, top), polar(near, b, top), Vector3.UP)
		mesh.quad("ceiling", polar(near, a, bottom), polar(far, a, bottom), polar(far, b, bottom), polar(near, b, bottom), Vector3.DOWN)
		mesh.quad("column", polar(far, a, bottom), polar(far, b, bottom), polar(far, b, top), polar(far, a, top), outward((a + b) * 0.5))

static func _arc(from: float, to: float) -> Array[float]:
	var count := maxi(1, ceili(absf(to - from) / deg_to_rad(2.5)))
	var result: Array[float] = []
	for i: int in count + 1:
		result.append(lerpf(from, to, float(i) / count))
	return result

static func make_body(label_text: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = label_text
	body.collision_layer = 1
	body.collision_mask = 0
	return body

static func add_shape(body: StaticBody3D, shape: Shape3D, place: Transform3D = Transform3D.IDENTITY) -> void:
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.transform = place
	body.add_child(collision)

static func _face_quad(faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	faces.append_array(PackedVector3Array([a, b, c, a, c, d]))

## One welded ramp (toe on the ground floor, level landing overlapping the upper floor) and
## closed hulls under the part of the flight too low to walk beneath.
static func _colliders(parent: Node3D, s: Dictionary) -> void:
	var inner: float = s.inner
	var outer: float = s.outer
	var start: float = s.start
	var step: float = s.step
	var steps: int = s.steps
	var upper: float = s.upper
	var ground: float = s.ground
	var faces := PackedVector3Array()
	var angles: Array[float] = [start - step * 0.5]
	for j: int in 2 * steps:
		angles.append(start + j * step * 0.5)
	for i: int in angles.size() - 1:
		var a := angles[i]
		var b := angles[i + 1]
		_face_quad(faces, polar(inner, a, ramp(s, a)), polar(outer, a, ramp(s, a)), polar(outer, b, ramp(s, b)), polar(inner, b, ramp(s, b)))
	var level := _arc(angles[angles.size() - 1], float(s.hole_end) + deg_to_rad(3.0))
	var near := float(s.hole_inner) - 0.05
	var far := maxf(float(s.hole_outer), outer + 0.02) - 0.02
	for i: int in level.size() - 1:
		_face_quad(faces, polar(near, level[i], upper), polar(far, level[i], upper), polar(far, level[i + 1], upper), polar(near, level[i + 1], upper))
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	var ramp_body := make_body("StairRamp")
	add_shape(ramp_body, shape)
	parent.add_child(ramp_body)
	var base := make_body("StairBase")
	for k: int in int(s.open_from):
		var points := PackedVector3Array()
		for angle: float in [start + k * step, start + (k + 1) * step]:
			var top := maxf(ground + 0.01, ramp(s, angle) - 0.03)
			for r: float in [inner, outer]:
				points.append(polar(r, angle, ground - 0.05))
				points.append(polar(r, angle, top))
		var hull := ConvexPolygonShape3D.new()
		hull.points = points
		add_shape(base, hull)
	parent.add_child(base)

## Stair foot on the ground floor, every tread middle, the level top, then onto the upper floor.
static func _path(s: Dictionary) -> Array[Vector3]:
	var centre := (float(s.inner) + float(s.outer)) * 0.5
	var start: float = s.start
	var step: float = s.step
	var upper: float = s.upper
	var path: Array[Vector3] = [polar(centre, start - step, float(s.ground))]
	for k: int in int(s.steps):
		path.append(polar(centre, start + (k + 0.5) * step, float(s.ground) + (k + 1) * float(s.rise)))
	path.append(polar(centre, float(s.climb_end), upper))
	var beyond := float(s.hole_end) + 0.3 / centre
	path.append(polar(centre, beyond, upper))
	path.append(polar(centre - 0.3, beyond + 0.45 / centre, upper))
	return path

static func _railings(mesh: MESH, body: StaticBody3D, s: Dictionary) -> void:
	var start: float = s.start
	var step: float = s.step
	var upper: float = s.upper
	var hole_start: float = s.hole_start
	var rail_radius := float(s.inner) + 0.07
	var first := start + step * 0.35
	var top := start + (int(s.steps) - 1) * step
	# Flight rail on the open inner side (and the outer side when the flight stands off the
	# wall), each curling into a big volute at the foot.
	var sides: Array[float] = [rail_radius]
	if bool(s.outer_rail):
		sides.append(float(s.outer) - 0.07)
	for radius: float in sides:
		var flight := PackedVector3Array()
		var count := maxi(8, ceili(rad_to_deg(top - first) / 2.5))
		for i: int in count + 1:
			var angle := lerpf(first, top, float(i) / count)
			flight.append(polar(radius, angle, ramp(s, angle)))
		iron_run(mesh, body, flight, RAIL_HEIGHT, 0.15, 0.12)
		_newel_curl(mesh, flight[0] + Vector3.UP * RAIL_HEIGHT, along(first))
	# Upper gallery around the well: the hole's first radial edge, then its inner arc.
	var gallery := float(s.hole_inner) - 0.05
	var shift := -along(hole_start) * 0.05
	var wall_end := polar(maxf(float(s.hole_outer), float(s.outer_view)) - 0.06, hole_start, upper) + shift
	var corner := polar(gallery, hole_start, upper) + shift
	var edge := PackedVector3Array()
	for i: int in 9:
		edge.append(wall_end.lerp(corner, i / 8.0))
	iron_run(mesh, body, edge, RAIL_HEIGHT, 0.1, 0.0)
	var corner_angle := hole_start - atan2(0.05, gallery)
	var arc := PackedVector3Array()
	var arc_count := maxi(4, ceili(rad_to_deg(top - corner_angle) / 2.5))
	for i: int in arc_count + 1:
		arc.append(polar(gallery, lerpf(corner_angle, top, float(i) / arc_count), upper))
	iron_run(mesh, body, arc, RAIL_HEIGHT, 0.1, 0.0)
	# The flight's handrail meets the gallery rail over the level top tread.
	var gallery_end := polar(gallery, top, upper)
	var flight_end := polar(rail_radius, top, ramp(s, top))
	mesh.tube("iron", PackedVector3Array([gallery_end + Vector3.UP * RAIL_HEIGHT, flight_end + Vector3.UP * RAIL_HEIGHT]), 0.03, 8)
	_guard(body, gallery_end, flight_end, RAIL_HEIGHT, 0.0)

## One railing run over its foot line: handrail, foot rail, posts, a big S-scroll per bay,
## thin guard boxes on layer 1. `sink` pushes posts into stair treads.
static func iron_run(mesh: MESH, body: StaticBody3D, base: PackedVector3Array, height: float, low: float, sink: float) -> void:
	var lengths: Array[float] = [0.0]
	for i: int in range(1, base.size()):
		var delta := base[i] - base[i - 1]
		lengths.append(lengths[i - 1] + Vector2(delta.x, delta.z).length())
	var total: float = lengths[lengths.size() - 1]
	if total < 0.05:
		return
	var handrail := PackedVector3Array()
	var foot_rail := PackedVector3Array()
	for point: Vector3 in base:
		handrail.append(point + Vector3.UP * height)
		foot_rail.append(point + Vector3.UP * low)
	mesh.tube("iron", handrail, 0.03, 8)
	mesh.tube("iron", foot_rail, 0.017, 6)
	var bays := maxi(1, roundi(total / BAY))
	var bay := total / bays
	for j: int in bays + 1:
		var foot := _at(base, lengths, j * bay)
		mesh.tube("iron", PackedVector3Array([foot - Vector3.UP * sink, foot + Vector3.UP * height]), 0.022, 6)
		if j < bays:
			_scroll(mesh, base, lengths, j * bay, bay, low, height)
	var pieces := maxi(1, ceili(total / 0.4))
	for j: int in pieces:
		_guard(body, _at(base, lengths, total * j / pieces), _at(base, lengths, total * (j + 1) / pieces), height, sink)

static func _at(base: PackedVector3Array, lengths: Array[float], distance: float) -> Vector3:
	if distance <= 0.0:
		return base[0]
	for i: int in base.size() - 1:
		if distance <= lengths[i + 1]:
			var span := lengths[i + 1] - lengths[i]
			return base[i].lerp(base[i + 1], (distance - lengths[i]) / span if span > 0.0 else 0.0)
	return base[base.size() - 1]

## Entrance-hall ironwork: a low curl rising into a high curl, drawn in the bay's own plane
## (sheared with the stair). Broad shapes read under the game's ink outline.
static func _scroll(mesh: MESH, base: PackedVector3Array, lengths: Array[float], from: float, bay: float, low: float, height: float) -> void:
	var band := height - low
	var radius := minf(bay * 0.2, band * 0.21)
	var lower := Vector2(bay * 0.3, band * 0.3)
	var higher := Vector2(bay * 0.7, band * 0.7)
	var shape := PackedVector2Array()
	for i: int in 21:
		var t := i / 20.0
		var angle := PI * 0.5 + TAU * 1.25 * (1.0 - t)
		shape.append(lower + Vector2(cos(angle), sin(angle)) * radius * lerpf(0.18, 1.0, t))
	for i: int in range(1, 6):
		shape.append((lower + Vector2(0, radius)).lerp(higher - Vector2(0, radius), i / 6.0))
	for i: int in 21:
		var t := i / 20.0
		var angle := -PI * 0.5 + TAU * 1.25 * t
		shape.append(higher + Vector2(cos(angle), sin(angle)) * radius * lerpf(1.0, 0.18, t))
	var points := PackedVector3Array()
	for p: Vector2 in shape:
		points.append(_at(base, lengths, from + p.x) + Vector3.UP * (low + p.y))
	mesh.tube("iron", points, 0.016, 6)

## The handrail's start rolls back and down into a volute, as at the entrance hall stair.
static func _newel_curl(mesh: MESH, top: Vector3, forward: Vector3) -> void:
	var size := 0.22
	var centre := top - Vector3.UP * size
	var points := PackedVector3Array()
	for i: int in 27:
		var t := i / 26.0
		var angle := TAU * 1.4 * t
		var r := size * lerpf(1.0, 0.2, t)
		points.append(centre - forward * sin(angle) * r + Vector3.UP * cos(angle) * r)
	mesh.tube("iron", points, 0.03, 8, 0.018)

## Guard box from a to b: on the floor, or reaching under the ramp for stair rails.
static func _guard(body: StaticBody3D, a: Vector3, b: Vector3, height: float, sink: float) -> void:
	var flat := Vector3(b.x - a.x, 0.0, b.z - a.z)
	if flat.length() < 0.01:
		return
	var low := minf(a.y, b.y) - (0.22 if sink > 0.0 else 0.0)
	var high := maxf(a.y, b.y) + height + 0.05
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.08, high - low, flat.length() + 0.02)
	var middle := (a + b) * 0.5
	middle.y = (low + high) * 0.5
	add_shape(body, shape, Transform3D(Basis.looking_at(flat.normalized(), Vector3.UP), middle))
