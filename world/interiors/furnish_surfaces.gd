extends RefCounted
## furnish surfaces extracted from interior_furnisher.gd.
## State and callback dispatch stay on the owning instance; authored transforms and order are unchanged.

const TALL := 32
const GAP := 0.03
const HANDLE_KEEPOUT := 0.75


static func _read_house(context: RefCounted) -> void:
	var source: Array = (context.home as Node3D)._fitted_rooms if not (context.home as Node3D)._fitted_rooms.is_empty() else (context.home as Node3D).floors
	for r: Rect2 in source: (context.rooms as Array[Rect2]).append(Rect2(r.position * (context.s as float), r.size * (context.s as float)))
	(context.tops as Array[float]).assign((context.home as Node3D)._room_tops if (context.home as Node3D)._room_tops.size() == (context.rooms as Array[Rect2]).size() else [])
	while (context.tops as Array[float]).size() < (context.rooms as Array[Rect2]).size(): (context.tops as Array[float]).append((context.home as Node3D).floor_y)
	context.door_pt = (context._plan((context.home as Node3D).doorway) as Vector2)
	context.door_in = (context._plan_world((context.home as Node3D).inside()) as Vector2)
	context._read_attachment_surfaces()
	# The batcher's world-axis boxes lose width/depth when the house is rotated.
	# Read the original panes AND their trim in house coordinates, before batching.
	var facts: Array[Dictionary] = (context._source_windows((context.home as Node3D).get_parent() as Node3D) as Array[Dictionary])
	var to_home: Transform3D = (context.home as Node3D).transform.affine_inverse()
	for fact: Dictionary in facts:
		var box: AABB = to_home * (fact.glass as AABB)
		var frame: AABB = to_home * (fact.frame as AABB)
		var c := (context._plan(box.get_center()) as Vector2)
		var room := (context._nearest_room(c, 0.8) as int)
		if room < 0: continue
		var sill := (box.position.y - (context._top(room) as float)) * (context.s as float)
		if sill > 2.2 or sill < 0.2: continue   # an upper floor window, or a door light
		var thin_x := box.size.x < box.size.z
		var rc := (context.rooms as Array[Rect2])[room].get_center()
		var n := Vector2(signf(rc.x - c.x), 0.0) if thin_x else Vector2(0.0, signf(rc.y - c.y))
		# The glass sits inside the wall: its room-side face is the fitted room edge.
		var edge := c
		var r := (context.rooms as Array[Rect2])[room]
		if thin_x: edge.x = r.position.x if n.x > 0 else r.end.x
		else: edge.y = r.position.y if n.y > 0 else r.end.y
		var window: Dictionary = {"c": c, "n": n, "half": maxf(box.size.x, box.size.z) * (context.s as float) * 0.5, "sill": sill,
			"top": (box.end.y - (context._top(room) as float)) * (context.s as float), "room": room, "edge": edge,
			"frame": AABB(frame.position * (context.s as float), frame.size * (context.s as float))}
		window.curtain = (context._curtain_layout(window) as Dictionary)
		(context.windows as Array).append(window)

static func _curtain_layout(context: RefCounted, w: Dictionary) -> Dictionary:
	var size: Vector3 = (context._visible_size("curtains") as Vector3)
	var scale: float = clampf((w.top - w.sill + 0.3) / size.y, 1.0, 1.6)
	var sized: Vector3 = size * scale
	var n: Vector2 = w.n
	var frame: AABB = w.frame
	var top: float = maxf(w.top, frame.end.y - (context._top(w.room) as float) * (context.s as float)) + 0.2
	var right: Vector2 = Vector2(n.y, -n.x)
	var left_hit: Variant = context._wall_hit(w.c - right * sized.x * .44, n, w.room, top-.05)
	var right_hit: Variant = context._wall_hit(w.c + right * sized.x * .44, n, w.room, top-.05)
	if left_hit == null or right_hit == null: return {}
	# A straight curtain rod cannot mount across a corner or an opening.
	if absf(((left_hit as Vector2)-(right_hit as Vector2)).dot(n)) > .06: return {}
	# Place the whole source assembly by its rod, not the fabric's full depth.
	# Projecting frames must not push the rod out into the room or add long arms.
	var rod_depth: float = -.04052734375 / .998046875 * sized.x
	var depth: float = maxf((left_hit as Vector2).dot(n), (right_hit as Vector2).dot(n))
	var c: Vector2 = w.c + n * (depth - (w.c as Vector2).dot(n) - rod_depth + .008)
	if (context._attachment_blocks_door(c, (context._yaw_of(n) as float), sized) as bool): return {}
	var face := Vector2(frame.end.x if n.x > 0 else frame.position.x,
		frame.end.z if n.y > 0 else frame.position.z)
	var drape: float = maxf(0.0, face.dot(n) + sized.z * .5 + GAP - c.dot(n))
	var source_scale: float = sized.x / .998046875
	var drape_below: float = (frame.end.y - (context._top(w.room) as float) * (context.s as float) - (top - sized.y) + GAP) / source_scale
	return {"pos": c, "yaw": (context._yaw_of(n) as float), "scale": scale, "lift": top - sized.y, "size": sized,
		"drape": drape, "drape_below": drape_below}

