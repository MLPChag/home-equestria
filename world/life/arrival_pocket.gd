extends Node3D
## Where Anon wakes (dev 2026-10-01): the middle of the dense Everfree, far from every trail.
## Nothing is cut down: a natural gap among the real streamed trunks is found at run time
## (BiomeFoliage tree_colliders), with a mossy stump and three apples in it, thorn bushes in the
## gaps between the trees around it and one fallen log where Twilight will come in. An invisible
## wall on its own physics layer keeps only Anon inside until she arrives; ponies never collide
## with it.
const FOOD_SPAWN := preload("res://world/food/food_spawn.gd")
const LAYER := 1 << 23
const RADIUS := 4.2
const STUMP := "res://world/props/rnl/rnl_treestump/prefab.scn"
const THORNS := "res://world/props/rnl/nature__ss_everfree_thorns_01/prefab.scn"
const LOG := "res://world/props/rnl/rnl_bigtreelog/prefab.scn"
## A gap is free of trunks out to this distance from its centre.
const FREE := 3.6
var centre := Vector3.INF
var facing := Vector3.FORWARD     # from where Anon lies toward the stump
var stump_top := Vector3.INF
var gate := Vector3.INF           # where the fallen log lies and Twilight comes in
var gate_dir := Vector3.FORWARD
var log_node: Node3D
var _wall: StaticBody3D
var _player_body: CollisionObject3D

## Trunk centres (flat) within `reach` of `at`, read from the streamed foliage cells.
static func trunks(at: Vector3, reach: float) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if not is_instance_valid(WorldTerrain.instance): return result
	var foliage := WorldTerrain.instance.get_node_or_null("BiomeFoliage")
	if foliage == null: return result
	for holder: Node in foliage.get_children():
		if not holder is Node3D or not holder.has_meta("tree_colliders"): continue
		var origin: Vector3 = (holder as Node3D).global_position
		var half: float = BiomeFoliage.CELL * 0.5
		if Vector2(origin.x + half, origin.z + half).distance_to(Vector2(at.x, at.z)) > reach + BiomeFoliage.CELL: continue
		for spec: Array in holder.get_meta("tree_colliders"):
			var p: Vector3 = origin + Vector3(spec[0])
			if Vector2(p.x, p.z).distance_to(Vector2(at.x, at.z)) <= reach: result.append(p)
	return result

## The best gap near `near`: free of trunks for FREE metres, gently sloped, with as many trees
## around it as possible. INF until the foliage near `near` has streamed in.
static func find(near: Vector3) -> Vector3:
	var all := trunks(near, 60.0)
	if all.size() < 12: return Vector3.INF
	var best := Vector3.INF
	var best_score := -INF
	for ring in range(0, 13):
		var steps := maxi(1, ring * 6)
		for i in steps:
			var angle := TAU * float(i) / float(steps)
			var p := near + Vector3(cos(angle), 0.0, sin(angle)) * float(ring) * 3.0
			var h := WorldTerrain.instance.height_at(p)
			if not is_finite(h): continue
			var flat := true
			for k in 8:
				var q := p + Vector3(cos(k * TAU / 8.0), 0.0, sin(k * TAU / 8.0)) * RADIUS
				var hq := WorldTerrain.instance.height_at(q)
				if not is_finite(hq) or absf(hq - h) > 0.7: flat = false; break
			if not flat: continue
			var nearest := INF
			var around := 0
			for t: Vector3 in all:
				var d := Vector2(t.x, t.z).distance_to(Vector2(p.x, p.z))
				nearest = minf(nearest, d)
				if d < 11.0: around += 1
			if nearest < FREE: continue
			var score := float(around) - float(ring) * 0.15
			if score > best_score: best_score = score; best = Vector3(p.x, h, p.z)
	return best

