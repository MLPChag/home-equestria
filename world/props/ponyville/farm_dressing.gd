extends Node3D
## Sweet Apple Acres fences and apple orchard (world/props/ponyville/farm_layout.json).
## Built once collision is staged: fence posts stand on the ground under each post, rails run
## post to post, and a stretch that would cross a building or prop is left open. Orchard trees
## are the approved purchased trees, smaller, with red apples in their crowns: one MultiMesh per
## kind of tree and one for all the apples, with continuous LODs.
## Fences and trunks collide, so the walk grid and the player treat them as solid.

const LAYOUT := "res://world/props/ponyville/farm_layout.json"
const CATALOGUE := preload("res://world/foliage/grassy_catalogue.gd")
const APPLE := preload("res://world/inventory/assets/apple.tscn")
signal orchard_ready
var orchard_trees: Array[Dictionary] = []
var _orchard_by_id: Dictionary = {}
var _apple_batch: MultiMesh
## Past FAR_APPLES_FROM the apple batch draws an 8-triangle stand-in per apple (2026-10-23 GPU
## pass: 221k apple triangles seen from town at 384 m). Same instances, so growth, picked apples
## and shakes carry over; only the batch's mesh is swapped.
const FAR_APPLES_FROM := 150.0
var _apple_near: Mesh
var _apple_far: Mesh
var _apple_bounds := AABB()
var _fruit_growth: Dictionary = {}
var _fruit_released: Dictionary = {}
var _shakes: Dictionary = {}
const MAX_SHAKING_TREES: int = 8
const SHAKE_SECONDS: float = .65
var _tries := 0
var _built: bool = false

func _ready() -> void:
	set_process(false)
	name = "SweetAppleAcresDressing"
	add_to_group("apple_orchards")
	get_tree().create_timer(2.0).timeout.connect(_build)

func _build() -> void:
	if not is_inside_tree() or _built: return
	var layout: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	if not (layout is Dictionary): push_warning("[farm] bad " + LAYOUT); return
	# Wait until the ground under the farm has collision (streamed terrain, staged bodies).
	var probe: Vector3 = _ground(Vector3(60, 0, -430))
	if not probe.is_finite() and _tries < 20:
		_tries += 1; get_tree().create_timer(2.0).timeout.connect(_build); return
	_built = true
	_fences(layout)
	_orchard(layout)
	orchard_ready.emit()

## Farm growth and fence posts belong on terrain, not on a roof above the site.
func _ground(p: Vector3) -> Vector3:
	if is_instance_valid(WorldTerrain.instance):
		var h: float = WorldTerrain.instance.height_at(Vector3(p.x, 0, p.z))
		if is_finite(h): return Vector3(p.x, h, p.z)
	var space := get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(p.x, 400, p.z), Vector3(p.x, -400, p.z), 1))
	if not hit.is_empty(): return hit.position
	return Vector3.INF

## Anything solid (buildings, props, other fences) in a box standing on the ground here.
func _blocked(at: Vector3, size: Vector3, yaw: float) -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new(); box.size = size
	query.shape = box; query.collision_mask = 1
	query.transform = Transform3D(Basis(Vector3.UP, yaw), at + Vector3.UP * (0.35 + size.y * 0.5))
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query, 4):
		if hit.collider is Terrain3D or (hit.collider is Node and (hit.collider as Node).is_ancestor_of(self)): continue
		if hit.collider is Node and str((hit.collider as Node).name).begins_with("Farm"): continue
		return true
	return false

