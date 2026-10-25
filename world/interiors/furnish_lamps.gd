extends RefCounted
## House lamps (dev 2026-10-14: "add lamps to every house"). Runs inside interior_furnisher.gd after
## the rooms are furnished and before curtains. Lamp props are ordinary kit entries with a "lamp"
## key (interior_kit.json props + its "lamps" table); their models are the Blender kit GLBs in
## world/props/lamps/kit, and world/props/lamps/kit_lamp.gd gives each its light and switch.
## Every furnished home gets one standing light (a table lamp on a bedside table, a floor lamp by
## the sofa or armchair, else against a wall), one upper light (a pendant over a table, a wall
## sconce or a candle niche) and a wall lantern beside the front door outside.
const KIT_LAMP := preload("res://world/props/lamps/kit_lamp.gd")
const FURNITURE_ASSETS := preload("res://world/interiors/furniture_assets.gd")
const FURNISH_SURFACES := preload("res://world/interiors/furnish_surfaces.gd")
## Lowest a pendant may hang over open floor, and its gap above a table it lights.
const PENDANT_HEADROOM := 2.05
const PENDANT_OVER_TABLE := 0.45

## Kit lamp props become loaded kit props: scene from the lamp kit, size from the model itself
## (so the furnisher spawns them at scale 1).
static func register() -> void:
	var kit: Dictionary = FURNITURE_ASSETS._kit
	for id: String in kit.get("props", {}):
		var spec: Dictionary = kit.props[id]
		if not spec.has("lamp") or FURNITURE_ASSETS._sizes.has(id): continue
		var path: String = KIT_LAMP.DIR + str(spec.lamp) + ".glb"
		if not ResourceLoader.exists(path): continue
		var scene: PackedScene = load(path) as PackedScene
		if scene == null: continue
		FURNITURE_ASSETS._scenes[id] = scene
		var model: Node3D = scene.instantiate() as Node3D
		var box: AABB = FURNITURE_ASSETS._model_box(id, model)
		model.free()
		FURNITURE_ASSETS._sizes[id] = box.size

## The lamp pass. f is the interior_furnisher instance (a coroutine like its other passes).
static func run(f: RefCounted) -> void:
	var table: Dictionary = (f._kit as Dictionary).get("lamps", {})
	if table.is_empty(): return
	var standing: Array = table.get("standing", [])
	var upper: Array = table.get("upper", [])
	var have_standing := false
	var have_upper := false
	for area: Dictionary in (f.areas as Array):
		await f._slice()
		if not f._alive(): return
		if _try_steps(f, area, standing, false): have_standing = true
		if (f.rng as RandomNumberGenerator).randf() <= float(table.get("upper_chance", 0.7)) or not have_upper:
			if _try_steps(f, area, upper, false): have_upper = true
	# Every home gets both kinds: fall back to any room and the plainest rules.
	for area: Dictionary in (f.areas as Array):
		if not f._alive(): return
		if not have_standing: have_standing = _try_steps(f, area, table.get("standing_fallback", []), true)
		if not have_upper: have_upper = _try_steps(f, area, table.get("upper_fallback", []), true)
	if not have_standing: _note(f, "  NO STANDING LAMP: no safe spot")
	if not have_upper: _note(f, "  NO UPPER LAMP: no safe spot")
	_plan_door_lantern(f, str(table.get("door", "wall-lantern")))

## First step that fits this area's role (and passes its chance) places the area's lamp.
static func _try_steps(f: RefCounted, area: Dictionary, steps: Array, any_role: bool) -> bool:
	for step: Dictionary in steps:
		var roles: Array = step.get("roles", [])
		if not any_role and not roles.is_empty() and not roles.has(area.role): continue
		var id: String = step.prop
		if not (f._sizes as Dictionary).has(id): continue
		if step.has("anchor") and not (area.placed as Dictionary).has(step.anchor): continue
		if not any_role and (f.rng as RandomNumberGenerator).randf() > float(step.get("chance", 1.0)): continue
		if _place(f, area, id, step): return true
	return false

