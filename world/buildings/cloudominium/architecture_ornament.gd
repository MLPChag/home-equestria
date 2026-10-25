extends RefCounted
## Cloudominium ornament in the room frame (dev 2026-09-28). From the entrance hall reference:
## pale blue-white Ionic columns (fluted shaft, scroll capital, square abacus), arched window
## trim and sills, the gold lightning-bolt pair over the door and recessed round ceiling
## lights; from the lounge reference, the rainbow painted across the upper wall.
## Clean cartoon forms: broad silhouettes, the game's ink outline supplies the line work.
const MESH := preload("res://world/buildings/cloudominium/architecture_mesh.gd")
const STAIR := preload("res://world/buildings/cloudominium/architecture_stair.gd")
const MATERIALS := preload("res://world/buildings/cloudominium/materials.gd")
const COLUMN_CLEARANCE := 0.3 # collision radius around each column's axis
const COLUMN_WIDTH := 0.82 # slim enough to stand between the wall and an off-wall stair
const COLUMN_WALL_GAP := 0.26 # wall column axis in from the hall wall
const TRIM := 0.13 # window architrave width on the wall
const TRIM_DEPTH := 0.07 # how far the architrave stands off the wall
const ARCH_SAMPLES := 14
const RAINBOW_BAND := 0.07
## Pastel bands, outer to inner, as room_surface.gdshader paints them.
const RAINBOW := [Color(0.95, 0.55, 0.55), Color(0.97, 0.72, 0.48), Color(0.96, 0.9, 0.55),
	Color(0.62, 0.86, 0.58), Color(0.55, 0.77, 0.93), Color(0.72, 0.61, 0.9)]
## One lightning bolt, tip down, in a unit box (entrance hall door bolts).
const BOLT := [Vector2(0.2, 1.0), Vector2(0.62, 1.0), Vector2(0.42, 0.62), Vector2(0.7, 0.62),
	Vector2(0.18, 0.0), Vector2(0.33, 0.45), Vector2(0.08, 0.45)]

## A column either side of the door (clear of its swing and the windows), one closing the
## lounge before the stair foot, and a free-standing one carrying the upper floor beside the
## start of the open flight. Returns their base points.
static func columns(parent: Node3D, mesh: MESH, layout: Dictionary, s: Dictionary) -> Array[Vector3]:
	var radius := float(layout.get("radius", 4.2))
	var ground := float(layout.get("ground_y", 0.0))
	var height := float(layout.get("ground_ceiling_y", 4.55)) - ground
	var door: Vector3 = layout.get("door_position", Vector3(0, ground, radius))
	var door_angle := atan2(door.x, door.z)
	var wall := radius - COLUMN_WALL_GAP
	var half := 0.34 * COLUMN_WIDTH / wall
	var spans := window_spans(layout, false)
	# A flight built out to the wall leaves no room for wall columns along it.
	var reach := float(s.outer_view)
	if reach > wall - 0.3 * COLUMN_WIDTH:
		spans.append(Vector2((float(s.start) + float(s.climb_end)) * 0.5, (float(s.climb_end) - float(s.start)) * 0.5 + 0.08))
	var spots: Array[Vector3] = []
	for direction: float in [-1.0, 1.0]:
		for i: int in 70:
			var angle := door_angle + direction * deg_to_rad(6.0 + 0.5 * i)
			var at := STAIR.polar(wall, angle, ground)
			if _clear(angle, half, spans) and not _in_swing(at, layout, 0.3):
				spots.append(at)
				break
	var closer := float(s.start) - deg_to_rad(20.0)
	for i: int in 49:
		var angle := closer + deg_to_rad(0.5 * floorf((i + 1) * 0.5)) * (1.0 if i % 2 == 0 else -1.0)
		if _clear(angle, half, spans):
			spots.append(STAIR.polar(wall, angle, ground))
			break
	var open_angle := float(s.start) + int(s.open_from) * float(s.step) + deg_to_rad(3.0)
	spots.append(STAIR.polar(float(s.inner) - 0.45, open_angle, ground))
	var part := MESH.new()
	_column(part, height, COLUMN_WIDTH)
	var column := part.bake(false)
	var body := STAIR.make_body("Columns")
	var cylinder := CylinderShape3D.new()
	cylinder.radius = COLUMN_CLEARANCE
	cylinder.height = height
	for at: Vector3 in spots:
		var facing := Vector3(-at.x, 0.0, -at.z).normalized()
		mesh.append(column, part.baked_keys, Transform3D(Basis(Vector3.UP.cross(facing), Vector3.UP, facing), at))
		STAIR.add_shape(body, cylinder, Transform3D(Basis.IDENTITY, at + Vector3.UP * height * 0.5))
	parent.add_child(body)
	return spots