func _fences(layout: Dictionary) -> void:
	var spec: Dictionary = layout.get("fence", {})
	var spacing := float(spec.get("post_spacing", 2.4))
	var post_h := float(spec.get("post_height", 1.15)); var post_w := float(spec.get("post_width", 0.13))
	var rails: Array = spec.get("rail_heights", [0.45, 0.9]); var rail_t := float(spec.get("rail_thickness", 0.07))
	var wood := StandardMaterial3D.new(); wood.albedo_color = Color(str(spec.get("color", "8a5a36"))); wood.roughness = 0.9
	var posts: Array[Transform3D] = []; var bars: Array[Transform3D] = []
	var body := StaticBody3D.new(); body.name = "FarmFence"; body.collision_mask = 0; add_child(body)
	for run: Dictionary in layout.get("fences", []):
		var pts: Array = run.get("points", [])
		var line: Array[Vector3] = []
		for i in range(pts.size() - 1):
			var a := Vector3(float(pts[i][0]), 0, float(pts[i][1])); var b := Vector3(float(pts[i + 1][0]), 0, float(pts[i + 1][1]))
			var n := maxi(1, roundi(a.distance_to(b) / spacing))
			for k in n + (1 if i == pts.size() - 2 else 0): line.append(a.lerp(b, float(k) / n))
		var prev := Vector3.INF
		for p in line:
			var g := _ground(p)
			if not g.is_finite(): prev = Vector3.INF; continue
			if _blocked(g, Vector3(post_w + .12, post_h - .35, post_w + .12), 0.0):
				prev = Vector3.INF; continue
			var ok := true
			if prev.is_finite():
				var mid := (prev + g) * 0.5; var d := g - prev; d.y = 0
				ok = not _blocked(mid, Vector3(0.3, post_h - 0.35, d.length()), atan2(d.x, d.z))
			if prev.is_finite() and ok:
				# Rails between this post and the previous one, following the slope.
				for h in rails:
					var from := prev + Vector3.UP * float(h); var to := g + Vector3.UP * float(h)
					var basis := Basis.looking_at(to - from, Vector3.UP) * Basis.from_scale(Vector3(rail_t, rail_t * 1.6, from.distance_to(to) + 0.1))
					bars.append(Transform3D(basis, (from + to) * 0.5))
				var span := g - prev
				var shape := CollisionShape3D.new(); var box := BoxShape3D.new()
				box.size = Vector3(0.12, post_h, Vector2(span.x, span.z).length())
				shape.shape = box
				shape.transform = Transform3D(Basis(Vector3.UP, atan2(span.x, span.z)), (prev + g) * 0.5 + Vector3.UP * post_h * 0.5)
				body.add_child(shape)
			if ok or not prev.is_finite():
				posts.append(Transform3D(Basis.from_scale(Vector3(post_w, post_h, post_w)), g + Vector3.UP * (post_h * 0.5 - 0.08)))
			prev = g if ok or not prev.is_finite() else Vector3.INF
	_multimesh("FarmFencePosts", BoxMesh.new(), wood, posts)
	_multimesh("FarmFenceRails", BoxMesh.new(), wood, bars)

func _multimesh(node_name: String, mesh: Mesh, material: Material, xforms: Array[Transform3D]) -> void:
	if xforms.is_empty(): return
	var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.mesh = mesh
	if node_name == "FarmApples": mm.use_custom_data = true
	mm.instance_count = xforms.size()
	for i in xforms.size(): mm.set_instance_transform(i, xforms[i])
	var mi := MultiMeshInstance3D.new(); mi.name = node_name; mi.multimesh = mm
	if material != null: mi.material_override = material
	add_child(mi)
	if node_name == "FarmApples":
		_apple_batch = mm
		var fruit_material: ShaderMaterial = ShaderMaterial.new()
		fruit_material.shader = preload("res://world/minigames/apple_bucking/orchard_fruit.gdshader")
		mi.material_override = fruit_material
		for i: int in mm.instance_count: mm.set_instance_custom_data(i, Color(1, 0, 0, 1))

