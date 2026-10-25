extends RefCounted
## occupancy grid extracted from interior_furnisher.gd.
## State and callback dispatch stay on the owning instance; authored transforms and order are unchanged.

const CELL := 0.1
const FLOOR := 1
const SOLID := 2
const LANE := 4
const CLEAR := 8
const RUG := 16
const TALL := 32
const LANE_RADIUS := 0.45
const BED_SIZE := Vector3(2.05, 1.1, 2.1)


static func _build_grid(context: RefCounted) -> void:
	# Packed arrays use copy-on-write; publish mutations back to their owner.
	var flags: PackedByteArray = context.flags
	var clear_owner: PackedInt32Array = context.clear_owner
	var bounds := (context.rooms as Array[Rect2])[0]
	for r in (context.rooms as Array[Rect2]): bounds = bounds.merge(r)
	bounds = bounds.grow(0.5)
	context.origin = bounds.position
	context.nx = ceili(bounds.size.x / CELL)
	context.nz = ceili(bounds.size.y / CELL)
	flags.resize((context.nx as int) * (context.nz as int))
	flags.fill(0)
	clear_owner.resize((context.nx as int) * (context.nz as int))
	clear_owner.fill(-1)
	for j in (context.nz as int):
		for i in (context.nx as int):
			var c := (context._centre(i, j) as Vector2)
			for r in (context.rooms as Array[Rect2]):
				if r.has_point(c): flags[j * (context.nx as int) + i] = FLOOR; break
	context.flags = flags
	context.clear_owner = clear_owner

static func _cell(context: RefCounted, p: Vector2) -> Vector2i:
	return Vector2i(floori((p.x - (context.origin as Vector2).x) / CELL), floori((p.y - (context.origin as Vector2).y) / CELL))

static func _centre(context: RefCounted, i: int, j: int) -> Vector2:
	return (context.origin as Vector2) + Vector2(i + 0.5, j + 0.5) * CELL

static func _cells(context: RefCounted, c: Vector2, yaw: float, hx: float, hz: float) -> PackedInt32Array:
	var r := (context._right(yaw) as Vector2)
	var f := (context._front(yaw) as Vector2)
	var ex := absf(r.x) * hx + absf(f.x) * hz
	var ez := absf(r.y) * hx + absf(f.y) * hz
	var a := (context._cell(c - Vector2(ex, ez)) as Vector2i)
	var b := (context._cell(c + Vector2(ex, ez)) as Vector2i)
	if a.x < 0 or a.y < 0 or b.x >= (context.nx as int) or b.y >= (context.nz as int): return PackedInt32Array([-1])
	var out := PackedInt32Array()
	for j in range(a.y, b.y + 1):
		for i in range(a.x, b.x + 1):
			var d := (context._centre(i, j) as Vector2) - c
			if absf(d.dot(r)) <= hx and absf(d.dot(f)) <= hz: out.append(j * (context.nx as int) + i)
	return out

static func _solid_ok(context: RefCounted, cells: PackedInt32Array, allow_clear_of := -1) -> bool:
	if cells.is_empty() or cells[0] < 0: return false
	for k in cells:
		var f := (context.flags as PackedByteArray)[k]
		if f & FLOOR == 0 or f & (SOLID | LANE) != 0: return false
		if f & CLEAR != 0 and (context.clear_owner as PackedInt32Array)[k] != allow_clear_of: return false
	return true

static func _open_ok(context: RefCounted, cells: PackedInt32Array) -> bool:
	if cells.is_empty(): return true
	if cells[0] < 0: return false
	for k in cells:
		if (context.flags as PackedByteArray)[k] & FLOOR == 0 or (context.flags as PackedByteArray)[k] & SOLID != 0: return false
	return true

static func _flat_ok(context: RefCounted, cells: PackedInt32Array, no_lane: bool) -> bool:
	if cells.is_empty() or cells[0] < 0: return false
	var bad := SOLID | RUG | (LANE if no_lane else 0)
	for k in cells:
		if (context.flags as PackedByteArray)[k] & FLOOR == 0 or (context.flags as PackedByteArray)[k] & bad != 0: return false
	return true