static func _place(f: RefCounted, area: Dictionary, id: String, step: Dictionary) -> bool:
	var before: int = (f.placed as Array).size()
	match str(step.rule):
		"hang": f._hang_wall(area, id)
		"ceiling": _hang_pendant(f, area, id, step)
		_: f._place(area, id, str(step.rule), step)
	return (f.placed as Array).size() > before

## A pendant over the anchor table (or the room centre with full headroom), from the real ceiling.
static func _hang_pendant(f: RefCounted, area: Dictionary, id: String, step: Dictionary) -> void:
	var size: Vector3 = (f._sizes as Dictionary)[id]
	var room: int = area.room
	var spots: Array[Dictionary] = []
	var anchor_id: String = str(step.get("anchor", ""))
	if not anchor_id.is_empty() and (area.placed as Dictionary).has(anchor_id):
		var a: Dictionary = area.placed[anchor_id]
		spots.append({"pos": a.pos, "floor_clear": float(a.lift) + (a.size as Vector3).y + PENDANT_OVER_TABLE})
	elif step.get("centre", false):
		spots.append({"pos": (area.rect as Rect2).get_center(), "floor_clear": PENDANT_HEADROOM})
	for spot: Dictionary in spots:
		var ceiling: float = _ceiling_above(f, spot.pos, room)
		if ceiling == INF:
			_note(f, "  %-14s %-15s -- ceiling: none overhead" % [area.role, id]); continue
		if ceiling - size.y < float(spot.floor_clear):
			_note(f, "  %-14s %-15s -- ceiling: %.2f m too low for %.2f m clear" % [area.role, id, ceiling, float(spot.floor_clear)]); continue
		if FURNISH_SURFACES._blocks_door_swing(f, spot.pos, 0.0, size):
			_note(f, "  %-14s %-15s -- ceiling: in the door swing" % [area.role, id]); continue
		var c := {"pos": spot.pos, "yaw": (f.rng as RandomNumberGenerator).randf() * TAU, "weight": 1.0, "lift": ceiling - size.y}
		f._accept(area, id, (f._kit as Dictionary).props[id], size, c, room)
		return

## Height (m above the room floor) of the nearest surface over plan point p, INF if none within
## CEILING_REACH. Collision first; then the house shell's own triangles, because many cottage
## ceilings and roofs are drawn but have no collider (2026-10-15: every pendant found nothing).
const CEILING_REACH := 4.5
static func _ceiling_above(f: RefCounted, p: Vector2, room: int) -> float:
	var floor_at: Vector3 = f._world(p, room)
	var best := INF
	var space: PhysicsDirectSpaceState3D = f.space
	var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(floor_at + Vector3.UP * 1.0, floor_at + Vector3.UP * CEILING_REACH, 1))
	if not hit.is_empty(): best = (hit.position as Vector3).y - floor_at.y
	# Shell triangles in the furnisher's plan metres (home-local times the house scale).
	var home: Node3D = f.home
	var ys: float = home.global_basis.y.length()
	var base := Vector3(p.x, float(f._top(room)) * ys, p.y)
	var from: Vector3 = base + Vector3.UP * 1.0
	var to: Vector3 = base + Vector3.UP * minf(best, CEILING_REACH)
	for t: Dictionary in _overhead_triangles(f):
		var bounds: AABB = t.bounds
		if p.x < bounds.position.x or p.x > bounds.end.x or p.y < bounds.position.z or p.y > bounds.end.z: continue
		if bounds.position.y > to.y or bounds.end.y < from.y: continue
		var at: Variant = Geometry3D.segment_intersects_triangle(from, to, t.a, t.b, t.c)
		if at == null: at = Geometry3D.segment_intersects_triangle(from, to, t.a, t.c, t.b)
		if at != null:
			best = minf(best, (at as Vector3).y - base.y)
			to = base + Vector3.UP * best
	return best