func _orchard(layout: Dictionary) -> void:
	var spec: Dictionary = layout.get("orchard", {})
	if spec.is_empty(): return
	var trees := CATALOGUE.trees()
	if trees.is_empty(): return
	var rng := RandomNumberGenerator.new(); rng.seed = 20260923
	var apple_mesh: Mesh = null
	var apple_scene := APPLE.instantiate()
	for mi: MeshInstance3D in apple_scene.find_children("*", "MeshInstance3D", true, false): apple_mesh = mi.mesh; break
	apple_scene.free()
	var apples: Array[Transform3D] = []
	var planted := {}   # entry id -> [entry, [Transform3D]]
	var trunks := StaticBody3D.new(); trunks.name = "FarmOrchardTrunks"; trunks.collision_mask = 0; add_child(trunks)
	var xr: Array = spec.x; var zr: Array = spec.z; var step: Array = spec.spacing
	var z := float(zr[0]); var row := 0
	while z <= float(zr[1]):
		var x := float(xr[0]) + (float(step[0]) * 0.5 if row % 2 == 1 else 0.0)
		var column: int = 0
		while x <= float(xr[1]):
			var at := Vector3(x + rng.randf_range(-1, 1) * float(spec.jitter), 0, z + rng.randf_range(-1, 1) * float(spec.jitter))
			var g := _ground(at)
			if g.is_finite() and not _blocked(g, Vector3(1.6, 1.4, 1.6), 0.0):
				var entry: Dictionary = trees[rng.randi() % trees.size()]
				if _species(entry).has("mesh"):
					var s := rng.randf_range(float(spec.scale[0]), float(spec.scale[1]))
					var xform := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), g + Basis.from_scale(Vector3.ONE * s) * CATALOGUE.contact_offset(entry))
					if not planted.has(entry.id): planted[entry.id] = [entry, []]
					var tree_instance: int = planted[entry.id][1].size()
					planted[entry.id][1].append(xform)
					var shape := CollisionShape3D.new(); var cyl := CylinderShape3D.new(); cyl.radius = 0.35; cyl.height = 2.2
					shape.shape = cyl; shape.position = g + Vector3.UP * 1.1; trunks.add_child(shape)
					# IDs name planted grid slots, never scene instance IDs or the compacted
					# list of unblocked trees. Skipping another slot cannot rename a harvest.
					var tree_id: String = "saa:r%02d:c%02d" % [row, column]
					shape.set_meta("apple_tree_id", tree_id)
					var first_apple: int = apples.size()
					if apple_mesh != null: _hang_apples(xform, _species(entry).box, apples, rng, int(spec.apples_per_tree), float(spec.apple_scale))
					var tree: Dictionary = {"id":tree_id, "position":g, "radius":.35, "height":2.2,
						"batch":"FarmOrchard_" + str(entry.id), "instance":tree_instance, "render_transform":xform * _species(entry).local,
						"first":first_apple, "apples":apples.slice(first_apple), "shape":shape}
					orchard_trees.append(tree); _orchard_by_id[tree_id] = tree
			x += float(step[0])
			column += 1
		z += float(step[1]); row += 1
	# dev 2026-09-26: "merge the apples on SAA all together". The orchard was ~50 tree nodes with
	# three LOD meshes each (~100 draws); now one batch per kind of tree, drawn with continuous
	# index LODs (the engine thins each batch by its size on screen, so no LOD switch shows).
	for id in planted:
		var kind: Dictionary = _species(planted[id][0])
		var xforms: Array[Transform3D] = []
		for t: Transform3D in planted[id][1]: xforms.append(t * kind.local)
		_multimesh("FarmOrchard_" + str(id), kind.mesh, null, xforms)
	if apple_mesh != null:
		_multimesh("FarmApples", _orchard_apple(apple_mesh), null, apples)
		_apple_near = _apple_batch.mesh
		_apple_far = _far_apple(_apple_near)
		_apple_bounds = AABB(apples[0].origin, Vector3.ZERO) if not apples.is_empty() else AABB()
		for t: Transform3D in apples: _apple_bounds = _apple_bounds.expand(t.origin)
		var timer := Timer.new(); timer.name = "FarAppleCheck"; timer.wait_time = 0.5; timer.autostart = true
		timer.timeout.connect(_swap_apple_detail); add_child(timer)
		_swap_apple_detail()

func _swap_apple_detail() -> void:
	var camera := preload("res://world/player_view.gd").camera(self)
	if _apple_batch == null or camera == null: return
	var eye := global_transform.affine_inverse() * camera.global_position
	var nearest := eye.clamp(_apple_bounds.position, _apple_bounds.end)
	var wanted: Mesh = _apple_far if eye.distance_to(nearest) > FAR_APPLES_FROM else _apple_near
	if _apple_batch.mesh != wanted: _apple_batch.mesh = wanted

## An octahedron the apple's size and colour: at 150 m an apple is a pixel or two.
static func _far_apple(near: Mesh) -> Mesh:
	var box := near.get_aabb()
	var colour := Color(0.75, 0.1, 0.08)
	var colours: Variant = near.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	if colours is PackedColorArray and not (colours as PackedColorArray).is_empty():
		var sum := Color(0, 0, 0, 0)
		for c: Color in colours: sum += c
		colour = sum / float((colours as PackedColorArray).size())
	var c := box.get_center(); var h := box.size * 0.5
	var tips := [c + Vector3(h.x, 0, 0), c + Vector3(0, 0, h.z), c - Vector3(h.x, 0, 0), c - Vector3(0, 0, h.z)]
	var top := c + Vector3(0, h.y, 0); var bottom := c - Vector3(0, h.y, 0)
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 4:
		var a: Vector3 = tips[i]; var b: Vector3 = tips[(i + 1) % 4]
		for tri: Array in [[top, b, a], [bottom, a, b]]:
			# Godot's front faces wind clockwise seen from outside.
			var n := (Vector3(tri[1]) - Vector3(tri[0])).cross(Vector3(tri[2]) - Vector3(tri[0])).normalized()
			if n.dot(Vector3(tri[0]) - c) > 0.0: tri.reverse()
			else: n = -n
			for v: Vector3 in tri: st.set_color(colour); st.set_normal(n); st.add_vertex(v)
	return st.commit()