## Angular spans (centre, half-width) the windows of one storey take on its wall, trim included.
static func window_spans(layout: Dictionary, upper: bool) -> Array[Vector2]:
	var wall := wall_radius(layout, upper)
	var spans: Array[Vector2] = []
	for window: Dictionary in layout.get("windows", []):
		if is_upper(window, layout) == upper:
			spans.append(Vector2(deg_to_rad(float(window.get("angle", 0.0))), (float(window.get("width", 1.2)) * 0.5 + TRIM + 0.1) / wall))
	return spans

static func is_upper(window: Dictionary, layout: Dictionary) -> bool:
	if window.has("level"):
		return str(window.get("level")) == "upper"
	return float(window.get("y", 0.0)) > float(layout.get("ground_ceiling_y", 4.55))

static func wall_radius(layout: Dictionary, upper: bool) -> float:
	var radius := float(layout.get("radius", 4.2))
	return float(layout.get("upper_radius", radius)) if upper else radius

static func _clear(angle: float, half: float, spans: Array[Vector2]) -> bool:
	for span: Vector2 in spans:
		if absf(wrapf(angle - span.x, -PI, PI)) < half + span.y:
			return false
	return true

## Whether a column footprint at `at` reaches the front door's inward swing.
static func _in_swing(at: Vector3, layout: Dictionary, reach: float) -> bool:
	var radius := float(layout.get("radius", 4.2))
	var door: Vector3 = layout.get("door_position", Vector3(0, 0, radius))
	var width := float(layout.get("door_width", 1.9))
	var direction := Vector2(door.x, door.z).normalized()
	var local := Vector2(at.x, at.z) - Vector2(door.x, door.z)
	var across := local.dot(Vector2(direction.y, -direction.x))
	var inward := -local.dot(direction)
	var nearest := Vector2(clampf(across, -width * 0.5 - 0.03, width * 0.5 + 0.03), clampf(inward, 0.0, width + 0.1))
	return nearest.distance_to(Vector2(across, inward)) < reach

## One Ionic column in local metres, front (volute faces) toward local +Z; `w` scales its width.
static func _column(mesh: MESH, height: float, w: float) -> void:
	var top := height
	mesh.box("column", Vector3(0, 0.06, 0), Vector3(0.64 * w, 0.12, 0.64 * w))
	mesh.lathe("column", _widen([Vector2(0, 0.12), Vector2(0.3, 0.12), Vector2(0.315, 0.15),
		Vector2(0.3, 0.185), Vector2(0.265, 0.2), Vector2(0.255, 0.23), Vector2(0.28, 0.25),
		Vector2(0.272, 0.285), Vector2(0.25, 0.3), Vector2(0, 0.3)], w))
	_fluted_shaft(mesh, 0.3, top - 0.6, 0.25 * w, 0.224 * w, 0.03 * w)
	mesh.lathe("column", _widen([Vector2(0, top - 0.6), Vector2(0.224, top - 0.6),
		Vector2(0.246, top - 0.58), Vector2(0.224, top - 0.56), Vector2(0.232, top - 0.5),
		Vector2(0.285, top - 0.41), Vector2(0.3, top - 0.36), Vector2(0, top - 0.36)], w))
	# Canalis between the two volute scrolls, then the square abacus.
	mesh.box("column", Vector3(0, top - 0.245, 0), Vector3(0.5 * w, 0.25, 0.42 * w))
	for side: float in [-1.0, 1.0]:
		mesh.push(Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(side * 0.24 * w, top - 0.3, 0)))
		mesh.lathe("column", _widen([Vector2(0, -0.22), Vector2(0.13, -0.22), Vector2(0.14, -0.2),
			Vector2(0.14, 0.2), Vector2(0.13, 0.22), Vector2(0, 0.22)], w), 24)
		mesh.pop()
		for face: float in [-1.0, 1.0]:
			var spiral := PackedVector3Array()
			for i: int in 25:
				var t := i / 24.0
				var angle := PI * 0.5 + side * TAU * 2.0 * t
				var r := lerpf(0.118, 0.025, t) * w
				spiral.append(Vector3(side * 0.24 * w + cos(angle) * r, top - 0.3 + sin(angle) * r, face * 0.226 * w))
			mesh.tube("column", spiral, 0.013, 6)
	mesh.box("column", Vector3(0, top - 0.06, 0), Vector3(0.7 * w, 0.12, 0.7 * w))