static func _mark(context: RefCounted, cells: PackedInt32Array, bit: int, who := -1) -> void:
	# Packed arrays use copy-on-write; publish mutations back to their owner.
	var flags: PackedByteArray = context.flags
	var clear_owner: PackedInt32Array = context.clear_owner
	for k in cells:
		if k < 0: continue
		flags[k] |= bit
		if bit == CLEAR and clear_owner[k] != -2: clear_owner[k] = who
	context.flags = flags
	context.clear_owner = clear_owner

static func _sat(context: RefCounted, mask: int) -> PackedInt32Array:
	var w := (context.nx as int) + 1
	var sat := PackedInt32Array()
	sat.resize(w * ((context.nz as int) + 1))
	for j in (context.nz as int):
		var row := 0
		var base := j * (context.nx as int)
		var here := (j + 1) * w
		var above := j * w
		for i in (context.nx as int):
			var f := (context.flags as PackedByteArray)[base + i]
			if f & FLOOR == 0 or f & mask != 0: row += 1
			sat[here + i + 1] = sat[above + i + 1] + row
	return sat

static func _box_clean(context: RefCounted, sat: PackedInt32Array, c: Vector2, ex: float, ez: float) -> bool:
	var i0 := ceili((c.x - ex - (context.origin as Vector2).x) / CELL - 0.5)
	var i1 := floori((c.x + ex - (context.origin as Vector2).x) / CELL - 0.5)
	var j0 := ceili((c.y - ez - (context.origin as Vector2).y) / CELL - 0.5)
	var j1 := floori((c.y + ez - (context.origin as Vector2).y) / CELL - 0.5)
	if i0 < 0 or j0 < 0 or i1 >= (context.nx as int) or j1 >= (context.nz as int): return false
	if i1 < i0 or j1 < j0: return true
	var w := (context.nx as int) + 1
	return sat[(j1 + 1) * w + i1 + 1] - sat[j0 * w + i1 + 1] - sat[(j1 + 1) * w + i0] + sat[j0 * w + i0] == 0

static func _backed(context: RefCounted, c: Vector2, yaw: float, w: float, d: float) -> bool:
	var strip := (context._cells(c - (context._front(yaw) as Vector2) * (d * 0.5 + 0.12), yaw, w * 0.4, 0.05) as PackedInt32Array)
	if strip.is_empty() or strip[0] < 0: return true
	var on := 0
	for k in strip: if (context.flags as PackedByteArray)[k] & FLOOR: on += 1
	return on <= strip.size() / 5

static func _corner(context: RefCounted, c: Vector2, yaw: float, w: float, d: float) -> int:
	for sgn in [1, -1]:
		var strip := (context._cells(c + (context._right(yaw) as Vector2) * sgn * (w * 0.5 + 0.12), yaw, 0.05, d * 0.4) as PackedInt32Array)
		if strip.is_empty() or strip[0] < 0: return sgn
		var on := 0
		for k in strip: if (context.flags as PackedByteArray)[k] & FLOOR: on += 1
		if on <= strip.size() / 5: return sgn
	return 0

static func _mark_beds(context: RefCounted) -> void:
	var list: Array = []
	if is_instance_valid((context.home as Node3D).bed): list.append((context.home as Node3D).bed)
	for extra in (context.home as Node3D)._extra_beds: if is_instance_valid(extra): list.append(extra)
	var inv := (context.home as Node3D).global_basis.orthonormalized().inverse()
	for bed: Node3D in list:
		var pos := (context._plan_world(bed.global_position) as Vector2)
		var yaw := (inv * bed.global_basis.orthonormalized()).get_euler().y
		var side: Vector3 = bed.get_meta("side_local", Vector3(0, 0, BED_SIZE.z * 0.5 + 0.6))
		var entry := {"pos": pos, "yaw": yaw, "room": (context._room_of(pos) as int), "side_sign": signf(side.x),
			"side": (context._plan_world(bed.global_transform * side) as Vector2)}
		(context.beds as Array).append(entry)
		context._mark((context._cells(pos, yaw, BED_SIZE.x * 0.5 + 0.05, BED_SIZE.z * 0.5 + 0.05) as PackedInt32Array), SOLID | TALL)

