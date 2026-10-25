extends RefCounted
## Individual alcoves carved through the tree-wall lining. Stable physical shelf keys.
const KIT := preload("res://world/buildings/golden_oak/furniture_kit.gd")
const WALL_RADIUS := 5.01
const RECESS_RADIUS := 5.40
const BAY_RADIUS := 4.54
const BOOK_SHIFT := -.58 # Original front .22 becomes -.36: radial distance 4.90.
const JEWELS := ["d74969", "ae467c", "784baa", "5455b0", "3884ba", "3faaa9",
	"ec768d", "a66acb", "c55147", "789946", "4167a5", "e4a651"]

## Main removes these rectangles from lining visuals AND collision.
static func wall_openings() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var angles := [56.0, 80.0, 104.0, 141.0, 199.0, 116.0, 142.0, 195.0]
	for index: int in angles.size():
		var width: float = 1.55 if index < 3 else (1.6 if index < 5 else 1.4)
		var height: float = 2.45 if index < 3 else (2.6 if index < 5 else 2.65)
		var bottom: float = 0.0 if index < 5 else 3.4
		result.append({"angle": deg_to_rad(angles[index]), "half_angle": asin(width * .5 / WALL_RADIUS),
			"bottom": bottom, "top": bottom + height, "index": index})
	return result

static func build(parent: Node3D, at: Vector3, yaw: float, index: int, width: float = 1.55, height: float = 2.45) -> Node3D:
	var bay := Node3D.new()
	bay.name = "CarvedBookshelf%02d" % index
	bay.transform = Transform3D(Basis(Vector3.UP, yaw), at)
	bay.set_meta("furniture", "bookshelf")
	bay.add_to_group("house_furniture")
	var half: float = width * .5
	var levels: Array = []
	var shelf_y := .27
	while shelf_y < height - half - .14:
		levels.append([shelf_y, .37])
		shelf_y += .42
	# Do not change these inputs: RNG order determines persistent shelf keys.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("golden_oak:carved_shelf:%02d" % index)
	KIT.BOOKS.fill(bay, {"x": [-half + .15, half - .15], "front": .22, "levels": levels}, rng,
		"golden_oak:carved_shelf:%02d" % index, 1.8, {"fabric": "8c425e"})
	for child: Node in bay.get_children():
		if child is MultiMeshInstance3D or child.has_meta("shelf_key"):
			(child as Node3D).position.z += BOOK_SHIFT
	var rows: Array[float] = []
	for level: Array in levels: rows.append(float(level[0]))
	# Additional decorative row uses a separate generator, never physical-book keys.
	while shelf_y + .335 < height - .055:
		rows.append(shelf_y)
		shelf_y += .42
	_carve_panel(bay, width, height, rows, index, parent.global_transform, _board_material(parent))
	_fill_decorative_gaps(bay, rows, half, index)
	parent.add_child(bay)
	return bay

## Closed boards share one ordinary back-culled material per interior. Open alcove
## bevels keep their separate two-sided material. No runtime traversal or tick.
static func _board_material(parent: Node3D) -> StandardMaterial3D:
	const KEY := &"golden_oak_shelf_board_material"
	if parent.has_meta(KEY): return parent.get_meta(KEY) as StandardMaterial3D
	var material := KIT.material("ec987f")
	material.cull_mode = BaseMaterial3D.CULL_BACK
	parent.set_meta(KEY, material)
	return material

static func _point(x: float, y: float, radius: float) -> Vector3:
	return Vector3(x, y, BAY_RADIUS - sqrt(radius * radius - x * x))

static func _surface(material: Material) -> SurfaceTool:
	var result := SurfaceTool.new()
	result.begin(Mesh.PRIMITIVE_TRIANGLES)
	result.set_material(material)
	return result

static func _quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for point: Vector3 in [a, b, c, a, c, d]: surface.add_vertex(point)

