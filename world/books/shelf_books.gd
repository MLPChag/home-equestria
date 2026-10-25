extends RefCounted
## Books on house bookshelves (dev 2026-09-26: "theres NO BOOKS on it"). Each shelf gets a row of
## slots across every shelf. Real books from the player's library can be taken or placed
## (group "shelf_books"; E on desktop, grip in VR) and read. A taken book stays taken
## (book_library.gd mark_taken), so shelves do not refill on the next load.
##
## Works in the bookcase's own frame, in metres: origin at the bottom centre of its front-facing
## box, +Z out of the shelves. The shelf levels come from the kit ("shelves" in interior_kit.json).

const LIBRARY := preload("res://world/books/book_library.gd")
const BOOK := preload("res://world/books/book_item.gd")
const DECOR_COLOURS := ["6b2e2a", "7d4a2b", "2f4a3a", "34465e", "5a3d5c", "8a6a3b", "a7472f", "3e5f58",
	"4a3b2c", "9b8a6a", "2b2b30", "6e7b46", "b58a4c", "5d2438", "31506b", "c9b48f"]
static var _decor_mesh: ArrayMesh

## Adds the books under `anchor` (a Node3D in bookcase metres). `spec` is the kit's shelf entry,
## `density` the house style's liking for books, `palette` the house fabric palette.
static func fill(anchor: Node3D, spec: Dictionary, rng: RandomNumberGenerator, key_prefix: String, density := 1.0, palette := {}) -> int:
	var x0: float = spec.x[0]
	var x1: float = spec.x[1]
	var front: float = spec.front
	var transforms: Array[Transform3D] = []
	var colours: Array[Color] = []
	var real := 0
	var library: Array = LIBRARY.books()
	var levels: Array = spec.levels
	anchor.add_to_group("book_shelves")
	var shelf_height := 0.0
	for level: Array in levels: shelf_height = maxf(shelf_height, float(level[0]) + float(level[1]))
	anchor.set_meta("shelf_radius", Vector3(maxf(absf(x0), absf(x1)), shelf_height, absf(front) + BOOK.SIZE.x).length())
	for level_index in levels.size():
		var level: Array = levels[level_index]
		var floor_y: float = level[0]
		var clear: float = level[1]
		if rng.randf() > clampf(0.55 + 0.35 * density, 0.2, 1.0): continue   # an empty shelf now and then
		var x := x0 + rng.randf_range(0.0, 0.06)
		var end := x1 - rng.randf_range(0.0, 0.25 / maxf(density, 0.4))
		var real_here := 0
		while x < end - 0.02:
			var roll := rng.randf()
			# A short lying stack of 2-4 books.
			if roll < 0.08 and end - x > 0.26:
				var y := floor_y
				for n in rng.randi_range(2, 4):
					var w := rng.randf_range(0.17, 0.24)
					var d := rng.randf_range(0.13, 0.17)
					var t := rng.randf_range(0.025, 0.04)
					var basis := Basis(Vector3.UP, rng.randf_range(-0.12, 0.12)) * Basis.from_scale(Vector3(w, t, d))
					transforms.append(Transform3D(basis, Vector3(x + 0.13, y + t * 0.5, front - d * 0.5 - 0.01)))
					colours.append(_colour(rng, palette))
					y += t
				x += 0.27
				continue
			# A readable library book, standing among the others (not on the low top shelf).
			if library.size() > 0 and clear > 0.24 and real_here < 2 and roll < 0.14 * density and end - x > BOOK.SIZE.y + 0.01:
				var book: Dictionary = library[rng.randi_range(0, library.size() - 1)]
				var key := "%s:%d:%d" % [key_prefix, level_index, int(x * 100)]
				_real_book(anchor, book, Vector3(x + BOOK.SIZE.y * 0.5, floor_y, front), key, clear)
				if not LIBRARY.taken(key): real += 1
				# Reserve taken slots too: borrowing must not change the seeded layout.
				real_here += 1
				x += BOOK.SIZE.y + 0.004
				continue
			var height := minf(rng.randf_range(0.17, 0.28), clear - 0.015)
			var depth := minf(rng.randf_range(0.12, 0.18), height * 0.85)
			var thick := rng.randf_range(0.018, 0.05)
			var lean := 0.0
			if roll > 0.93 and x > x0 + 0.1:
				lean = rng.randf_range(0.18, 0.32)       # leaning against its neighbour
			var basis := _upright() * Basis.from_scale(Vector3(depth, thick, height))
			var pivot := Vector3(x + thick * 0.5, floor_y, front - depth * 0.5 - rng.randf_range(0.0, 0.02))
			if lean > 0.0:
				basis = Basis(Vector3.BACK, -lean) * basis
				pivot.x += sin(lean) * height * 0.5
				x += sin(lean) * height
			transforms.append(Transform3D(basis, pivot + Vector3.UP * height * 0.5 * cos(lean)))
			colours.append(_colour(rng, palette))
			x += thick + rng.randf_range(0.0, 0.004)
			if lean > 0.0: break
	# Keep the old seeded readable-book positions/keys so existing loans stay taken.
	# Fill the remaining width with stable slots; no decorative book occupies a usable slot.
	for level_index in levels.size():
		var level: Array = levels[level_index]
		if float(level[1]) < .10: continue
		var floor_y: float = level[0]
		var clear: float = level[1]
		var added := 0
		var x: float = x0 + BOOK.SIZE.y * .5
		var stock := clampi(roundi(4.0 * density), 3, 8)
		while x <= x1 - BOOK.SIZE.y * .5:
			var occupied := false
			for child: Node in anchor.get_children():
				if child is Node3D and child.has_meta("shelf_floor") and is_equal_approx(float(child.get_meta("shelf_floor")), floor_y) and absf(child.position.x - x) < BOOK.SIZE.y + .004:
					occupied = true; break
			if not occupied:
				var book: Dictionary = library[(level_index * 7 + added) % library.size()] if not library.is_empty() and added < stock else {}
				var key := "%s:slot:%d:%d" % [key_prefix, level_index, roundi(x * 1000.0)]
				_real_book(anchor, book, Vector3(x, floor_y, front), key, clear)
				if not str(anchor.get_child(-1).get_meta("item_id", "")).is_empty(): real += 1
				added += 1
			x += BOOK.SIZE.y + .008
	if library.is_empty() and not transforms.is_empty():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _decor()
		mm.instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i])
			mm.set_instance_color(i, colours[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "ShelfBooks"
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = 30.0
		anchor.add_child(mmi)
	return real

## Book frame upright on a shelf: head up (+Z book -> +Y), spine out (-X book -> +Z),
## thickness along the shelf (+Y book -> -X).
static func _upright() -> Basis:
	return Basis(Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0))

static func _colour(rng: RandomNumberGenerator, palette: Dictionary) -> Color:
	var c := Color(DECOR_COLOURS[rng.randi_range(0, DECOR_COLOURS.size() - 1)])
	if palette.has("fabric") and rng.randf() < 0.3: c = Color.html(palette.fabric).darkened(rng.randf_range(0.1, 0.35))
	return c.darkened(rng.randf_range(-0.08, 0.12))

static func _decor() -> ArrayMesh:
	if _decor_mesh != null: return _decor_mesh
	_decor_mesh = BOOK.mesh(Vector3.ONE).duplicate()
	var cover := StandardMaterial3D.new()
	cover.vertex_color_use_as_albedo = true
	cover.vertex_color_is_srgb = true
	cover.roughness = 0.7
	_decor_mesh.surface_set_material(0, cover)
	_decor_mesh.surface_set_material(1, BOOK.page_material())
	return _decor_mesh

static func _real_book(anchor: Node3D, book: Dictionary, at: Vector3, key: String, clearance: float = 1.0) -> void:
	var body := StaticBody3D.new()
	body.name = "LibraryBook"
	body.collision_layer = 1 << 17       # the inventory's item layer: E and grip find it, ponies do not
	body.collision_mask = 0
	var initial := LIBRARY.item_id(int(book.id)) if book.has("id") else ""
	var item := LIBRARY.shelf_item(key, initial)
	body.set_meta("item_id", item)
	body.set_meta("shelf_floor", at.y)
	body.set_meta("shelf_key", key)
	body.set_meta("shelf_book", true)
	body.add_to_group("shelf_slots")
	if not item.is_empty(): body.add_to_group("shelf_books")
	else:
		body.hide()
		body.collision_layer = 0
	var size := BOOK.SIZE
	# Low shelves keep the larger handheld edition, with a fitted shelf copy.
	size.z = minf(size.z, clearance - .025)
	body.transform = Transform3D(_upright(), at + Vector3(0, size.z * 0.5, -size.x * 0.5 - 0.005))
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.set_meta("shelf_size", size)
	if not item.is_empty(): BOOK.build(body, item, size, anchor.get_tree() if anchor.is_inside_tree() else null)
	anchor.add_child(body)

## A generous, orientation-independent return target. Approach the visible front,
## not the back of a wall; geometry blocks returning through another room.
static func return_slot(tree: SceneTree, item: Node3D) -> Node3D:
	var best: Node3D
	var distance := .48
	if LIBRARY.id_of(str(item.get_meta("item_id", ""))) < 0: return null
	for slot: Node3D in _nearby_slots(tree, item.global_position, .48):
		if slot.visible: continue
		var d := item.global_position.distance_to(slot.global_position)
		if d >= distance: continue
		# The spine/front is -X in the book frame; stop before the shelf cavity.
		var front := slot.global_position - slot.global_basis.x * (BOOK.SIZE.x * .5 + .06)
		var query := PhysicsRayQueryParameters3D.create(item.global_position, front, 1)
		if item is CollisionObject3D: query.exclude = [item.get_rid()]
		if not item.get_world_3d().direct_space_state.intersect_ray(query).is_empty(): continue
		best = slot
		distance = d
	return best

## One broad check per bookcase, not every slot in every loaded house each input frame.
static func _nearby_slots(tree: SceneTree, point: Vector3, reach: float) -> Array[Node]:
	var result: Array[Node] = []
	for shelf: Node3D in tree.get_nodes_in_group("book_shelves"):
		if not shelf.is_visible_in_tree(): continue
		# Radius is in shelf metres; imported bookcases may carry a non-uniform scale.
		var scale: Vector3 = shelf.global_basis.get_scale().abs()
		var radius: float = float(shelf.get_meta("shelf_radius", 2.0)) * maxf(scale.x, maxf(scale.y, scale.z))
		if shelf.global_position.distance_squared_to(point) > (reach + radius) * (reach + radius): continue
		for child: Node in shelf.get_children():
			if child.is_in_group("shelf_slots"): result.append(child)
	return result

## Desktop placement follows the same centre cursor as pickup, so adjacent slots are deliberate.
static func aimed_slot(tree: SceneTree, origin: Vector3, direction: Vector3) -> Node3D:
	if not origin.is_finite() or not direction.is_finite(): return null
	var best: Node3D
	var nearest := 2.5
	for slot: Node3D in _nearby_slots(tree, origin, 2.5):
		if slot.visible: continue
		var normal := -slot.global_basis.x.normalized()
		var denominator := direction.dot(normal)
		if denominator >= -.001: continue
		var front := slot.global_position + normal * (BOOK.SIZE.x * .5 + .06)
		var distance := (front - origin).dot(normal) / denominator
		if distance <= 0.0 or distance > nearest: continue
		var local := slot.to_local(origin + direction * distance)
		var size: Vector3 = slot.get_meta("shelf_size", BOOK.SIZE)
		if absf(local.y) > size.y * .5 + .004 or absf(local.z) > size.z * .5: continue
		var query := PhysicsRayQueryParameters3D.create(origin, front, 1)
		if not slot.get_world_3d().direct_space_state.intersect_ray(query).is_empty(): continue
		best = slot; nearest = distance
	return best

static func return_book(slot: Node3D, inventory: RefCounted, token: String) -> bool:
	if not is_instance_valid(slot) or slot.visible or not inventory.loans.has(token): return false
	var item_id := str(inventory.loans[token].id)
	if LIBRARY.id_of(item_id) < 0: return false
	var key := str(slot.get_meta("shelf_key", ""))
	if not LIBRARY.set_shelf_item(key, item_id): return false
	if not inventory.consume(token):
		LIBRARY.mark_taken(key)
		return false
	slot.set_meta("item_id", item_id)
	var previous := slot.get_node_or_null("Book")
	if previous != null: slot.remove_child(previous); previous.free()
	var size: Vector3 = slot.get_meta("shelf_size", BOOK.SIZE)
	BOOK.build(slot, item_id, size, slot.get_tree())
	slot.show()
	slot.collision_layer = 1 << 17
	slot.add_to_group("shelf_books")
	return true
