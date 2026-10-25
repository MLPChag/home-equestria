extends RefCounted
const FURNITURE_ASSETS := preload("res://world/interiors/furniture_assets.gd")
const FURNISH_STYLE := preload("res://world/interiors/furnish_style.gd")
const OCCUPANCY_GRID := preload("res://world/interiors/occupancy_grid.gd")
const FURNISH_CANDIDATES := preload("res://world/interiors/furnish_candidates.gd")
const FURNISH_SURFACES := preload("res://world/interiors/furnish_surfaces.gd")
const FURNISH_LAMPS := preload("res://world/interiors/furnish_lamps.gd")
## Seeded house interiors (dev 2026-09-26: "a skyrim dungeon system type deal that makes
## believable and proper nice house layouts that are slightly different for each house").
##
## The kit (world/interiors/interior_kit.json) says what each prop is and how it may stand; the
## recipes say which props make a kitchen, a living room, a bedroom or a nook, in what order and
## how likely each is. This solver does the placing, seeded by the house's place_id, so a house
## always gets the same layout and no two houses of a design match exactly.
##
## Work happens in "plan" space: house-local x/z times the house scale, i.e. metres. An occupancy
## grid (10 cm cells) tracks the floor, placed props, the lanes ponies walk indoors (door, room
## centres, the passage between rooms, bed sides; they path in straight lines there, see
## HouseInterior.local_waypoint) and the space in front of props. Each candidate passes the grid
## first, then a physics box test against the real shell (walls are not quite where the floor
## rects say; round walls, windows, doors, beds), and wall pieces are pushed flush to the wall.

const KIT_PATH := "res://world/interiors/interior_kit.json"
const MANIFEST_PATH := "res://world/props/household/manifest.json"
const PROP_DIR := "res://world/props/household/"
const CELL := 0.1
const FLOOR := 1
const SOLID := 2
const LANE := 4
const CLEAR := 8
const RUG := 16
const TALL := 32
const LANE_RADIUS := 0.45
const GAP := 0.03
const TALL_M := 1.35
const BED_SIZE := Vector3(2.05, 1.1, 2.1)
const VISIBLE_M := 40.0

static var _kit: Dictionary:
	get: return FURNITURE_ASSETS._kit
	set(value): FURNITURE_ASSETS._kit = value
static var _sizes: Dictionary:
	get: return FURNITURE_ASSETS._sizes
	set(value): FURNITURE_ASSETS._sizes = value
static var _scenes: Dictionary:
	get: return FURNITURE_ASSETS._scenes
	set(value): FURNITURE_ASSETS._scenes = value
static var _boxes: Dictionary:
	get: return FURNITURE_ASSETS._boxes
	set(value): FURNITURE_ASSETS._boxes = value

var home: Node3D
var s := 1.0
var rng := RandomNumberGenerator.new()
var space: PhysicsDirectSpaceState3D
var origin := Vector2.ZERO
var nx := 0
var nz := 0
var flags := PackedByteArray()
var clear_owner := PackedInt32Array()  # which placed prop's clearance a CLEAR cell belongs to
var rooms: Array[Rect2] = []        # plan metres
var tops: Array[float] = []         # floor top per room, house-local units
var areas: Array = []               # {rect, room, role, beds:Array, placed:{}}
var windows: Array = []             # {c, n, half, sill, top, room, edge, frame, curtain}
var beds: Array = []                # {pos, yaw, right, front, side_sign, room}
var door_pt := Vector2.ZERO
var door_in := Vector2.ZERO
var placed: Array = []              # {id, pos, yaw, size, area, index, faces, scale}
var report := PackedStringArray()
var spawn_ms := 0.0
var _wall_triangles: Array[Dictionary] = []
var _door_clearance := Rect2()
## Plan outlines of the door leaf swinging shut to open (furnish_surfaces.gd _door_sweep).
var _door_sweep: Array[PackedVector2Array] = []
## The inside door handle, in plan metres: nothing may stand within HANDLE_KEEPOUT of it (the door
## survey of 2026-09-30 found house A's icebox against its inside handle, blocking the grip).
var _handle_plan := Vector2.INF
const HANDLE_KEEPOUT := 0.75


static func load_kit() -> void:
	FURNITURE_ASSETS.load_kit()
	FURNISH_LAMPS.register()

static func _model(id: String) -> String:
	return FURNITURE_ASSETS._model(id)