## Same one apple MultiMesh and original tree LOD batches; only instance transforms
## and maturity data change. Runtime updates when the quantized growth changes.
func set_fruit_growth(id: String, growth: float) -> void:
	set_fruit_state(id, growth, _fruit_released.get(id, []))

func set_fruit_state(id: String, growth: float, released: Array) -> void:
	if _apple_batch == null or not _orchard_by_id.has(id): return
	var amount: float = clampf(growth, 0.0, 1.0)
	if is_equal_approx(float(_fruit_growth.get(id, -1.0)), amount) and _fruit_released.get(id, []) == released: return
	_fruit_growth[id] = amount
	_fruit_released[id] = released.duplicate()
	_update_fruit_instances(id)

func _update_fruit_instances(id: String, shake: Transform3D = Transform3D.IDENTITY) -> void:
	var tree: Dictionary = _orchard_by_id[id]
	var amount: float = float(_fruit_growth.get(id, 1.0))
	var released: Array = _fruit_released.get(id, [])
	for index: int in tree.apples.size():
		var original: Transform3D = tree.apples[index]
		var visible_amount: float = .00001 if index in released else maxf(.00001, amount)
		var scaled: Transform3D = shake * Transform3D(original.basis.scaled(Vector3.ONE * visible_amount), original.origin)
		_apple_batch.set_instance_transform(int(tree.first) + index, scaled)
		_apple_batch.set_instance_custom_data(int(tree.first) + index, Color(amount, 0, 0, 1))

func shake_tree(id: String, strength: float = 1.0) -> void:
	if not _orchard_by_id.has(id) or not is_finite(strength) or strength <= 0.0: return
	if not _shakes.has(id) and _shakes.size() >= MAX_SHAKING_TREES: return
	_shakes[id] = {"time":0.0, "strength":clampf(strength, .65, 1.35)}
	set_process(true)

