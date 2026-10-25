extends RefCounted
## Shared physical surface queries; rendered waves never become solid floors.
const MASK := 1 << 15

static func surface_above(space: PhysicsDirectSpaceState3D, point: Vector3) -> float:
	if not point.is_finite(): return -INF
	var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 2048.0, point, MASK)
	query.hit_back_faces = true
	var hit := space.intersect_ray(query)
	return float(hit.position.y) if not hit.is_empty() else -INF

## Run once per staged scene part, before its bodies enter the physics space.
## Older bakes did not persist the water group and kept layer-1 river collision.
static func prepare_native(node: Node, patterns: Array, prefix := "", inherited := false) -> void:
	var path := prefix.path_join(str(node.name))
	var water := inherited or node.is_in_group("navigation_water")
	for pattern in patterns:
		var p := str(pattern)
		if path == p or path.ends_with("/" + p) or path.contains("/" + p + "/") or path.begins_with(p + "/"):
			water = true; break
	if water and node is MeshInstance3D:
		node.add_to_group("navigation_water", true)
	if water and node is StaticBody3D:
		node.collision_layer = MASK
		node.collision_mask = 0
	for child in node.get_children(): prepare_native(child, patterns, path, water)