## The house shell's non-vertical triangles (ceilings, roof undersides), cached per furnish.
static func _overhead_triangles(f: RefCounted) -> Array:
	if f.has_meta("overhead_triangles"): return f.get_meta("overhead_triangles")
	var out: Array = []
	var home: Node3D = f.home
	var house: Node3D = home.get_parent() as Node3D
	var inverse: Transform3D = home.global_transform.affine_inverse()
	var metres := Vector3(float(f.s), home.global_basis.y.length(), float(f.s))
	for mesh: MeshInstance3D in house.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null or not mesh.is_visible_in_tree(): continue
		var label: String = str(mesh.name).to_lower()
		if not (label in ["exterior", "exteriorroomface"] or label.contains("ceiling") or label.contains("roof") or mesh.get_meta("interior_attachment_surface", false)): continue
		var transform: Transform3D = inverse * mesh.global_transform
		var faces: PackedVector3Array = mesh.mesh.get_faces()
		for i: int in range(0, faces.size(), 3):
			var a: Vector3 = (transform * faces[i]) * metres
			var b: Vector3 = (transform * faces[i + 1]) * metres
			var c: Vector3 = (transform * faces[i + 2]) * metres
			var normal: Vector3 = (b - a).cross(c - a)
			if normal.length_squared() < 1e-8 or absf(normal.normalized().y) < .35: continue
			out.append({"a": a, "b": b, "c": c, "bounds": AABB(a, Vector3.ZERO).expand(b).expand(c).grow(.001)})
	f.set_meta("overhead_triangles", out)
	return out

## The front-door wall lantern: outside, beside the door on the house wall, facing the street.
## Planned here (physics is ready), spawned by spawn_outdoor after the furniture.
## Cartoon fronts are not flat: timber beams, window trim and slanted boards stand out of the
## wall (houses C, E and G had no clear flat spot, 2026-10-15). A grid of rays over the lantern's
## back finds the outermost surface there; the lantern mounts on it, and its box in front of
## that surface must be clear. Candidates: both sides, a few distances and heights.
static func _plan_door_lantern(f: RefCounted, id: String) -> void:
	var home: Node3D = f.home
	if not (f._kit as Dictionary).props.has(id): return
	var size: Vector3 = Vector3(.2, .5, .4)
	if (f._sizes as Dictionary).has(id): size = (f._sizes as Dictionary)[id]
	var s: float = f.s
	var width: float = float(home.door_width)
	var sides: Array[float] = [-1.0, 1.0]
	if (f.rng as RandomNumberGenerator).randf() < 0.5: sides.reverse()
	var space: PhysicsDirectSpaceState3D = f.space
	var basis: Basis = home.global_basis.orthonormalized()
	var outward: Vector3 = basis.z
	for height: float in LANTERN_HEIGHTS:
		for beside: float in LANTERN_BESIDE:
			for side: float in sides:
				var local_x: float = home.doorway.x + side * (width * 0.5 + (beside + size.x * 0.5) / s)
				var local_y: float = home.floor_y + height / s
				var centre: Vector3 = home.to_global(Vector3(local_x, local_y, home.doorway.z))
				var mount: Variant = _lantern_mount(space, centre, basis, size)
				if mount == null: continue
				var wall: Vector3 = mount
				var plan: Vector2 = f._plan_world(wall + outward * size.z * 0.5)
				if FURNISH_SURFACES._blocks_door_swing(f, plan, 0.0, size): continue
				if _over_window(f, wall, basis, size):
					_note(f, "  lantern side %d %.2f m: over a window" % [int(side), beside]); continue
				f.set_meta("door_lantern", {"id": id, "at": home.to_local(wall)})
				_note(f, "  %-14s %-15s outside the door, side %d, %.2f m beside, %.2f m up" % ["house", id, int(side), beside, height])
				return
	_note(f, "  NO DOOR LANTERN: no clear wall beside the door")