## Lays out and spawns the furniture of one HouseInterior. A coroutine: it works at most
## SLICE_US per frame, so a town full of houses furnishes over a few seconds without hitches.
## Returns the placements (empty if the house left the tree meanwhile).
func furnish(target: Node3D) -> Array:
	load_kit()
	home = target
	_gen = home.furnish_gen
	_slice_start = Time.get_ticks_usec()
	s = maxf(home.global_basis.get_scale().x, 0.001)
	space = home.get_world_3d().direct_space_state
	rng.seed = hash("interior:" + str(home.place_id()))
	_pick_style()
	var t0 := Time.get_ticks_usec()
	_read_house()
	_build_grid()
	_mark_beds()
	_mark_lanes()
	_assign_roles()
	await _slice()
	if not _alive(): return []
	await _reserve_kitchen()
	if _alive() and bool(home.get_meta("welcome_table_required", false)):
		await _reserve_welcome_table()
	await _run("house", null, ["doormat"])
	for role: String in ["bedroom", "kitchen", "living_kitchen", "living", "nook"]:
		for area: Dictionary in areas:
			if area.role == role and _alive(): await _run(role, area)
	# Lamps after the furniture they stand by or on, before curtains (dev 2026-10-14).
	if _alive(): await FURNISH_LAMPS.run(self)
	if _alive(): await _run("house", null, ["curtains"])
	if not _alive(): return []
	var t1 := Time.get_ticks_usec()
	# Whatever an earlier run left goes before this layout appears.
	for node in home.get_children():
		if node.is_in_group("house_furniture") or node.is_in_group("house_activity_spots"):
			home.remove_child(node)
			node.queue_free()
	for p: Dictionary in placed:
		_spawn(p)
	FURNISH_LAMPS.spawn_outdoor(self)
	if is_instance_valid(home.bed): _dress_bed(home.bed)
	for extra in home._extra_beds:
		if is_instance_valid(extra): _dress_bed(extra)
	spawn_ms = (Time.get_ticks_usec() - t1) / 1000.0
	if not debug_hits.is_empty(): report.append("  shell hits: " + ", ".join(debug_hits))
	var roles := []
	for area: Dictionary in areas: roles.append(area.role)
	report.insert(0, "[interior] %s %s %s (%s wood, %s) roles %s, %d props, %.1f ms of work over %d frames" % [home.label(), str(home.get_parent().scene_file_path).get_file(), style_name, finish_name, palette_name, roles, placed.size(), _work_us / 1000.0 + (Time.get_ticks_usec() - _slice_start) / 1000.0, _frames + 1])
	return placed

const SLICE_US := 4000
signal slice_resumed
var _slice_start := 0
var _work_us := 0
var _frames := 0
var _cancelled := false
func _slice() -> void:
	if not _alive(): return
	var used := Time.get_ticks_usec() - _slice_start
	if used < SLICE_US: return
	_work_us += used
	_frames += 1
	# The final scene teardown has no following process_frame. Wake the coroutine
	# on house removal too, releasing its RefCounted stack before the tree dies.
	var tree := home.get_tree()
	tree.process_frame.connect(_resume_slice, CONNECT_ONE_SHOT)
	home.tree_exiting.connect(_cancel_slice, CONNECT_ONE_SHOT)
	await slice_resumed
	if is_instance_valid(tree) and tree.process_frame.is_connected(_resume_slice):
		tree.process_frame.disconnect(_resume_slice)
	if is_instance_valid(home) and home.tree_exiting.is_connected(_cancel_slice):
		home.tree_exiting.disconnect(_cancel_slice)
	_slice_start = Time.get_ticks_usec()

func _resume_slice() -> void:
	slice_resumed.emit()

func _cancel_slice() -> void:
	_cancelled = true
	slice_resumed.emit()

var _gen := -1
## Still this house's newest furnishing run (a restart makes an older run stop, not spawn).
func _alive() -> bool: return not _cancelled and is_instance_valid(home) and home.is_inside_tree() and home.furnish_gen == _gen


# --- style ------------------------------------------------------------------------------------

var style := {}          # the kit style this house drew
var style_name := ""
var finish := {}         # wood finish: {color, contrast, roughness} or {keep}
var finish_name := ""
var palette := {}        # {fabric, linen}
var palette_name := ""

## One style and accent family per house. Large fabrics use neutral supporting
## colours; small upholstery and blankets carry the accent instead of tinting everything.
func _pick_style() -> void:
	FURNISH_STYLE._pick_style(self)

func _chance(id: String, step: Dictionary) -> float:
	return FURNISH_STYLE._chance(self, id, step)

static var _materials := {}   # "model|finish|palette" -> ShaderMaterial, shared by every house alike
const FURNITURE_SHADER := preload("res://world/interiors/furniture.gdshader")
const SHELF_BOOKS := preload("res://world/books/shelf_books.gd")

func _fabric_colour(model: String) -> Color:
	return FURNISH_STYLE._fabric_colour(self, model)

func _linen_colour() -> Color:
	return FURNISH_STYLE._linen_colour(self)

func _material(model: String, source: Material) -> Material:
	return FURNISH_STYLE._material(self, model, source)

## Bed sheets stay neutral; the blanket carries the house accent.
func _dress_bed(bed: Node3D) -> void:
	FURNISH_STYLE._dress_bed(self, bed)

# --- house facts -----------------------------------------------------------------------------

func _plan(local: Vector3) -> Vector2: return Vector2(local.x, local.z) * s
func _plan_world(world: Vector3) -> Vector2: return _plan(home.to_local(world))
func _world(p: Vector2, room: int, lift := 0.0) -> Vector3:
	return home.to_global(Vector3(p.x / s, _top(room), p.y / s)) + Vector3.UP * lift