func _process(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0: return
	for id: String in _shakes.keys():
		var state: Dictionary = _shakes[id]
		state.time += minf(delta, .1)
		var tree: Dictionary = _orchard_by_id[id]
		var batch: MultiMeshInstance3D = get_node_or_null(tree.batch) as MultiMeshInstance3D
		var finished: bool = float(state.time) >= SHAKE_SECONDS
		var angle: float = 0.0 if finished else sin(float(state.time) * 32.0) * .012 * float(state.strength) * exp(-float(state.time) * 5.0)
		var pivot: Vector3 = tree.position
		var basis: Basis = Basis(Vector3.RIGHT, angle) * Basis(Vector3.BACK, angle * .6)
		var shake: Transform3D = Transform3D(basis, pivot - basis * pivot)
		if batch != null: batch.multimesh.set_instance_transform(int(tree.instance), shake * Transform3D(tree.render_transform))
		if _apple_batch != null: _update_fruit_instances(id, shake)
		if finished: _shakes.erase(id)
	if _shakes.is_empty(): set_process(false)

func tree_from_hit(hit: Dictionary) -> String:
	var body: CollisionObject3D = hit.get("collider") as CollisionObject3D
	if body == null or body.get_parent() != self or not hit.has("shape"): return ""
	var owner: Object = body.shape_owner_get_owner(body.shape_find_owner(int(hit.shape)))
	return str(owner.get_meta("apple_tree_id", "")) if is_instance_valid(owner) else ""

## One kind of orchard tree: its full-detail mesh with continuous LODs, the mesh's transform in
## the tree scene, and the tree's bounds (for hanging apples).
static var _kinds := {}
static func _species(entry: Dictionary) -> Dictionary:
	var id := str(entry.id)
	if _kinds.has(id): return _kinds[id]
	var result := {}
	var packed: PackedScene = CATALOGUE.scene(entry)
	if packed != null:
		var tree: Node3D = packed.instantiate()
		var level: Node = tree.get_node_or_null("LOD0")
		if level == null:
			for child in tree.get_children():
				if str(child.name).begins_with("LOD0"): level = child; break
		if level == null: level = tree
		var source: MeshInstance3D = level if level is MeshInstance3D else null
		if source == null:
			for mi: MeshInstance3D in level.find_children("*", "MeshInstance3D", true, false): source = mi; break
		var box := AABB(); var first := true
		for mi: MeshInstance3D in tree.find_children("*", "MeshInstance3D", true, false):
			if mi.mesh == null: continue
			var b := _relative(tree, mi) * mi.get_aabb()
			box = b if first else box.merge(b); first = false
		if source != null:
			result = {"mesh": _with_lods(source.mesh, source), "local": _relative(tree, source), "box": box}
		tree.free()
	_kinds[id] = result
	return result

static func _relative(root: Node, node: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var at := node
	while at != null and at != root:
		if at is Node3D: t = (at as Node3D).transform * t
		at = at.get_parent()
	return t

## The mesh with its materials baked in and continuous index LODs generated.
static func _with_lods(mesh: Mesh, node: MeshInstance3D) -> Mesh:
	var importer := ImporterMesh.new()
	for s in mesh.get_surface_count():
		importer.add_surface(mesh.surface_get_primitive_type(s), mesh.surface_get_arrays(s), [], {}, node.get_active_material(s),
			"", _keep_flags(mesh, s))
	importer.generate_lods(60.0, 25.0, [])
	return importer.get_mesh()

## The custom-channel formats and 8-weight flag of a surface: the Grassy Fields trees carry wind
## data in CUSTOM0, whose arrays are rejected unless the format says what they hold.
static func _keep_flags(mesh: Mesh, surface: int) -> int:
	var custom := 0
	for shift in [Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT]:
		custom |= Mesh.ARRAY_FORMAT_CUSTOM_MASK << shift
	var format := (mesh as ArrayMesh).surface_get_format(surface) if mesh is ArrayMesh else 0
	return format & (custom | Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)

## The hand-held apple is 2,520 triangles; hanging in a crown, 1,728 of them were 4.35 M
## triangles in one view (dev's snapshot 2026-09-25). The orchard uses a simplified copy
## (same material, same silhouette at arm's length) of ~150 triangles; the one you pick up
## is still the full apple.
const ORCHARD_APPLE_TRIANGLES := 160
static var _low_apple: Mesh
static func _orchard_apple(source: Mesh) -> Mesh:
	if _low_apple != null: return _low_apple
	var importer := ImporterMesh.new()
	for s in source.get_surface_count():
		importer.add_surface(source.surface_get_primitive_type(s), source.surface_get_arrays(s), [], {}, source.surface_get_material(s))
	importer.generate_lods(60.0, 25.0, [])
	var out := ArrayMesh.new()
	for s in importer.get_surface_count():
		var arrays := importer.get_surface_arrays(s)
		var budget := maxi(12, ORCHARD_APPLE_TRIANGLES * (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3 / maxi(1, _triangles(source)))
		for lod in importer.get_surface_lod_count(s):
			var indices := importer.get_surface_lod_indices(s, lod)
			arrays[Mesh.ARRAY_INDEX] = indices
			if indices.size() / 3 <= budget: break
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(s, importer.get_surface_material(s))
	# and continuous LODs below that, so apples far off thin out without a visible switch
	var thinner := ImporterMesh.new()
	for s in out.get_surface_count():
		thinner.add_surface(Mesh.PRIMITIVE_TRIANGLES, out.surface_get_arrays(s), [], {}, out.surface_get_material(s))
	thinner.generate_lods(60.0, 25.0, [])
	_low_apple = thinner.get_mesh()
	return _low_apple

static func _triangles(mesh: Mesh) -> int:
	var n := 0
	for s in mesh.get_surface_count(): n += (mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	return n

## Apples on the outside of the crown: points on the upper part of the tree's bounds.
func _hang_apples(tree: Transform3D, box: AABB, apples: Array[Transform3D], rng: RandomNumberGenerator, count: int, apple_scale: float) -> void:
	if box.size == Vector3.ZERO: return
	var crown_bottom := box.position.y + box.size.y * 0.4
	var centre := Vector3(box.get_center().x, (crown_bottom + box.end.y) * 0.5, box.get_center().z)
	var radii := Vector3(box.size.x * 0.42, (box.end.y - crown_bottom) * 0.46, box.size.z * 0.42)
	for i in count:
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.55, 1), rng.randf_range(-1, 1)).normalized()
		var local := centre + dir * radii * rng.randf_range(0.82, 1.0)
		var world := tree * local
		apples.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * apple_scale), world))