## Lathe profile (radius, height) made narrower or wider.
static func _widen(profile: Array, w: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point: Vector2 in profile:
		result.append(Vector2(point.x * w, point.y))
	return result

## Tapered shaft with 20 shallow flutes that fade out at both ends.
static func _fluted_shaft(mesh: MESH, y0: float, y1: float, r0: float, r1: float, flute_depth: float) -> void:
	var flutes := 20
	var fractions: Array[float] = []
	for flute: int in flutes:
		for offset: float in [0.0, 0.14, 0.32, 0.5, 0.68, 0.86]:
			fractions.append((flute + offset) / flutes)
	var count := fractions.size()
	var heights: Array[float] = [y0, y0 + 0.12, y1 - 0.12, y1]
	var depths: Array[float] = [0.0, 1.0, 1.0, 0.0]
	var rows: Array[PackedVector3Array] = []
	var row_normals: Array[PackedVector3Array] = []
	for row: int in heights.size():
		var y := heights[row]
		var base := lerpf(r0, r1, (y - y0) / (y1 - y0))
		var points := PackedVector3Array()
		for f: float in fractions:
			var local := fposmod(f * flutes, 1.0)
			var groove := sin(PI * (local - 0.14) / 0.72) if local > 0.14 and local < 0.86 else 0.0
			var r := base - flute_depth * depths[row] * groove
			points.append(Vector3(sin(TAU * f) * r, y, cos(TAU * f) * r))
		var normals := PackedVector3Array()
		for i: int in count:
			var span := points[(i + 1) % count] - points[(i + count - 1) % count]
			var n := Vector3(span.z, 0.0, -span.x).normalized()
			if n.dot(Vector3(points[i].x, 0.0, points[i].z)) < 0.0:
				n = -n
			normals.append(n)
		rows.append(points)
		row_normals.append(normals)
	for row: int in heights.size() - 1:
		for i: int in count:
			var j := (i + 1) % count
			var a := rows[row][i]
			var b := rows[row][j]
			var c := rows[row + 1][j]
			var d := rows[row + 1][i]
			var outward := Vector3(a.x + b.x, 0.0, a.z + b.z)
			mesh.tri("column", a, b, c, outward, row_normals[row][i], row_normals[row][j], row_normals[row + 1][j])
			mesh.tri("column", a, c, d, outward, row_normals[row][i], row_normals[row + 1][j], row_normals[row + 1][i])

## Architrave, sill and keystone inside every window the shell cuts, on its storey's wall.
static func windows(parent: Node3D, mesh: MESH, layout: Dictionary) -> void:
	var body := STAIR.make_body("WindowSills")
	for window: Dictionary in layout.get("windows", []):
		var upper := is_upper(window, layout)
		var ceiling := float(layout.get("ceiling_y", 9.6)) if upper else float(layout.get("ground_ceiling_y", 4.55))
		_window(mesh, body, window, wall_radius(layout, upper), ceiling)
	parent.add_child(body)

## The opening's outline on the unrolled wall (s = metres along the wall from the window's
## angle, y = height), from the left jamb's foot over the arch to the right jamb's foot.
## `grow` offsets it outward. window.arch: "round" (default) or "pointed". The shell may cut
## its holes with this same outline so trim and opening agree.
static func outline(window: Dictionary, grow: float) -> PackedVector2Array:
	var half := float(window.get("width", 1.2)) * 0.5
	var height := float(window.get("height", 2.2))
	var bottom := float(window.get("y", 2.0)) - height * 0.5
	var points := PackedVector2Array([Vector2(-half - grow, bottom)])
	var spring := spring_height(window)
	if str(window.get("arch", "round")) == "pointed":
		var reach := half * 1.6
		var offset := reach - half
		var apex := acos(clampf(-offset / (reach + grow), -1.0, 1.0))
		for i: int in ARCH_SAMPLES + 1:
			var a := lerpf(PI, apex, float(i) / ARCH_SAMPLES)
			points.append(Vector2(offset + cos(a) * (reach + grow), spring + sin(a) * (reach + grow)))
		for i: int in range(1, ARCH_SAMPLES + 1):
			var a := lerpf(apex, PI, float(i) / ARCH_SAMPLES)
			points.append(Vector2(-offset - cos(a) * (reach + grow), spring + sin(a) * (reach + grow)))
	else:
		for i: int in 2 * ARCH_SAMPLES + 1:
			var a := lerpf(PI, 0.0, float(i) / (2 * ARCH_SAMPLES))
			points.append(Vector2(cos(a) * (half + grow), spring + sin(a) * (half + grow)))
	points.append(Vector2(half + grow, bottom))
	return points

## Height where the jambs turn into the arch.
static func spring_height(window: Dictionary) -> float:
	var half := float(window.get("width", 1.2)) * 0.5
	var top := float(window.get("y", 2.0)) + float(window.get("height", 2.2)) * 0.5
	if str(window.get("arch", "round")) == "pointed":
		var reach := half * 1.6
		return top - sqrt(reach * reach - (reach - half) * (reach - half))
	return top - half

static func _on_wall(point: Vector2, angle: float, radius: float, depth: float) -> Vector3:
	return STAIR.polar(radius - depth, angle + point.x / radius, point.y)

static func _window(mesh: MESH, body: StaticBody3D, window: Dictionary, radius: float, ceiling: float) -> void:
	var angle := deg_to_rad(float(window.get("angle", 0.0)))
	var height := float(window.get("height", 2.2))
	var bottom := float(window.get("y", 2.0)) - height * 0.5
	var spring := spring_height(window)
	var tangent := STAIR.along(angle)
	# The inner edge laps 2 cm over the opening and 6 cm into the reveal to hide small seams.
	var inner := outline(window, -0.02)
	var outer := outline(window, TRIM)
	for i: int in inner.size() - 1:
		var a := _on_wall(inner[i], angle, radius, TRIM_DEPTH)
		var b := _on_wall(inner[i + 1], angle, radius, TRIM_DEPTH)
		var c := _on_wall(outer[i + 1], angle, radius, TRIM_DEPTH)
		var d := _on_wall(outer[i], angle, radius, TRIM_DEPTH)
		var middle := (inner[i] + inner[i + 1]) * 0.5
		var into := Vector2(0.0, clampf(middle.y, bottom, spring)) - middle
		var towards := tangent * into.x + Vector3.UP * into.y
		mesh.quad("column", a, b, c, d, -STAIR.outward(angle + middle.x / radius))
		mesh.quad("column", _on_wall(inner[i], angle, radius, -0.06), _on_wall(inner[i + 1], angle, radius, -0.06), b, a, towards)
		mesh.quad("column", _on_wall(outer[i], angle, radius, 0.0), _on_wall(outer[i + 1], angle, radius, 0.0), c, d, -towards)
	var reach := float(window.get("width", 1.2)) * 0.5 + TRIM + 0.08
	_wall_slab(mesh, angle, radius, Vector2(-reach, reach), Vector2(bottom - 0.09, bottom), Vector2(0.0, 0.17))
	var apex := outline(window, 0.0)[ARCH_SAMPLES + 1].y
	var key_top := minf(apex + TRIM + 0.05, ceiling - 0.02)
	if key_top > apex + 0.05:
		_wall_slab(mesh, angle, radius, Vector2(-0.09, 0.09), Vector2(apex - 0.03, key_top), Vector2(0.0, 0.1))
	# Sill collision, so things set on it stay; a chord box is close enough on this curve.
	var shape := BoxShape3D.new()
	shape.size = Vector3(reach * 2.0, 0.09, 0.17)
	var basis := Basis(-tangent, Vector3.UP, -STAIR.outward(angle))
	STAIR.add_shape(body, shape, Transform3D(basis, STAIR.polar(radius - 0.085, angle, bottom - 0.045)))

## Curved block standing off the wall: s range, y range, depth range (x = back, y = front).
static func _wall_slab(mesh: MESH, angle: float, radius: float, span: Vector2, rise: Vector2, depth: Vector2) -> void:
	var count := maxi(1, ceili((span.y - span.x) / 0.12))
	for i: int in count:
		var a := lerpf(span.x, span.y, float(i) / count)
		var b := lerpf(span.x, span.y, float(i + 1) / count)
		var facing := -STAIR.outward(angle + (a + b) * 0.5 / radius)
		mesh.quad("column", _on_wall(Vector2(a, rise.x), angle, radius, depth.y), _on_wall(Vector2(b, rise.x), angle, radius, depth.y), _on_wall(Vector2(b, rise.y), angle, radius, depth.y), _on_wall(Vector2(a, rise.y), angle, radius, depth.y), facing)
		for level: float in [rise.x, rise.y]:
			mesh.quad("column", _on_wall(Vector2(a, level), angle, radius, depth.x), _on_wall(Vector2(b, level), angle, radius, depth.x), _on_wall(Vector2(b, level), angle, radius, depth.y), _on_wall(Vector2(a, level), angle, radius, depth.y), Vector3.UP if level > rise.x else Vector3.DOWN)
	for end: float in [span.x, span.y]:
		var side := STAIR.along(angle + end / radius) * signf(end)
		mesh.quad("column", _on_wall(Vector2(end, rise.x), angle, radius, depth.x), _on_wall(Vector2(end, rise.x), angle, radius, depth.y), _on_wall(Vector2(end, rise.y), angle, radius, depth.y), _on_wall(Vector2(end, rise.y), angle, radius, depth.x), side)

## The gold lightning-bolt pair over the inside of the front door, tips spreading downward.
static func door_bolts(mesh: MESH, layout: Dictionary) -> void:
	var radius := float(layout.get("radius", 4.2))
	var ground := float(layout.get("ground_y", 0.0))
	var door: Vector3 = layout.get("door_position", Vector3(0, ground, radius))
	var door_angle := atan2(door.x, door.z)
	var y := minf(ground + float(layout.get("door_height", 3.6)) + 0.42, float(layout.get("ground_ceiling_y", 4.55)) - 0.36)
	for side: float in [-1.0, 1.0]:
		# Increasing angle runs to the left of someone inside, so -along is their right.
		var angle := door_angle - side * 0.5 / radius
		# A window at the bolts' height pushes them out beside its trim.
		for window: Dictionary in layout.get("windows", []):
			var middle := float(window.get("y", 2.0))
			var height := float(window.get("height", 2.2))
			if is_upper(window, layout) or middle - height * 0.5 - 0.15 > y + 0.35 or middle + height * 0.5 + TRIM < y - 0.35:
				continue
			var centre := deg_to_rad(float(window.get("angle", 0.0)))
			var clear := (float(window.get("width", 1.2)) * 0.5 + TRIM + 0.3) / radius
			if absf(wrapf(angle - centre, -PI, PI)) < clear:
				angle = centre - side * clear
		var basis := Basis(-STAIR.along(angle), Vector3.UP, -STAIR.outward(angle))
		var shape := PackedVector2Array()
		for point: Vector2 in BOLT:
			var local := ((point - Vector2(0.39, 0.5)) * 0.62).rotated(deg_to_rad(50.0))
			shape.append(Vector2(local.x * side, local.y))
		mesh.extrude("brass", shape, Transform3D(basis, STAIR.polar(radius - 0.03, angle, y)), 0.05)

## Lounge rainbow as a painted strip on the hall wall, clear of the window openings, its ends
## tucked into small painted clouds. Skipped when the wall artwork already paints it.
static func rainbow(mesh: MESH, layout: Dictionary) -> void:
	var wall_paint := MATERIALS.get_material("wall")
	if wall_paint is ShaderMaterial:
		var painted: Variant = (wall_paint as ShaderMaterial).get_shader_parameter("rainbow_strength")
		if painted != null and float(painted) > 0.0:
			return
	var radius := float(layout.get("radius", 4.2))
	var ceiling := float(layout.get("ground_ceiling_y", 4.55))
	var zones: Dictionary = layout.get("zones", {})
	var lounge: Dictionary = zones.get("lounge", {})
	var from := deg_to_rad(float(lounge.get("from", 35.0)))
	var to := from + fposmod(deg_to_rad(float(lounge.get("to", 125.0))) - from, TAU)
	# Openings on the lounge wall (s along the wall, half width, bottom, top), measured from the
	# arc's centre: over the lowest window if there is one, else the zone's middle.
	var centre := (from + to) * 0.5
	var lowest := INF
	for window: Dictionary in layout.get("windows", []):
		var at := from + fposmod(deg_to_rad(float(window.get("angle", 0.0))) - from, TAU)
		var top := float(window.get("y", 2.0)) + float(window.get("height", 2.2)) * 0.5
		if at <= to and not is_upper(window, layout) and top < lowest:
			lowest = top
			centre = at
	var openings: Array[Vector4] = []
	for window: Dictionary in layout.get("windows", []):
		var at := from + fposmod(deg_to_rad(float(window.get("angle", 0.0))) - from, TAU)
		if at <= to + 0.3 and at >= from - 0.3 and not is_upper(window, layout):
			var height := float(window.get("height", 2.2))
			var middle := float(window.get("y", 2.0))
			openings.append(Vector4((at - centre) * radius, float(window.get("width", 1.2)) * 0.5 + TRIM + 0.1, middle - height * 0.5 - 0.2, middle + height * 0.5 + TRIM + 0.2))
	var widest := (minf(centre - from, to - centre) - deg_to_rad(4.0)) * radius
	var arc := _fit_rainbow(openings, widest, ceiling - 0.16)
	if arc == Vector3.ZERO:
		push_warning("Cloudominium rainbow: no clear arc between the lounge windows")
		return
	var reach := arc.x
	var outer := arc.y
	var middle := arc.z
	var paint := StandardMaterial3D.new()
	paint.vertex_color_use_as_albedo = true
	paint.vertex_color_is_srgb = true
	paint.roughness = 0.9
	mesh.use_material("rainbow_paint", paint)
	var samples := 40
	for band: int in RAINBOW.size():
		mesh.paint = RAINBOW[band]
		var big := outer - band * RAINBOW_BAND
		var small := big - RAINBOW_BAND
		for i: int in samples:
			var a := lerpf(-reach, reach, float(i) / samples)
			var b := lerpf(-reach, reach, float(i + 1) / samples)
			var corners: Array[Vector3] = []
			for p: Vector2 in [Vector2(a, big), Vector2(b, big), Vector2(b, small), Vector2(a, small)]:
				corners.append(_on_wall(Vector2(p.x, middle + sqrt(maxf(p.y * p.y - p.x * p.x, 0.0))), centre, radius, 0.02))
			mesh.quad("rainbow_paint", corners[0], corners[1], corners[2], corners[3], -STAIR.outward(centre + (a + b) * 0.5 / radius))
	mesh.paint = Color.WHITE
	var inner_end := outer - RAINBOW_BAND * RAINBOW.size()
	for end: float in [-1.0, 1.0]:
		var s := end * (reach - 0.05)
		var y := middle + (sqrt(maxf(outer * outer - s * s, 0.0)) + sqrt(maxf(inner_end * inner_end - s * s, 0.0))) * 0.5
		for puff: Vector4 in [Vector4(0, 0, 0.3, 0.22), Vector4(0.2, -0.1, 0.24, 0.17), Vector4(-0.18, -0.12, 0.22, 0.16), Vector4(0.05, 0.14, 0.2, 0.15)]:
			var at := Vector2(s + end * puff.x, y + puff.y)
			var angle := centre + at.x / radius
			var axes := Basis(STAIR.along(angle) * puff.z, Vector3.UP * puff.w, -STAIR.outward(angle) * 0.07)
			mesh.ellipsoid("cloud", _on_wall(at, centre, radius, 0.03), axes)

## Highest, widest bow (half reach, outer radius, circle centre height) whose six bands pass
## over or under every opening. Zero when none fits.
static func _fit_rainbow(openings: Array[Vector4], widest: float, highest: float) -> Vector3:
	var bands := RAINBOW_BAND * RAINBOW.size()
	var peak := highest
	while peak > 1.6:
		var reach := widest
		while reach >= 1.2:
			for drop: float in [0.95, 0.8, 0.65, 0.5]:
				var outer := (reach * reach + drop * drop) / (2.0 * drop)
				var inner := outer - bands
				var middle := peak - outer
				if inner <= reach:
					continue
				var fits := true
				for opening: Vector4 in openings:
					var near := clampf(0.0, opening.x - opening.y, opening.x + opening.y)
					var far := maxf(absf(opening.x - opening.y), absf(opening.x + opening.y))
					if absf(near) > reach:
						continue
					far = minf(far, reach)
					var under := middle + sqrt(outer * outer - near * near) < opening.z
					var over := middle + sqrt(inner * inner - far * far) > opening.w
					if not under and not over:
						fits = false
						break
				if fits:
					return Vector3(reach, outer, middle)
			reach -= 0.2
		peak -= 0.1
	return Vector3.ZERO

## Source ceiling fixtures: six under the upper floor, three upstairs, with
## a few bounded shadowless lights as in Golden Oak.
static func lights(parent:Node3D,_mesh:MESH,layout:Dictionary)->void:
	var radius:=float(layout.get("radius",4.2));var ground:=float(layout.get("ground_y",0))
	var under:=float(layout.get("ground_ceiling_y",4.55));var upper:=float(layout.get("upper_y",4.8));var ceiling:=float(layout.get("ceiling_y",9.6))
	var ring:=minf(1.9,radius*.45);var positions:Array[Vector3]=[]
	for i in 6:
		var at:=STAIR.polar(ring,deg_to_rad(30+60*i),under);positions.append(at)
		if i%2==0:_light(parent,at-Vector3.UP*.3,maxf(5.5,under-ground+1.2),1.0)
	for i in 3:positions.append(STAIR.polar(ring*.8,deg_to_rad(60+120*i),ceiling))
	preload("res://world/buildings/cloudominium/room_props.gd").ceiling_lamps(parent,positions)
	_light(parent,Vector3(0,lerpf(upper,ceiling,.62),0),maxf(5.5,ceiling-upper+1.5),1.0)

static func _light(parent: Node3D, at: Vector3, reach: float, energy: float) -> void:
	var light := OmniLight3D.new()
	light.name = "RecessedCloudLight"
	light.position = at
	light.light_color = Color("fff0d4")
	light.light_energy = energy
	light.omni_range = reach
	light.omni_attenuation = 0.7
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 25.0
	light.distance_fade_length = 10.0
	parent.add_child(light)