static func _finish(parent: Node3D, label: String, surface: SurfaceTool) -> void:
	surface.generate_normals()
	surface.index()
	var view := MeshInstance3D.new()
	view.name = label
	view.mesh = surface.commit()
	# Follow actual holes/reveals: a filled case-shaped collider would block the
	# player's hands from reaching books recessed behind the original wall plane.
	var body := StaticBody3D.new()
	body.name = label + "Solid"
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape: ConcavePolygonShape3D = view.mesh.create_trimesh_shape()
	shape.backface_collision = true
	collision.shape = shape
	body.add_child(collision)
	view.add_child(body)
	parent.add_child(view)

static func _carve_panel(bay: Node3D, width: float, height: float, rows: Array[float], index: int, room_frame: Transform3D, board_mat: StandardMaterial3D) -> void:
	# Main owns this shader; cylindrical world-to-room coordinates match the shell.
	var face_mat: Material = load("res://world/buildings/golden_oak/reference_materials.gd").wall(room_frame)
	var bevel_mat := KIT.material("ec987f")
	var reveal_mat := KIT.material("b95358")
	var back_mat := KIT.material("823943")
	for material: StandardMaterial3D in [bevel_mat, reveal_mat, back_mat]:
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var face: SurfaceTool = _surface(face_mat)
	var bevel: SurfaceTool = _surface(bevel_mat)
	var reveal: SurfaceTool = _surface(reveal_mat)
	var back: SurfaceTool = _surface(back_mat)
	var half: float = width * .5
	for row: int in rows.size():
		var center_y: float = rows[row] + .15
		var low: float = 0.0 if row == 0 else (rows[row - 1] + rows[row]) * .5 + .15
		var high: float = height if row == rows.size() - 1 else (rows[row] + rows[row + 1]) * .5 + .15
		var outside := PackedVector2Array()
		# Every corner is sampled; adjacent bands share x subdivisions and radius.
		for k: int in 12: outside.append(Vector2(lerpf(-half, half, float(k) / 12), low))
		for k: int in 6: outside.append(Vector2(half, lerpf(low, high, float(k) / 6)))
		for k: int in 12: outside.append(Vector2(lerpf(half, -half, float(k) / 12), high))
		for k: int in 6: outside.append(Vector2(-half, lerpf(high, low, float(k) / 6)))
		var mouth := PackedVector2Array()
		var crown: bool = row == rows.size() - 1
		var roundness: float = .65 if crown else .38 + .035 * ((row + index) % 4)
		for outer: Vector2 in outside:
			var angle: float = atan2((outer.y - center_y) / .185, outer.x / (half - .045))
			var sx: float = cos(angle)
			var sy: float = sin(angle)
			# Separately tapered, gently uneven rounded slots, never a case-wide arch.
			var x: float = signf(sx) * pow(absf(sx), roundness) * (half - .045)
			x *= (.88 if crown else 1.0) * (1.0 - .055 * maxf(sy, 0.0))
			x += .012 * sin(angle * 3.0 + index * .9 + row * 1.7) * absf(sy)
			var y: float = center_y + signf(sy) * pow(absf(sy), .48) * .185
			y += .008 * sin(angle * 2.0 + index + row * 1.3) * absf(sx)
			mouth.append(Vector2(x, y))
		for k: int in mouth.size():
			var n: int = (k + 1) % mouth.size()
			var a: Vector2 = mouth[k]
			var b: Vector2 = mouth[n]
			var oa: Vector2 = outside[k]
			var ob: Vector2 = outside[n]
			_quad(face, _point(oa.x, oa.y, WALL_RADIUS), _point(ob.x, ob.y, WALL_RADIUS),
				_point(b.x, b.y, WALL_RADIUS), _point(a.x, a.y, WALL_RADIUS))
			var ia := Vector2(a.x * .975, center_y + (a.y - center_y) * .92)
			var ib := Vector2(b.x * .975, center_y + (b.y - center_y) * .92)
			_quad(bevel, _point(a.x, a.y, WALL_RADIUS), _point(b.x, b.y, WALL_RADIUS),
				_point(ib.x, ib.y, 5.065), _point(ia.x, ia.y, 5.065))
			var ba := Vector2(a.x * .93, center_y + (a.y - center_y) * .92)
			var bb := Vector2(b.x * .93, center_y + (b.y - center_y) * .92)
			_quad(reveal, _point(ia.x, ia.y, 5.065), _point(ib.x, ib.y, 5.065),
				_point(bb.x, bb.y, RECESS_RADIUS), _point(ba.x, ba.y, RECESS_RADIUS))
			for p: Vector3 in [_point(0, center_y, RECESS_RADIUS), _point(ba.x, ba.y, RECESS_RADIUS), _point(bb.x, bb.y, RECESS_RADIUS)]:
				back.add_vertex(p)
		# Shelf boards carry books physically without filling the reachable opening.
		KIT.box(bay, "AlcoveShelf%02d" % row, Vector3(width - .15, .035, .45),
			Vector3(0, rows[row] - .0175, -.60), board_mat, true)
	_finish(bay, "ContinuousPeachWall", face)
	_finish(bay, "SoftCarvedMouths", bevel)
	_finish(bay, "CoralInnerReveals", reveal)
	_finish(bay, "IndividualRoundedRecesses", back)

