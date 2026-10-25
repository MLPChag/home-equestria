extends RefCounted
## Candle clusters scattered on home tables (dev 2026-09-28). Seeded per home and table, so a
## house always has the same candles. Houses call scatter() once furnished; homes built by hand
## (Cloudominium) call cluster() at their own table tops.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const CLUSTER := preload("res://world/props/candles/candle_cluster.gd")
## Furniture kit ids with a flat top a candle may stand on, and the chance each gets a cluster.
const TABLES := {"bedside-table": 0.75, "coffee-table": 0.7, "round-cafe-table": 0.6, "dresser": 0.5}
const SIZES := [1, 1, 3, 3, 4]

## One cluster of `count` candles standing at `at` (global transform, candle bases on its origin).
static func cluster(parent: Node, at: Transform3D, rng: RandomNumberGenerator, count := 0) -> Node3D:
	var node := CLUSTER.new()
	node.name = "Candles"
	parent.add_child(node)
	node.global_transform = Transform3D(Basis(Vector3.UP, rng.randf() * TAU), at.origin)
	node.build(count if count > 0 else SIZES[rng.randi() % SIZES.size()], rng)
	return node

## Clusters on the tables among `root`'s furniture (group house_furniture, meta furniture),
## seeded by `key`. Waits two physics frames so the tables' collision is in the space, then drops
## a ray on a random spot of each top; spots where something else stands higher are retried.
static func scatter(root: Node, key: String) -> void:
	if not is_instance_valid(root) or not root.is_inside_tree(): return
	var tree := root.get_tree()
	if not await SHUTDOWN.physics_frame(root) or not await SHUTDOWN.physics_frame(root): return
	if not is_instance_valid(root) or not root.is_inside_tree(): return
	var space := (root as Node3D).get_world_3d().direct_space_state if root is Node3D else null
	var index := 0
	for table: Node in tree.get_nodes_in_group("house_furniture"):
		if not root.is_ancestor_of(table) or not table is Node3D: continue
		if bool(table.get_meta("welcome_table", false)): continue
		var id := str(table.get_meta("furniture", ""))
		if not TABLES.has(id): continue
		index += 1
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(key + ":" + id + ":" + str(index))
		if rng.randf() > float(TABLES[id]): continue
		var box := _global_box(table as Node3D)
		if box.size.length_squared() < .0001: continue
		for attempt in 6:
			var point := Vector3(lerpf(box.position.x + box.size.x * 0.22, box.end.x - box.size.x * 0.22, rng.randf()),
				box.end.y, lerpf(box.position.z + box.size.z * 0.22, box.end.z - box.size.z * 0.22, rng.randf()))
			var top := box.end.y
			if space != null:
				var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(point + Vector3.UP * 0.4, point - Vector3.UP * 0.35, 1))
				if not hit.is_empty():
					if float(hit.position.y) > box.end.y + 0.02 or Vector3(hit.normal).y < 0.9: continue
					top = float(hit.position.y)
			cluster(table, Transform3D(Basis.IDENTITY, Vector3(point.x, top, point.z)), rng)
			break

static func _global_box(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null or mi.name == "Candles": continue
		var b := mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box