func _top(room: int) -> float: return tops[room] if room >= 0 and room < tops.size() else home.floor_y
func _yaw_basis(yaw: float) -> Basis: return home.global_basis.orthonormalized() * Basis(Vector3.UP, yaw)
static func _front(yaw: float) -> Vector2: return Vector2(sin(yaw), cos(yaw))
static func _right(yaw: float) -> Vector2: return Vector2(cos(yaw), -sin(yaw))
static func _yaw_of(front: Vector2) -> float: return atan2(front.x, front.y)

func _read_house() -> void:
	FURNISH_SURFACES._read_house(self)

# Plain bounds only: no retained scene nodes, meshes, or references back to the home.
static var _window_bounds: Dictionary:
	get: return FURNITURE_ASSETS._window_bounds
	set(value): FURNITURE_ASSETS._window_bounds = value

static func _source_windows(house: Node3D) -> Array[Dictionary]:
	return FURNITURE_ASSETS._source_windows(house)

## The same uniform scale and bottom-centre anchor used by _spawn, not the
## rounded dimensions in the manifest (which are only the requested size).
static func _visible_size(id: String) -> Vector3:
	return FURNITURE_ASSETS._visible_size(id)

func _curtain_layout(w: Dictionary) -> Dictionary:
	return FURNISH_SURFACES._curtain_layout(self, w)

## Hung decoration must clear the complete window and the potential curtain
## envelope, including its rod and tied-back fabric, before chance picks curtains.
func _decoration_blocks_window(c: Vector2, yaw: float, size: Vector3, room: int, lift: float) -> bool:
	return FURNISH_SURFACES._decoration_blocks_window(self, c, yaw, size, room, lift)

func _nearest_room(p: Vector2, reach: float) -> int:
	var best := -1
	var best_d := reach
	for i in rooms.size():
		var r := rooms[i]
		var q := Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
		var d := q.distance_to(p)
		if d <= best_d: best_d = d; best = i
	return best

func _room_of(p: Vector2) -> int:
	for i in rooms.size():
		if rooms[i].grow(0.01).has_point(p): return i
	return -1


# --- occupancy grid --------------------------------------------------------------------------

func _build_grid() -> void:
	OCCUPANCY_GRID._build_grid(self)

func _cell(p: Vector2) -> Vector2i:
	return OCCUPANCY_GRID._cell(self, p)

func _centre(i: int, j: int) -> Vector2:
	return OCCUPANCY_GRID._centre(self, i, j)

## Cells whose centres fall inside the rectangle (centre c, heading yaw, half sizes hx along the
## prop's width and hz along its depth). [-1] when it leaves the grid.
func _cells(c: Vector2, yaw: float, hx: float, hz: float) -> PackedInt32Array:
	return OCCUPANCY_GRID._cells(self, c, yaw, hx, hz)

func _solid_ok(cells: PackedInt32Array, allow_clear_of := -1) -> bool:
	return OCCUPANCY_GRID._solid_ok(self, cells, allow_clear_of)

## Room to stand or walk: on the floor, nothing solid.
func _open_ok(cells: PackedInt32Array) -> bool:
	return OCCUPANCY_GRID._open_ok(self, cells)

func _flat_ok(cells: PackedInt32Array, no_lane: bool) -> bool:
	return OCCUPANCY_GRID._flat_ok(self, cells, no_lane)

func _mark(cells: PackedInt32Array, bit: int, who := -1) -> void:
	OCCUPANCY_GRID._mark(self, cells, bit, who)

## Summed-area table of cells that are off the floor or carry any bit of `mask`: any
## axis-aligned box can then be tested in four lookups (free-standing searches try thousands).
func _sat(mask: int) -> PackedInt32Array:
	return OCCUPANCY_GRID._sat(self, mask)

## No bad cell centre inside the axis-aligned box (centre c, half extents ex, ez).
func _box_clean(sat: PackedInt32Array, c: Vector2, ex: float, ez: float) -> bool:
	return OCCUPANCY_GRID._box_clean(self, sat, c, ex, ez)

## A wall stands right behind the prop: the strip behind its back is (almost) off the floor.
func _backed(c: Vector2, yaw: float, w: float, d: float) -> bool:
	return OCCUPANCY_GRID._backed(self, c, yaw, w, d)

## Which side (+1 right, -1 left, 0 none) has a wall right beside the prop.
func _corner(c: Vector2, yaw: float, w: float, d: float) -> int:
	return OCCUPANCY_GRID._corner(self, c, yaw, w, d)

func _mark_beds() -> void:
	OCCUPANCY_GRID._mark_beds(self)

## Keep the straight lines ponies walk indoors free: door to the room centre (and its rest
## slots), door and centre to every bed side, and room to room through the passage.
func _mark_lanes() -> void:
	OCCUPANCY_GRID._mark_lanes(self)