static func _mark_lanes(context: RefCounted) -> void:
	var centres: Array[Vector2] = []
	for r: Rect2 in (context.home as Node3D).floors: centres.append((context._plan(Vector3(r.get_center().x, 0, r.get_center().y)) as Vector2))
	var segs: Array = [[(context.door_pt as Vector2), (context.door_in as Vector2)], [(context.door_in as Vector2), centres[0]]]
	var links: Array[Vector2] = [centres[0]]
	if (context.home as Node3D).floors.size() >= 2:
		if not (context.home as Node3D)._passage_done: (context.home as Node3D)._measure_passage()
		# HouseInterior.local_waypoint goes through the measured opening, else round the L corner.
		var main: Rect2 = (context.home as Node3D).floors[0]
		var wing: Rect2 = (context.home as Node3D).floors[1]
		var via := (context._plan(Vector3(wing.get_center().x, 0, main.end.y - 0.09)) as Vector2)
		if (context.home as Node3D)._passage.is_finite() and not (context.home as Node3D)._passage_open_all: via = (context._plan((context.home as Node3D)._passage) as Vector2)
		segs.append([centres[0], via]); segs.append([via, centres[1]]); segs.append([(context.door_in as Vector2), via])
		links.append(via)
	for b: Dictionary in (context.beds as Array):
		segs.append([(context.door_in as Vector2), b.side])
		for c in links: segs.append([c, b.side])
		# The direct line to a long-side exit can cross the bed itself. Reserve
		# the usable way around its foot too, so a kitchen cannot seal that aisle.
		var front: Vector2 = (context._front(b.yaw) as Vector2)
		var side: Vector2 = b.side
		var foot: Vector2 = side + front * maxf(0.0, BED_SIZE.z * .5 + .6 - (side - (b.pos as Vector2)).dot(front))
		segs.append([foot, side])
		for c: Vector2 in links: segs.append([c, foot])
	for seg: Array in segs: context._lane(seg[0], seg[1], LANE_RADIUS)
	context._lane(centres[0], centres[0], 0.8)
	context._lane((context.door_in as Vector2), (context.door_in as Vector2), 0.8)

static func _lane(context: RefCounted, a: Vector2, b: Vector2, radius: float) -> void:
	# Packed arrays use copy-on-write; publish mutations back to their owner.
	var flags: PackedByteArray = context.flags
	var lo := (context._cell(Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2.ONE * radius) as Vector2i)
	var hi := (context._cell(Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2.ONE * radius) as Vector2i)
	for j in range(maxi(lo.y, 0), mini(hi.y, (context.nz as int) - 1) + 1):
		for i in range(maxi(lo.x, 0), mini(hi.x, (context.nx as int) - 1) + 1):
			var p := (context._centre(i, j) as Vector2)
			var ab := b - a
			var t := 0.0 if ab.length_squared() < 1e-6 else clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
			if p.distance_to(a + ab * t) <= radius: flags[j * (context.nx as int) + i] |= LANE
	context.flags = flags

static func debug_image(context: RefCounted) -> Image:
	var img := Image.create((context.nx as int), (context.nz as int), false, Image.FORMAT_RGB8)
	for j in (context.nz as int):
		for i in (context.nx as int):
			var f := (context.flags as PackedByteArray)[j * (context.nx as int) + i]
			var col := Color(0.15, 0.15, 0.17)
			if f & FLOOR: col = Color(0.93, 0.89, 0.8)
			if f & LANE: col = col.lerp(Color(0.45, 0.65, 0.95), 0.55)
			if f & CLEAR: col = col.lerp(Color(0.95, 0.85, 0.3), 0.5)
			if f & RUG: col = Color(0.9, 0.6, 0.7)
			if f & SOLID: col = Color(0.55, 0.38, 0.22) if f & TALL == 0 else Color(0.3, 0.2, 0.12)
			img.set_pixel(i, j, col)
	for w: Dictionary in (context.windows as Array):
		var k := (context._cell(w.edge) as Vector2i)
		for d in range(-int(w.half / CELL), int(w.half / CELL) + 1):
			var t := Vector2i(int(-w.n.y * d), int(w.n.x * d))
			var q := k + t
			if q.x >= 0 and q.y >= 0 and q.x < (context.nx as int) and q.y < (context.nz as int): img.set_pixel(q.x, q.y, Color(0.2, 0.8, 0.9))
	return img