static func _decoration_blocks_window(context: RefCounted, c: Vector2, yaw: float, size: Vector3, room: int, lift: float) -> bool:
	var floor_height: float = (context._top(room) as float) * (context.s as float)
	for w: Dictionary in (context.windows as Array):
		var frame: AABB = w.frame
		var bounds: AABB = frame
		var curtain: Dictionary = w.curtain
		if not curtain.is_empty():
			var curtain_size: Vector3 = curtain.size
			var curtain_transform: Transform3D = Transform3D(Basis(Vector3.UP, curtain.yaw),
				Vector3(curtain.pos.x, (context._top(w.room) as float) * (context.s as float) + curtain.lift, curtain.pos.y))
			bounds = bounds.merge(curtain_transform * AABB(Vector3(-curtain_size.x * 0.5, 0, -curtain_size.z * 0.5), curtain_size))
			# The lower cloth drapes forward from the fixed wall rod. Reserve its
			# complete cached-variant envelope when placing nearby hanging props.
			var forward: Vector3 = curtain_transform.basis * Vector3.BACK
			curtain_transform.origin += forward * (float(curtain.get("drape", 0.0)) + curtain_size.x / .998046875 * .025)
			bounds = bounds.merge(curtain_transform * AABB(Vector3(-curtain_size.x * 0.5, 0, -curtain_size.z * 0.5), curtain_size))
		if floor_height + lift >= bounds.end.y + GAP or floor_height + lift + size.y <= bounds.position.y - GAP: continue
		var centre: Vector2 = Vector2(bounds.get_center().x, bounds.get_center().z)
		var half: Vector2 = Vector2(bounds.size.x, bounds.size.z) * 0.5
		var separated: bool = false
		for axis: Vector2 in [Vector2.RIGHT, Vector2.DOWN, (context._right(yaw) as Vector2), (context._front(yaw) as Vector2)]:
			var extent: float = absf(axis.dot((context._right(yaw) as Vector2))) * size.x * 0.5 + absf(axis.dot((context._front(yaw) as Vector2))) * size.z * 0.5
			var window_extent: float = absf(axis.x) * half.x + absf(axis.y) * half.y
			if absf((c - centre).dot(axis)) >= extent + window_extent + GAP:
				separated = true
				break
		if not separated: return true
	return false

static func _blocks_window(context: RefCounted, c: Vector2, yaw: float, size: Vector3) -> bool:
	var f := (context._front(yaw) as Vector2)
	for w: Dictionary in (context.windows as Array):
		# A sofa back or a dresser may reach a little over the sill; cupboards may not.
		if size.y < w.sill + 0.08: continue
		if f.dot(w.n) < 0.7: continue
		var back := c - f * size.z * 0.5
		if absf((back - w.edge).dot(w.n)) > 0.6: continue
		var t := Vector2(-w.n.y, w.n.x)
		if absf((c - w.edge).dot(t)) < size.x * 0.5 + w.half + 0.1: return true
	return false