func _lane(a: Vector2, b: Vector2, radius: float) -> void:
	OCCUPANCY_GRID._lane(self, a, b, radius)

# --- rooms and roles -------------------------------------------------------------------------

## Split big rooms into two areas along their long side; the areas holding beds are bedrooms,
## the rest become kitchen / living room / nook (or one living-kitchen when only one is left).
func _assign_roles() -> void:
	var big := 0
	for r in rooms: if minf(r.size.x, r.size.y) >= 1.6: big += 1
	for i in rooms.size():
		var r := rooms[i]
		if minf(r.size.x, r.size.y) < 1.6: continue
		var long := maxf(r.size.x, r.size.y)
		var parts: Array[Rect2] = [r]
		if long >= 7.0 or (big == 1 and long >= 5.0):
			if r.size.x >= r.size.y: parts = [Rect2(r.position, Vector2(r.size.x * 0.5, r.size.y)), Rect2(r.position + Vector2(r.size.x * 0.5, 0), Vector2(r.size.x * 0.5, r.size.y))]
			else: parts = [Rect2(r.position, Vector2(r.size.x, r.size.y * 0.5)), Rect2(r.position + Vector2(0, r.size.y * 0.5), Vector2(r.size.x, r.size.y * 0.5))]
		for part in parts: areas.append({"rect": part, "room": i, "role": "", "beds": [], "placed": {}})
	# Each bed belongs to one area: the one holding its centre, else the nearest.
	for b: Dictionary in beds:
		var best: Dictionary = {}
		var best_d := INF
		for area: Dictionary in areas:
			var r: Rect2 = area.rect
			var q := Vector2(clampf(b.pos.x, r.position.x, r.end.x), clampf(b.pos.y, r.position.y, r.end.y))
			var d := q.distance_to(b.pos)
			if d < best_d: best_d = d; best = area
		if not best.is_empty(): best.beds.append(b)
	var free: Array = []
	for area: Dictionary in areas:
		if area.beds.is_empty(): free.append(area)
		else: area.role = "bedroom"
	# Seeded order, larger areas first for the kitchen: the island needs its aisle.
	_shuffle(free)
	var largest := 0
	for k in free.size():
		if free[k].rect.get_area() > free[largest].rect.get_area(): largest = k
	if not free.is_empty() and free[largest].rect.get_area() > free[0].rect.get_area() + 6.0:
		var tmp = free[0]; free[0] = free[largest]; free[largest] = tmp
	if free.size() == 1: free[0].role = "living_kitchen"
	elif free.size() >= 2:
		free[0].role = "kitchen"; free[1].role = "living"
		for k in range(2, free.size()): free[k].role = "nook"