static func _fill_decorative_gaps(bay: Node3D, rows: Array[float], half: float, index: int) -> void:
	var original: MultiMeshInstance3D = bay.get_node_or_null("ShelfBooks") as MultiMeshInstance3D
	var occupied: Array[Rect2] = []
	if original != null:
		var mm: MultiMesh = original.multimesh
		for i: int in mm.instance_count:
			var pose: Transform3D = mm.get_instance_transform(i)
			var bounds: AABB = pose * mm.mesh.get_aabb()
			occupied.append(Rect2(bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y))
			mm.set_instance_color(i, Color(JEWELS[(i * 7 + index * 3) % JEWELS.size()]))
	for child: Node in bay.get_children():
		if not child.has_meta("shelf_key"): continue
		var body: Node3D = child as Node3D
		var collision: CollisionShape3D = body.get_child(0) as CollisionShape3D
		var box: BoxShape3D = collision.shape as BoxShape3D
		var bounds: AABB = body.transform * AABB(-box.size * .5, box.size)
		occupied.append(Rect2(bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y))
	var poses: Array[Transform3D] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("golden_oak:alcove_decor:%02d" % index)
	for row: int in rows.size():
		var floor_y: float = rows[row]
		var edge: float = .25 if row == rows.size() - 1 else .16
		var x: float = -half + edge
		while x < half - edge - .02:
			var thickness: float = rng.randf_range(.024, .048)
			var book_height: float = rng.randf_range(.19, .28)
			var rect := Rect2(x - .004, floor_y + .012, thickness + .01, book_height)
			var available := true
			for taken: Rect2 in occupied:
				if rect.intersects(taken):
					available = false
					break
			if available:
				var basis: Basis = KIT.BOOKS._upright() * Basis.from_scale(Vector3(.155, thickness, book_height))
				poses.append(Transform3D(basis, Vector3(x + thickness * .5, floor_y + book_height * .5, -.45)))
			x += thickness + .007
	if poses.is_empty(): return
	var books := MultiMesh.new()
	books.transform_format = MultiMesh.TRANSFORM_3D
	books.use_colors = true
	books.mesh = KIT.BOOKS._decor()
	books.instance_count = poses.size()
	for i: int in poses.size():
		books.set_instance_transform(i, poses[i])
		books.set_instance_color(i, Color(JEWELS[(i * 5 + index) % JEWELS.size()]))
	var view := MultiMeshInstance3D.new()
	view.name = "AlcoveExtraBooks"
	view.multimesh = books
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	view.visibility_range_end = 30.0
	bay.add_child(view)