static func _under_window(context: RefCounted, c: Vector2, yaw: float, size: Vector3) -> bool:
	var f := (context._front(yaw) as Vector2)
	for w: Dictionary in (context.windows as Array):
		if f.dot(w.n) < 0.7 or absf((c - f * size.z * 0.5 - w.edge).dot(w.n)) > 0.6: continue
		if absf((c - w.edge).dot(Vector2(-w.n.y, w.n.x))) < w.half: return true
	return false

static func _read_attachment_surfaces(context: RefCounted) -> void:
	var house: Node3D = (context.home as Node3D).get_parent() as Node3D
	var inverse: Transform3D = (context.home as Node3D).global_transform.affine_inverse()
	var metres: Vector3 = Vector3((context.s as float), (context.home as Node3D).global_basis.y.length(), (context.s as float))
	for mesh: MeshInstance3D in house.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null or not mesh.is_visible_in_tree(): continue
		# Includes AInnerWall/Part2/ExteriorRoomFace, but not its projecting
		# NativeTimber trim: attachments mount on the actual room plane.
		if str(mesh.name) not in ["Exterior", "ExteriorRoomFace"] and not mesh.get_meta("interior_attachment_surface", false): continue
		var transform: Transform3D = inverse * mesh.global_transform
		var faces: PackedVector3Array = mesh.mesh.get_faces()
		for i: int in range(0, faces.size(), 3):
			var a: Vector3 = (transform * faces[i]) * metres
			var b: Vector3 = (transform * faces[i+1]) * metres
			var c: Vector3 = (transform * faces[i+2]) * metres
			var normal: Vector3 = (b-a).cross(c-a).normalized()
			if absf(normal.y) > .35 or normal.length_squared() < .5: continue
			(context._wall_triangles as Array[Dictionary]).append({"a": a, "b": b, "c": c, "normal": normal,
				"bounds": AABB(a, Vector3.ZERO).expand(b).expand(c).grow(.001)})
	var leaf: Node3D = (context.home as Node3D).door() as Node3D
	if leaf != null:
		# Door script opens +90 degrees about its authored left hinge. Reserve
		# its whole swept quadrant, independent of its current animated angle.
		var hinge: Vector2 = (context._plan_world(leaf.global_position) as Vector2)
		var closed: AABB = leaf.get("navigation_box")
		var radius: float = maxf(absf(closed.position.x), absf(closed.end.x)) * (context.s as float)
		radius = maxf(radius, float((context.home as Node3D).door_width) * (context.s as float))
		var thickness: float = maxf(absf(closed.position.z), absf(closed.end.z)) * (context.s as float) + .12
		context._door_clearance = Rect2(hinge + Vector2(-thickness, -radius-thickness), Vector2(radius+2*thickness, radius+2*thickness))
		context._door_sweep = _door_sweep(context, leaf)
		var handle: Variant = leaf.get("handle")
		if handle is Vector3: context._handle_plan = (context._plan_world(leaf.to_global(Vector3(handle.x, handle.y, -0.05))) as Vector2)

static func _blocks_handle(context: RefCounted, c: Vector2, yaw: float, size: Vector3) -> bool:
	if not (context._handle_plan as Vector2).is_finite(): return false
	var extent: Vector2 = (context._right(yaw) as Vector2).abs() * size.x * .5 + (context._front(yaw) as Vector2).abs() * size.z * .5
	var nearest := (context._handle_plan as Vector2).clamp(c - extent, c + extent)
	return nearest.distance_to((context._handle_plan as Vector2)) < HANDLE_KEEPOUT

static func _attachment_blocks_door(context: RefCounted, c: Vector2, yaw: float, size: Vector3) -> bool:
	if not (context._door_sweep as Array).is_empty(): return _blocks_door_swing(context, c, yaw, size)
	var extent: Vector2 = (context._right(yaw) as Vector2).abs() * size.x * .5 + (context._front(yaw) as Vector2).abs() * size.z * .5
	return (context._door_clearance as Rect2).has_area() and (context._door_clearance as Rect2).intersects(Rect2(c-extent, extent*2))