func _shuffle(list: Array) -> void:
	for i in range(list.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = list[i]; list[i] = list[j]; list[j] = tmp


# --- recipes ---------------------------------------------------------------------------------

## A cooking/sink counter is essential. Reserve it before wardrobes, sofas and rugs.
## Search assigned kitchen areas first, then real room perimeters: an arbitrary area split
## must not prevent using a clear wall in a shared studio. Beds and walking lanes stay fixed.
func _reserve_kitchen() -> void:
	var preferred: Array = []
	for area: Dictionary in areas:
		if area.role in ["kitchen", "living_kitchen"]: preferred.append(area)
	for area: Dictionary in preferred:
		if _place(area, "kitchen-island", "wall", {"essential": true}): return
	for room in rooms.size():
		await _slice()
		if not _alive(): return
		var whole: Dictionary = {"rect": rooms[room], "room": room, "role": "kitchen", "beds": [], "placed": {}}
		if _place(whole, "kitchen-island", "wall", {"essential": true}):
			var entry: Dictionary = placed[-1]
			for area: Dictionary in areas:
				if area.room == room and area.rect.has_point(entry.pos):
					area.placed["kitchen-island"] = entry
			return
	# Purpose-built kitchenette keeps full counter height, with a smaller footprint.
	# Do not shrink appliances or relax bed, wall, window and walking clearance checks.
	for room in rooms.size():
		await _slice()
		if not _alive(): return
		var whole: Dictionary = {"rect": rooms[room], "room": room, "role": "kitchen", "beds": [], "placed": {}}
		if _place(whole, "compact-kitchen", "wall", {"essential": true}): return
	report.append("  MISSING ESSENTIAL: no safe kitchen counter placement")

## Only the starter home requests this surface. Use normal floor/door/lane/physics
## placement, before optional clutter. A private area keeps recipe tea sets off it.
func _reserve_welcome_table() -> void:
	for rule: String in ["open", "wall"]:
		for room in rooms.size():
			await _slice()
			if not _alive(): return
			var whole: Dictionary = {"rect": rooms[room], "room": room, "role": "welcome", "beds": [], "placed": {}}
			if _place(whole, "coffee-table", rule, {"essential": true}):
				placed[-1]["welcome_table"] = true
				return
	report.append("  MISSING ESSENTIAL: no safe welcome table placement")

func _run(role: String, area, only: Array = []) -> void:
	var steps: Array = _kit.recipes[role] + style.get("extra", {}).get(role, [])
	for step: Dictionary in steps:
		await _slice()
		if not _alive(): return
		var id: String = step.prop
		if id == "kitchen-island": continue # Essential counter was reserved before decoration.
		if not only.is_empty() and not only.has(id): continue
		if not _sizes.has(id): continue
		var chance := _chance(id, step)
		if step.rule == "curtains": _curtains(style.get("curtains", chance)); continue
		if step.rule == "hang":
			if rng.randf() <= chance: _hang_wall(area, id)
			continue
		if step.rule in ["bedside", "bedrug", "bedfoot"]:
			for b: Dictionary in area.beds:
				if rng.randf() <= chance: _place(area, id, step.rule, step, b)
			continue
		if rng.randf() > chance: continue
		if not _place(area, id, step.rule, step) and step.has("else"): _place(area, id, step["else"], step)

func _place(area, id: String, rule: String, step: Dictionary, bed = null) -> bool:
	var spec: Dictionary = _kit.props.get(id, {})
	var size: Vector3 = _sizes[id]
	var cands: Array = []
	match rule:
		"wall": cands = _wall_candidates(area, id, size, spec, step)
		"island": cands = _island_candidates(area, size, spec)
		"face": cands = _face_candidates(area, size, spec, step)
		"front": cands = _front_candidates(area, size, step)
		"flank": cands = _flank_candidates(area, size, step)
		"between": cands = _between_candidates(area, size, step)
		"bedside": cands = _bedside_candidates(size, bed)
		"bedrug": cands = _bedrug_candidates(size, bed)
		"bedfoot": cands = _bedfoot_candidates(size, bed)
		"on": cands = _on_candidates(area, id, step)
		"under_window": cands = _window_floor_candidates(area, size, spec)
		"open": cands = _open_candidates(area, size, spec, false)
		"open_flat": cands = _open_candidates(area, size, spec, true)
		"door": cands = _door_candidates(size)
	var found := cands.size()
	# Prefer a couch that can actually unfold. Check again after wall snugging;
	# ordinary seats remain possible in rooms too small for a sleeping couch.
	if id == "sofa":
		for candidate: Dictionary in cands:
			if _couch_space(candidate.pos, candidate.yaw, area.room, false): candidate.weight *= 20.0
	var misses := [0, 0, 0]   # no wall behind, grid after snug, physics
	var tries := 0
	var max_tries: int = cands.size() if step.get("essential", false) else 24
	while not cands.is_empty() and tries < max_tries:
		tries += 1
		var pick := _pick(cands)
		var c: Dictionary = cands[pick]
		cands.remove_at(pick)
		var room: int = area.room if area != null else _room_of(c.pos)
		if room < 0: room = _nearest_room(c.pos, 1.0)
		if not spec.get("flat", false) and not spec.get("decor", false):
			if c.get("snug", false):
				var fitted = _snug(c.pos, c.yaw, size, room)
				if fitted == null: misses[0] += 1; continue
				# Pushing it to the real wall moved it: the grid must still agree.
				if not _solid_ok(_cells(fitted, c.yaw, size.x * 0.5, size.z * 0.5), c.get("allow", -1)):
					if not step.get("essential", false) or not _supported_edge(fitted, c.yaw, size, room):
						misses[1] += 1
						continue
				# dev 2026-09-26: cupboards stood in the middle of houses, backed onto the opening
				# between two rooms (the floor rects leave a gap there, so the grid saw "no floor
				# behind" and the cast met a wall stub). The whole back must be against a wall.
				if not _wall_behind(fitted, c.yaw, size, room): misses[0] += 1; continue
				c.pos = fitted
			if _blocks_handle(c.pos, c.yaw, size): misses[2] += 1; continue
			if not _physics_clear(c.pos, c.yaw, size, room): misses[2] += 1; continue
		# Anything standing taller than a rug keeps out of the door's swing, floor cushions too.
		if size.y > .03 and FURNISH_SURFACES._blocks_door_swing(self, c.pos, c.yaw, size): misses[2] += 1; continue
		if id == "sofa": c.sleep_couch = _couch_space(c.pos, c.yaw, room)
		_accept(area, id, spec, size, c, room)
		return true
	report.append("  %-14s %-15s -- %s: %d spots, no wall %d, moved into something %d, hits shell %d" % [area.role if area != null else "house", id, rule, found, misses[0], misses[1], misses[2]])
	return false

## A pull-out is solid while in use, so it cannot cross an essential walking lane
## or another piece's working space. Its foot approach can share ordinary floor.
func _couch_space(c: Vector2, yaw: float, room: int, check_shell: bool = true) -> bool:
	var front: Vector2 = _front(yaw)
	var bed_center: Vector2 = c + front * 1.09
	if not _solid_ok(_cells(bed_center, yaw, 0.85, 0.76)): return false
	if not _open_ok(_cells(c + front * 2.35, yaw, 0.85, 0.50)): return false
	if not check_shell: return true
	var shape:BoxShape3D=BoxShape3D.new()
	shape.size=Vector3(1.70,1.62,1.49)
	var query:PhysicsShapeQueryParameters3D=PhysicsShapeQueryParameters3D.new()
	query.shape=shape;query.collision_mask=1
	query.transform=Transform3D(_yaw_basis(yaw),_world(bed_center+front*.015,room,.04+shape.size.y*.5))
	return space.intersect_shape(query,1).is_empty() \
		and _physics_clear(c + front * 2.35, yaw, Vector3(1.70, 1.85, 1.0), room)

## The rectangular floor estimate can stop ~15 cm short of a slanted real wall.
## For an essential counter only, certify that narrow strip with actual floor rays;
## occupied cells, travel lanes and reserved clearances are never overridden.
func _supported_edge(c: Vector2, yaw: float, size: Vector3, room: int) -> bool:
	if room < 0: return false
	var cells: PackedInt32Array = _cells(c, yaw, size.x * 0.5, size.z * 0.5)
	if cells.is_empty() or cells[0] < 0: return false
	for cell: int in cells:
		if flags[cell] & (SOLID | LANE | CLEAR) != 0: return false
		if flags[cell] & FLOOR != 0: continue
		var p: Vector2 = _centre(cell % nx, int(cell / nx))
		if not rooms[room].grow(0.25).has_point(p): return false
		var floor_at: Vector3 = _world(p, room)
		var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(floor_at + Vector3.UP * 0.2, floor_at - Vector3.UP * 0.12, 1))
		if hit.is_empty() or hit.normal.y < 0.9 or absf(hit.position.y - floor_at.y) > 0.1: return false
	return true