func build(game: Node, at: Vector3, player_body: Node) -> void:
	name = "ArrivalPocket"
	centre = at
	var around := trunks(at, 14.0)
	# Twilight's way in: the widest gap between trees around the pocket.
	var best_gap := -INF
	for k in 16:
		var dir := Vector3(cos(k * TAU / 16.0), 0.0, sin(k * TAU / 16.0))
		var clear := INF
		for t: Vector3 in around:
			var rel := Vector2(t.x - at.x, t.z - at.z)
			var along := rel.dot(Vector2(dir.x, dir.z))
			if along < 1.0: continue
			clear = minf(clear, absf(rel.cross(Vector2(dir.x, dir.z))))
		if clear > best_gap: best_gap = clear; gate_dir = dir
	gate = _ground(at + gate_dir * (RADIUS + 0.4))
	# Anon lies across from the gate, feet toward the stump in the middle.
	facing = gate_dir
	var stump_at := _ground(at + gate_dir * 0.6)
	var stump := _prop(STUMP, stump_at, randf() * TAU, 1.05)
	var top := stump_at.y + 0.5
	if stump != null:
		var box := _bounds(stump)
		top = box.end.y
		_stump_collision(stump)
	stump_top = Vector3(stump_at.x, top, stump_at.z)
	for i in 3:
		var offset := Vector3(cos(i * 2.1) * 0.12, 0.0, sin(i * 2.1) * 0.12)
		var apple := FOOD_SPAWN.spawn(game, "food:red-apple", Transform3D(Basis.IDENTITY, stump_top + offset), false)
		if apple != null: apple.add_to_group("arrival_apples")
	# The fallen log blocks the gate; thorns fill the other gaps between trunks.
	log_node = _prop(LOG, gate, atan2(gate_dir.x, gate_dir.z), 2.6)
	for k in 10:
		var angle := TAU * float(k) / 10.0 + 0.3
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		if dir.dot(gate_dir) > 0.8: continue
		var spot := at + dir * (RADIUS + 0.3)
		var blocked := false
		for t: Vector3 in around:
			if Vector2(t.x - spot.x, t.z - spot.z).length() < 1.2: blocked = true; break
		if not blocked: _prop(THORNS, _ground(spot), randf() * TAU, 1.3)
	_build_wall(at)
	_clear_undergrowth(at, RADIUS - 0.6)
	_light(stump_at)
	_player_body = player_body as CollisionObject3D
	if _player_body != null: _player_body.collision_mask |= LAYER

## Match the accepted stump mesh instead of inflating a cylinder from its rotated
## world AABB. Built once for this static prop; no per-frame mesh or shape work.
func _stump_collision(stump: Node3D) -> StaticBody3D:
	var body := StaticBody3D.new(); body.name = "StumpBody"
	add_child(body)
	for node: Node in [stump] + stump.find_children("*", "MeshInstance3D", true, false):
		if not node is MeshInstance3D or node.mesh == null: continue
		var shape := CollisionShape3D.new()
		shape.shape = node.mesh.create_trimesh_shape()
		body.add_child(shape)
		shape.global_transform = node.global_transform
	return body

## Ring of tall boxes on LAYER: only Anon's body masks it, and only while the pocket holds him.
func _build_wall(at: Vector3) -> void:
	_wall = StaticBody3D.new(); _wall.name = "PocketWall"
	_wall.collision_layer = LAYER; _wall.collision_mask = 0
	add_child(_wall); _wall.global_position = at
	var count := 24
	for i in count:
		var angle := TAU * float(i) / float(count)
		var shape := CollisionShape3D.new(); var box := BoxShape3D.new()
		box.size = Vector3(TAU * RADIUS / float(count) + 0.3, 6.0, 0.3)
		shape.shape = box
		shape.position = Vector3(cos(angle), 0.0, sin(angle)) * RADIUS + Vector3.UP * 1.5
		shape.rotation.y = -angle + PI * 0.5
		_wall.add_child(shape)