## The door leaf's plan outline at SWEEP_STEPS angles from shut to fully open (hinged_door.gd: it
## turns about its hinge by angle * swing_direction, 0..90 degrees), each grown by DOOR_GAP.
## dev 2026-10-14: furniture stood where the open door swung through it in many houses; only the
## handle and wall-hung pieces were kept clear, and those against a one-direction box.
const SWEEP_STEPS := 10
const DOOR_GAP := 0.04
static func _door_sweep(context: RefCounted, leaf: Node3D) -> Array[PackedVector2Array]:
	var sweep: Array[PackedVector2Array] = []
	var box: AABB = leaf.get("navigation_box")
	if not box.has_volume() or leaf.get_parent() == null: return sweep
	var parent: Transform3D = (leaf.get_parent() as Node3D).global_transform
	var direction := float(leaf.get("swing_direction"))
	var corners: Array[Vector3] = [box.position, Vector3(box.end.x, box.position.y, box.position.z),
		Vector3(box.end.x, box.position.y, box.end.z), Vector3(box.position.x, box.position.y, box.end.z)]
	for step in SWEEP_STEPS + 1:
		var turn := Basis(Vector3.UP, PI * .5 * float(step) / SWEEP_STEPS * direction)
		var outline := PackedVector2Array()
		for corner: Vector3 in corners:
			outline.append(context._plan_world(parent * (leaf.position + turn * corner)) as Vector2)
		var grown := Geometry2D.offset_polygon(outline, DOOR_GAP)
		sweep.append(grown[0] if not grown.is_empty() else outline)
	return sweep

## True when a piece of footprint size.x by size.z at c, facing yaw, stands where the door swings.
static func _blocks_door_swing(context: RefCounted, c: Vector2, yaw: float, size: Vector3) -> bool:
	var sweep: Array = context._door_sweep
	if sweep.is_empty(): return false
	var right: Vector2 = (context._right(yaw) as Vector2) * size.x * .5
	var front: Vector2 = (context._front(yaw) as Vector2) * size.z * .5
	var footprint := PackedVector2Array([c - right - front, c + right - front, c + right + front, c - right + front])
	for outline: PackedVector2Array in sweep:
		if not Geometry2D.intersect_polygons(footprint, outline).is_empty(): return true
	return false

static func _wall_hit(context: RefCounted, p: Vector2, n: Vector2, room: int, height: float) -> Variant:
	var from: Vector3 = Vector3(p.x+n.x*.6, (context._top(room) as float)*(context.home as Node3D).global_basis.y.length()+height, p.y+n.y*.6)
	var to: Vector3 = Vector3(p.x-n.x*.5, from.y, p.y-n.y*.5)
	var nearest: Variant = null
	var distance: float = INF
	var direction: Vector3 = Vector3(n.x, 0, n.y)
	for triangle: Dictionary in (context._wall_triangles as Array[Dictionary]):
		if absf((triangle.normal as Vector3).dot(direction)) < .9: continue
		var bounds: AABB = triangle.bounds
		if from.y < bounds.position.y or from.y > bounds.end.y or not bounds.intersects_segment(from, to): continue
		var hit: Variant = Geometry3D.segment_intersects_triangle(from, to, triangle.a, triangle.b, triangle.c)
		if hit == null: continue
		var point: Vector3 = hit
		var travel: float = from.distance_squared_to(point)
		if travel < distance:
			distance = travel
			nearest = Vector2(point.x, point.z)
	return nearest