func _pick(cands: Array) -> int:
	var total := 0.0
	for c: Dictionary in cands: total += c.weight
	var roll := rng.randf() * total
	for i in cands.size():
		roll -= cands[i].weight
		if roll <= 0.0: return i
	return cands.size() - 1

func _accept(area, id: String, spec: Dictionary, size: Vector3, c: Dictionary, room: int) -> void:
	var index := placed.size()
	var entry := {"id": id, "pos": c.pos, "yaw": c.yaw, "size": size, "room": room, "index": index,
		"faces": c.get("faces", ""), "scale": c.get("scale", 1.0), "lift": c.get("lift", 0.0), "sleep_couch": c.get("sleep_couch", false)}
	if c.has("drape"):
		entry.drape = c.drape
		entry.drape_below = c.drape_below
	placed.append(entry)
	if area != null: area.placed[id] = entry
	var cells := _cells(c.pos, c.yaw, size.x * 0.5, size.z * 0.5)
	if spec.get("decor", false):
		pass
	elif spec.get("flat", false):
		_mark(cells, RUG)
	elif not spec.get("hang", 0.0) and not spec.get("curtain", false):
		_mark(cells, SOLID | (TALL if size.y > TALL_M else 0))
		var clear: float = spec.get("clear", 0.0)
		if clear > 0.0:
			_mark(_cells(c.pos + _front(c.yaw) * (size.z * 0.5 + clear * 0.5), c.yaw, size.x * 0.5, clear * 0.5), CLEAR, index)
		var aisle: float = spec.get("aisle", 0.0)
		if aisle > 0.0 and c.get("free", false):
			for k in _cells(c.pos, c.yaw, size.x * 0.5 + aisle, size.z * 0.5 + aisle):
				if k >= 0 and flags[k] & SOLID == 0 and flags[k] & CLEAR == 0: flags[k] |= CLEAR; clear_owner[k] = index
		if c.get("sleep_couch", false):
			# The front-of-anchor rule may use its own ordinary clearance. Give this
			# reservation no furniture owner so a coffee table cannot consume it.
			_mark(_cells(c.pos + _front(c.yaw) * 1.59, c.yaw, 0.85, 1.26), CLEAR, -2)
	report.append("  %-14s %-15s at (%.2f, %.2f) yaw %d" % [area.role if area != null else "house", id, c.pos.x, c.pos.y, roundi(rad_to_deg(c.yaw))])


# --- candidate generators --------------------------------------------------------------------

## Tall props must not stand in front of a window.
func _blocks_window(c: Vector2, yaw: float, size: Vector3) -> bool:
	return FURNISH_SURFACES._blocks_window(self, c, yaw, size)

func _under_window(c: Vector2, yaw: float, size: Vector3) -> bool:
	return FURNISH_SURFACES._under_window(self, c, yaw, size)

func _wall_candidates(area: Dictionary, id: String, size: Vector3, spec: Dictionary, step: Dictionary) -> Array:
	return FURNISH_CANDIDATES._wall_candidates(self, area, id, size, spec, step)

func _island_candidates(area: Dictionary, size: Vector3, spec: Dictionary) -> Array:
	return FURNISH_CANDIDATES._island_candidates(self, area, size, spec)

func _face_candidates(area: Dictionary, size: Vector3, spec: Dictionary, step: Dictionary) -> Array:
	return FURNISH_CANDIDATES._face_candidates(self, area, size, spec, step)