## Bushes and ferns standing inside the pocket would hide the stump and fill the first view.
## Only undergrowth instances are hidden (trees and their colliders are untouched), and only
## while the pocket exists; a rebuilt foliage cell brings them back.
var _hidden_plants: Array = []
func _clear_undergrowth(at: Vector3, radius: float) -> void:
	if not is_instance_valid(WorldTerrain.instance): return
	var foliage := WorldTerrain.instance.get_node_or_null("BiomeFoliage")
	if foliage == null: return
	for holder: Node in foliage.get_children():
		if not holder is Node3D: continue
		if Vector2((holder as Node3D).global_position.x + BiomeFoliage.CELL * 0.5, (holder as Node3D).global_position.z + BiomeFoliage.CELL * 0.5).distance_to(Vector2(at.x, at.z)) > BiomeFoliage.CELL + radius: continue
		for child: Node in holder.get_children():
			var mmi := child as MultiMeshInstance3D
			if mmi == null or mmi.multimesh == null: continue
			var mm := mmi.multimesh
			for i in mm.instance_count:
				var p: Vector3 = mmi.global_transform * mm.get_instance_transform(i).origin
				if Vector2(p.x - at.x, p.z - at.z).length() < radius:
					_hidden_plants.append([mm, i, mm.get_instance_transform(i)])
					mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.0001), mm.get_instance_transform(i).origin))

## A soft beam of daylight through the canopy onto the stump, and a little fill around it, so
## the deep forest is readable without lighting the whole Everfree.
func _light(stump_at: Vector3) -> void:
	var beam := SpotLight3D.new(); beam.name = "CanopyBeam"
	beam.light_color = Color(1.0, 0.95, 0.82); beam.light_energy = 4.0; beam.spot_range = 26.0
	beam.spot_angle = 16.0; beam.spot_angle_attenuation = 0.6; beam.shadow_enabled = false
	add_child(beam)
	beam.global_transform = Transform3D(Basis.looking_at(Vector3.DOWN + Vector3(0.12, 0, 0.08), Vector3.FORWARD), stump_at + Vector3(-1.4, 18.0, -1.0))
	var fill := OmniLight3D.new(); fill.name = "PocketFill"
	fill.light_color = Color(0.86, 0.96, 0.9); fill.light_energy = 0.7; fill.omni_range = 9.0; fill.shadow_enabled = false
	add_child(fill); fill.global_position = centre + Vector3.UP * 2.6

func _restore_undergrowth() -> void:
	for row: Array in _hidden_plants:
		var mm: MultiMesh = row[0]
		if is_instance_valid(mm) and int(row[1]) < mm.instance_count: mm.set_instance_transform(int(row[1]), row[2])
	_hidden_plants.clear()

func open() -> void:
	if is_instance_valid(_player_body): _player_body.collision_mask &= ~LAYER
	if is_instance_valid(_wall): _wall.queue_free()

func _exit_tree() -> void:
	if is_instance_valid(_player_body): _player_body.collision_mask &= ~LAYER
	_restore_undergrowth()

func _ground(p: Vector3) -> Vector3:
	var h := WorldTerrain.instance.height_at(p) if is_instance_valid(WorldTerrain.instance) else p.y
	return Vector3(p.x, h if is_finite(h) else p.y, p.z)

## A prop scaled so its longest side is `size` metres, standing on the ground at `at`.
func _prop(path: String, at: Vector3, yaw: float, size: float) -> Node3D:
	var packed := load(path) as PackedScene
	if packed == null: return null
	var node := packed.instantiate() as Node3D
	if node == null: return null
	# Decoration only: the walk grid must not cache the log or thorns as walls (Twilight's
	# route in was refused once the log had been lifted away). The stump gets its own collider.
	for body: Node in node.find_children("*", "CollisionObject3D", true, false):
		(body as CollisionObject3D).collision_layer = 0; (body as CollisionObject3D).collision_mask = 0
	if node is CollisionObject3D: (node as CollisionObject3D).collision_layer = 0
	add_child(node)
	var box := _bounds(node)
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	var scale_by := size / longest if longest > 0.001 else 1.0
	node.global_transform = Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale_by), at)
	box = _bounds(node)
	node.global_position.y += at.y - box.position.y - 0.05
	return node

func _bounds(node: Node3D) -> AABB:
	var result := AABB(); var first := true
	for mesh: Node in node.find_children("*", "MeshInstance3D", true, false):
		var mi := mesh as MeshInstance3D
		if mi.mesh == null: continue
		var box: AABB = mi.global_transform * mi.mesh.get_aabb()
		result = box if first else result.merge(box); first = false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var own: AABB = node.global_transform * (node as MeshInstance3D).mesh.get_aabb()
		result = own if first else result.merge(own)
	return result