## The lantern's box (in front of its wall point) overlaps a window's glass or trim, any floor
## (dev 2026-10-17: "theres a lamp attached to a window"). Glass is outward-facing wall to the
## mount rays, so this check is separate.
const WINDOW_MARGIN := 0.08
static func _over_window(f: RefCounted, wall: Vector3, basis: Basis, size: Vector3) -> bool:
	var home: Node3D = f.home
	var house: Node3D = home.get_parent() as Node3D
	if house == null: return false
	var lantern := Transform3D(basis, wall + basis.z * (size.z * 0.5) + Vector3.UP * -0.095) * AABB(-size * 0.5, size)
	for fact: Dictionary in (f._source_windows(house) as Array):
		for key: String in ["frame", "glass"]:
			if not fact.has(key): continue
			var box: AABB = house.global_transform * (fact[key] as AABB)
			if box.grow(WINDOW_MARGIN).intersects(lantern): return true
	return false

## Heights (m above the floor) and distances beside the door edge tried for the door lantern.
const LANTERN_HEIGHTS: Array[float] = [2.05, 1.9, 2.2, 1.75]
const LANTERN_BESIDE: Array[float] = [0.32, 0.55, 0.85]
## Deepest step the back plate may bridge between the outermost and innermost wall surface.
const LANTERN_MAX_STEP := 0.22

## The wall point for a lantern centred (in plan) at centre, or null: rays from the street over the
## back plate (3 across, 3 down) must all hit outward-facing wall within LANTERN_MAX_STEP of
## each other; the lantern's box in front of the outermost hit must touch nothing.
static func _lantern_mount(space: PhysicsDirectSpaceState3D, centre: Vector3, basis: Basis, size: Vector3) -> Variant:
	var outward: Vector3 = basis.z
	var nearest := INF
	var farthest := -INF
	for u: float in [-0.4, 0.0, 0.4]:
		for v: float in [0.1, 0.0, -0.2]:
			var at: Vector3 = centre + basis.x * (u * size.x) + Vector3.UP * v
			var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(at + outward * 1.6, at - outward * 0.8, 1))
			if hit.is_empty() or (hit.normal as Vector3).dot(outward) < 0.5: return null
			var travel: float = ((at + outward * 1.6) - (hit.position as Vector3)).dot(outward)
			nearest = minf(nearest, travel)
			farthest = maxf(farthest, travel)
	if farthest - nearest > LANTERN_MAX_STEP: return null
	var wall: Vector3 = centre + outward * (1.6 - nearest)
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, size.y, size.z - 0.04)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1
	# The model's box runs from the arm top (+0.15) down to the lantern finial (-0.34).
	query.transform = Transform3D(basis, wall + outward * (size.z * 0.5 + 0.03) + Vector3.UP * -0.095)
	if not space.intersect_shape(query, 1).is_empty(): return null
	return wall

## Spawns the planned door lantern (furniture of the house: a refurnish replaces it).
static func spawn_outdoor(f: RefCounted) -> void:
	if not f.has_meta("door_lantern"): return
	var plan: Dictionary = f.get_meta("door_lantern")
	var home: Node3D = f.home
	var lamp: Node3D = KIT_LAMP.create(str((f._kit as Dictionary).props[plan.id].lamp))
	lamp.name = "Furniture_%s_door" % str(plan.id)
	# Undo the house scale so the lantern keeps its modelled size (set before entering the tree:
	# Jolt bodies keep the scale they enter with).
	lamp.transform = Transform3D(Basis.from_scale(Vector3.ONE / maxf(float(f.s), 0.001)), plan.at)
	lamp.set_meta("furniture", str(plan.id))
	lamp.add_to_group("house_furniture")
	home.add_child(lamp)
	for mesh: MeshInstance3D in lamp.find_children("*", "MeshInstance3D", true, false):
		mesh.visibility_range_end = 70.0
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Lights a spawned kit lamp prop (called from the furnisher's _spawn).
static func light_up(model: Node3D, spec: Dictionary) -> void:
	if not spec.has("lamp"): return
	KIT_LAMP.attach(model, str(spec.lamp))

## Adds a line to the furnisher's report. PackedStringArray is a value type: appending to the
## property's returned copy would drop the line.
static func _note(f: RefCounted, line: String) -> void:
	var lines: PackedStringArray = f.report
	lines.append(line)
	f.report = lines