func _front_candidates(area: Dictionary, size: Vector3, step: Dictionary) -> Array:
	return FURNISH_CANDIDATES._front_candidates(self, area, size, step)

func _flank_candidates(area: Dictionary, size: Vector3, step: Dictionary) -> Array:
	return FURNISH_CANDIDATES._flank_candidates(self, area, size, step)

## A rug between the sofa and what it faces, else just in front of it. Rugs may tuck 15 cm under
## furniture legs, so the test footprint is smaller than the rug.
func _between_candidates(area: Dictionary, size: Vector3, step: Dictionary) -> Array:
	return FURNISH_CANDIDATES._between_candidates(self, area, size, step)

func _bedside_candidates(size: Vector3, b: Dictionary) -> Array:
	return FURNISH_CANDIDATES._bedside_candidates(self, size, b)

func _bedrug_candidates(size: Vector3, b: Dictionary) -> Array:
	return FURNISH_CANDIDATES._bedrug_candidates(self, size, b)

## Decor laid on its anchor (the kit's "on" table: offset across / up / forward, turn).
func _on_candidates(area: Dictionary, id: String, step: Dictionary) -> Array:
	return FURNISH_CANDIDATES._on_candidates(self, area, id, step)

## A bench across the foot of a bed, facing the room.
func _bedfoot_candidates(size: Vector3, b: Dictionary) -> Array:
	return FURNISH_CANDIDATES._bedfoot_candidates(self, size, b)

func _window_floor_candidates(area: Dictionary, size: Vector3, spec: Dictionary) -> Array:
	return FURNISH_CANDIDATES._window_floor_candidates(self, area, size, spec)

func _open_candidates(area: Dictionary, size: Vector3, spec: Dictionary, flat: bool) -> Array:
	return FURNISH_CANDIDATES._open_candidates(self, area, size, spec, flat)

func _door_candidates(size: Vector3) -> Array:
	return FURNISH_CANDIDATES._door_candidates(self, size)

# --- walls, windows and physics --------------------------------------------------------------

## Pushes a wall piece back until it touches the real wall (3 cm gap). null: no wall within reach.
func _snug(c: Vector2, yaw: float, size: Vector3, room: int) -> Variant:
	return FURNISH_CANDIDATES._snug(self, c, yaw, size, room)

## Rays straight back from five points across the piece's back, at 35 and 70 cm (under the
## window sills): at least four of the five must meet the house shell within 25 cm.
func _wall_behind(c: Vector2, yaw: float, size: Vector3, room: int) -> bool:
	return FURNISH_CANDIDATES._wall_behind(self, c, yaw, size, room)

func _physics_clear(c: Vector2, yaw: float, size: Vector3, room: int) -> bool:
	return FURNISH_CANDIDATES._physics_clear(self, c, yaw, size, room)

var debug_hits := PackedStringArray()

## Only visible structural triangles can support wall attachments. Physics layer 1
## also contains the moving door and furniture, and is not a wall classification.
func _read_attachment_surfaces() -> void:
	FURNISH_SURFACES._read_attachment_surfaces(self)

func _blocks_handle(c: Vector2, yaw: float, size: Vector3) -> bool:
	return FURNISH_SURFACES._blocks_handle(self, c, yaw, size)

func _attachment_blocks_door(c: Vector2, yaw: float, size: Vector3) -> bool:
	return FURNISH_SURFACES._attachment_blocks_door(self, c, yaw, size)

## Nearest visible wall face, in house metres, never the closed leaf or old props.
func _wall_hit(p: Vector2, n: Vector2, room: int, height: float) -> Variant:
	return FURNISH_SURFACES._wall_hit(self, p, n, room, height)

func _hang_wall(area: Dictionary, id: String) -> void:
	FURNISH_SURFACES._hang_wall(self, area, id)

## Wall spots for something hung at eye height: backed by a wall, no window there, nothing tall
## standing in front.
func _wall_candidates_hung(area: Dictionary, size: Vector3) -> Array:
	return FURNISH_SURFACES._wall_candidates_hung(self, area, size)

## One pair per ground-floor window by chance, hung on the wall face above the glass and scaled to
## the window's height.
func _curtains(chance: float) -> void:
	FURNISH_SURFACES._curtains(self, chance)

## Occupancy picture for review: floor cream, lanes blue, clearances yellow, props brown (tall
## darker), rugs pink; north (house -Z) up, one pixel per cell.
func debug_image() -> Image:
	return OCCUPANCY_GRID.debug_image(self)

# --- spawning --------------------------------------------------------------------------------

const SEAT := preload("res://world/life/seat.gd")
## Seat spots and split collision for a seatable prop (kit "seating"), in the prop's metres.
## Built before the prop enters the tree, so the bodies take their final scale (Jolt keeps the
## scale a body entered with).
static func _add_seating(model: Node3D, seating: Dictionary, box: AABB, k: float, is_couch := false) -> void:
	FURNITURE_ASSETS._add_seating(model, seating, box, k, is_couch)