static func _hang_wall(context: RefCounted, area: Dictionary, id: String) -> void:
	if not (context._sizes as Dictionary).has(id): return
	var size: Vector3 = (context._visible_size(id) as Vector3)
	var height: float = (context._kit as Dictionary).props[id].get("hang", 1.75)
	var cands := []
	for cand: Dictionary in (context._wall_candidates_hung(area, size) as Array):
		cands.append(cand)
	while not cands.is_empty():
		var pick := (context._pick(cands) as int)
		var c: Dictionary = cands[pick]
		cands.remove_at(pick)
		var hit: Variant = context._wall_hit(c.pos, (context._front(c.yaw) as Vector2), area.room, height)
		if hit == null: continue
		c.pos = hit + (context._front(c.yaw) as Vector2) * (size.z * 0.5 + 0.005)
		c.lift = height - size.y * 0.5
		if (context._attachment_blocks_door(c.pos, c.yaw, size) as bool): continue
		# Check after fitting to the real wall: candidate depth can move, and
		# curtains are selected later than clocks/racks in the recipe order.
		if (context._decoration_blocks_window(c.pos, c.yaw, size, area.room, c.lift) as bool): continue
		# The entire shelf must be supported; a centre ray alone can hit a wing
		# stub while the ends project across a doorway. Also keep below the roof.
		var backed: bool = true
		for offset: float in [-0.48, 0.0, 0.48]:
			# Low support rejects complete openings even if a lintel backs the
			# clock's centre. Top/bottom probes keep shelves off sloping corners.
			for probe_height: float in [.8, height-size.y*.45, height, height+size.y*.45]:
				var support: Variant = context._wall_hit(c.pos + (context._right(c.yaw) as Vector2)*size.x*offset, (context._front(c.yaw) as Vector2), area.room, probe_height)
				if support == null or absf(((support as Vector2)-c.pos).dot((context._front(c.yaw) as Vector2))) > size.z*.5+.06: backed = false
		if not backed: continue
		var shape: BoxShape3D = BoxShape3D.new()
		shape.size = Vector3(maxf(.02,size.x-.03),maxf(.02,size.y-.03),maxf(.02,size.z-.03))
		var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
		query.shape=shape;query.collision_mask=1
		query.transform=Transform3D((context._yaw_basis(c.yaw) as Basis),(context._world(c.pos,area.room,height) as Vector3))
		if not (context.space as PhysicsDirectSpaceState3D).intersect_shape(query,1).is_empty():continue
		var overlap: bool=false
		for previous: Dictionary in (context.placed as Array):
			if previous.room != area.room:continue
			if float(previous.lift)+previous.size.y < c.lift or previous.lift > c.lift+size.y:continue
			if previous.pos.distance_to(c.pos) < (Vector2(previous.size.x,previous.size.z).length()+Vector2(size.x,size.z).length())*.5:overlap=true;break
		if overlap:continue
		context._accept(area, id, (context._kit as Dictionary).props[id], size, c, area.room)
		return

static func _wall_candidates_hung(context: RefCounted, area: Dictionary, size: Vector3) -> Array:
	var out := []
	var r: Rect2 = area.rect
	for side in 4:
		var n: Vector2 = [Vector2(0, 1), Vector2(0, -1), Vector2(1, 0), Vector2(-1, 0)][side]
		var along_x := n.x == 0
		var line: float = [r.position.y, r.end.y, r.position.x, r.end.x][side]
		var lo := (r.position.x if along_x else r.position.y) + 0.5
		var hi := (r.end.x if along_x else r.end.y) - 0.5
		var a := lo
		while a <= hi:
			var on_wall := Vector2(a, line) if along_x else Vector2(line, a)
			a += 0.2
			var c := on_wall + n * 0.1
			var yaw := (context._yaw_of(n) as float)
			if not (context._backed(c, yaw, size.x, 0.1) as bool): continue
			if (context._blocks_window(c, yaw, Vector3(size.x, 9.0, 0.1)) as bool): continue
			var tall := false
			for k in (context._cells(c + n * 0.3, yaw, size.x * 0.5 + 0.1, 0.35) as PackedInt32Array):
				if k < 0 or (context.flags as PackedByteArray)[k] & TALL: tall = true; break
			if tall: continue
			var weight := 1.0
			for p: Dictionary in (context.placed as Array):
				if p.id == "sofa" and p.pos.distance_to(c) < 1.4: weight = 4.0
			out.append({"pos": c, "yaw": yaw, "weight": weight})
	return out

static func _curtains(context: RefCounted, chance: float) -> void:
	var id := "curtains"
	var done := []
	for w: Dictionary in (context.windows as Array):
		if (context.rng as RandomNumberGenerator).randf() > chance: continue
		var dup := false
		for d: Vector2 in done:
			if d.distance_to(w.c) < 0.5: dup = true
		if dup: continue
		var room: int = w.room
		var entry: Dictionary = w.curtain
		if entry.is_empty(): continue
		context._accept(null, id, (context._kit as Dictionary).props[id], entry.size, entry, room)
		done.append(w.c)

