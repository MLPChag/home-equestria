extends RefCounted
## The drawn top of a bed, for bodies that lie on it (dev 2026-09-28: "make sure the mares TOUCH
## the bed not float off of it. slightly clip into the bed as to simulate depressing into the foam").
## The physics mattress is one flat box at the blanket's 70th-percentile height (pony_bed: 0.563 m,
## while half the blanket lies below 0.534 m), so a body resting on it floats over the dips.
## Each bed mesh's level triangles are rasterised once into a 4 cm height grid, shared by every bed
## that uses the same mesh; lying bodies are placed against that visible surface instead.
const CELL := 0.04
## How far a resting body presses into the foam, metres.
const SINK := 0.025
## Drawn heights further than this from the physics mattress are pillows' sides, posts or frames.
const TRUST := 0.15
static var _grids: Dictionary = {}

## The bed a physics hit belongs to: the nearest ancestor carrying `mattress_top` (house, Golden Oak,
## Zecora and Trixie beds) or `soft_support`. Null for floors, sofas and everything else.
static func bed_of(hit: Object) -> Node3D:
	var node: Node = hit as Node
	for _step: int in 4:
		if node == null: return null
		if node is Node3D and (node.has_meta("mattress_top") or node.has_meta("soft_support")): return node as Node3D
		node = node.get_parent()
	return null

## Mean drawn bedding height (world y) under `points`; `fallback` (the physics top) where none is drawn.
static func visible_top(bed: Node3D, points: Array[Vector3], fallback: float) -> float:
	var meshes: Array[Node] = bed.find_children("*", "MeshInstance3D", true, false)
	var total := 0.0
	var count := 0
	for point: Vector3 in points:
		var best := -INF
		for node: Node in meshes:
			var drawn := node as MeshInstance3D
			if drawn.mesh == null or not drawn.is_visible_in_tree(): continue
			# Thin decals laid over the blanket (Twilight's stars) are drawn on it, not bedding.
			if drawn.mesh.get_aabb().size.y < 0.02: continue
			var grid: Dictionary = _grid(drawn.mesh)
			var local: Vector3 = drawn.global_transform.affine_inverse() * point
			var key := Vector2i(floori(local.x / CELL), floori(local.z / CELL))
			if not grid.has(key): continue
			best = maxf(best, (drawn.global_transform * Vector3(local.x, float(grid[key]), local.z)).y)
		if best > -INF and absf(best - fallback) <= TRUST:
			total += best
			count += 1
	return total / count if count > 0 else fallback

## Highest level (|normal.y| >= 0.5) triangle height per 4 cm cell, in the mesh's own frame.
static func _grid(mesh: Mesh) -> Dictionary:
	var id := mesh.get_instance_id()
	if _grids.has(id): return _grids[id]
	var grid := {}
	var faces: PackedVector3Array = mesh.get_faces()
	for i in range(0, faces.size() - 2, 3):
		var a: Vector3 = faces[i]
		var b: Vector3 = faces[i + 1]
		var c: Vector3 = faces[i + 2]
		var normal := (b - a).cross(c - a)
		if normal.length_squared() < 1e-12 or absf(normal.normalized().y) < 0.5: continue
		var a2 := Vector2(a.x, a.z)
		var v0 := Vector2(b.x, b.z) - a2
		var v1 := Vector2(c.x, c.z) - a2
		var area := v0.x * v1.y - v1.x * v0.y
		if absf(area) < 1e-10: continue
		var lo := a2.min(Vector2(b.x, b.z)).min(Vector2(c.x, c.z))
		var hi := a2.max(Vector2(b.x, b.z)).max(Vector2(c.x, c.z))
		var covered := false
		for x in range(floori(lo.x / CELL), floori(hi.x / CELL) + 1):
			for z in range(floori(lo.y / CELL), floori(hi.y / CELL) + 1):
				var w := Vector2((x + 0.5) * CELL, (z + 0.5) * CELL) - a2
				var s := (w.x * v1.y - v1.x * w.y) / area
				var t := (v0.x * w.y - w.x * v0.y) / area
				if s < 0.0 or t < 0.0 or s + t > 1.0: continue
				_raise(grid, Vector2i(x, z), a.y + s * (b.y - a.y) + t * (c.y - a.y))
				covered = true
		if not covered:
			# Smaller than a cell: its centre still counts, so fine folds are not lost.
			var centre := (a + b + c) / 3.0
			_raise(grid, Vector2i(floori(centre.x / CELL), floori(centre.z / CELL)), centre.y)
	_grids[id] = grid
	return grid

static func _raise(grid: Dictionary, key: Vector2i, height: float) -> void:
	if not grid.has(key) or float(grid[key]) < height: grid[key] = height