static func _scene_path(id: String) -> String:
	return FURNITURE_ASSETS._scene_path(id)

static func _scene(id: String) -> PackedScene:
	return FURNITURE_ASSETS._scene(id)

static var _requested: Dictionary:
	get: return FURNITURE_ASSETS._requested
	set(value): FURNITURE_ASSETS._requested = value
## Starts loading every kit prop on worker threads; true once all are in memory. Houses wait
## for this so the first furnished house does not stall the frame loading 20 GLBs.
static func props_loaded() -> bool:
	return FURNITURE_ASSETS.props_loaded()

static func _model_box(id: String, model: Node3D) -> AABB:
	return FURNITURE_ASSETS._model_box(id, model)

func _spawn(p: Dictionary) -> void:
	var model_id := _model(p.id)
	var scene := _scene(model_id)
	if scene == null: return
	var model: Node3D = scene.instantiate()
	var box := _model_box(model_id, model)
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	var metres: Vector3 = _sizes[p.id] * p.scale
	var k: float = maxf(metres.x, maxf(metres.y, metres.z)) / maxf(longest, 1e-6)
	var basis := Basis(Vector3.UP, p.yaw).scaled(Vector3.ONE * (k / s))
	var anchor := basis * Vector3(box.get_center().x, box.position.y, box.get_center().z)
	if p.id == "curtains" and p.get("drape", 0.0) > 0.0:
		preload("res://world/interiors/curtain_drape.gd").install(model, float(p.drape) / k, float(p.drape_below))
	var at := Vector3(p.pos.x / s, _top(p.room) + p.lift / s, p.pos.y / s)
	model.transform = Transform3D(basis, at - anchor)
	model.name = "Furniture_%s_%d" % [p.id, p.index]
	model.set_meta("furniture", p.id)
	if bool(p.get("welcome_table", false)): model.set_meta("welcome_table", true)
	if p.id=="sofa":model.set_meta("sleep_couch",p.get("sleep_couch",false))
	model.add_to_group("house_furniture")
	var spec: Dictionary = _kit.props.get(p.id, {})
	var shadows: bool = maxf(metres.x, maxf(metres.y, metres.z)) >= 1.6 and not spec.get("flat", false)
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			mi.set_surface_override_material(i, _material(model_id, mi.mesh.surface_get_material(i)))
		mi.visibility_range_end = VISIBLE_M
		mi.visibility_range_end_margin = 4.0
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var seating: Dictionary = spec.get("seating", {})
	if not seating.is_empty():
		_add_seating(model, seating, box, k, str(p.id)=="sofa")
		if p.id=="sofa":model.get_node("Seating/Couch").set_meta("layout_sleep_allowed",p.get("sleep_couch",false))
	elif spec.get("collide", false):
		var body := StaticBody3D.new()
		body.name = "Collision"
		body.collision_layer = 1
		body.collision_mask = 0
		var holder := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = box.size
		holder.shape = shape
		holder.position = box.get_center()
		body.add_child(holder)
		model.add_child(body)
	home.add_child(model)
	FURNISH_LAMPS.light_up(model, spec)
	if model_id in ["kitchen-island", "compact-kitchen"]:
		preload("res://world/cooking/cooking_fit.gd").attach(model, home, model_id)
	if _kit.get("shelves", {}).has(model_id) and _kit.shelves[model_id] is Dictionary and _kit.shelves[model_id].has("levels"):
		# Books on the shelves, in the bookcase's own metres (origin: bottom centre).
		var shelf := Node3D.new()
		shelf.name = "Books"
		shelf.transform = Transform3D(Basis.from_scale(Vector3.ONE / maxf(k, 1e-6)), Vector3(box.get_center().x, box.position.y, box.get_center().z))
		model.add_child(shelf)
		var shelf_rng := RandomNumberGenerator.new()
		shelf_rng.seed = hash("books:%s:%d" % [home.place_id(), p.index])
		SHELF_BOOKS.fill(shelf, _kit.shelves[model_id], shelf_rng, "%s:%d" % [home.place_id(), p.index], float(style.get("books", 1.0)), palette)
	var activity: Dictionary = spec.get("activity", {})
	if not activity.is_empty():
		var spot := Marker3D.new()
		spot.name = "Spot_%s_%d" % [activity.kind, p.index]
		var off: Array = activity.offset
		var local := _front(p.yaw) * (metres.z * 0.5 + float(off[1])) + _right(p.yaw) * float(off[0])
		var pos: Vector2 = p.pos + local
		var face_yaw: float = p.yaw + (PI if activity.get("face", "front") == "back" else 0.0)
		spot.transform = Transform3D(Basis(Vector3.UP, face_yaw), Vector3(pos.x / s, _top(p.room), pos.y / s))
		spot.set_meta("activity", activity.kind)
		spot.set_meta("furniture", p.id)
		spot.add_to_group("house_activity_spots")
		home.add_child(spot)
