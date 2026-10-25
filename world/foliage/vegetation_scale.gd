class_name VegetationScale
extends RefCounted
## Shared deterministic, human-scale policy for native and generated foliage.

const BUSH_MIN_HEIGHT := 0.6
const BUSH_MAX_HEIGHT := 1.6
const FERN_MIN_HEIGHT := 0.3
const FERN_MAX_HEIGHT := 0.6
const GRASS_MIN_HEIGHT := 0.1
const GRASS_MAX_HEIGHT := 0.35
const BRAMBLE_MIN_HEIGHT := 1.2
const BRAMBLE_MAX_HEIGHT := 1.9
const TREE_MIN_SPAN := 12.0
const TREE_MAX_SPAN := 22.0
const HERO_TREE_MIN_SPAN := 24.0
const HERO_TREE_MAX_SPAN := 28.0
const HERO_TREE_CHANCE := 0.06
const APPLIED_META := &"human_scale_v1"
const GROUNDCOVER_META := &"groundcover_scale_v2"


static func source_scale_requested() -> bool:
	return "--vegetation-source-scale" in preload("res://world/dev_tools.gd").user_args()


static func scale_class(name: String, category := "") -> String:
	var lower := name.to_lower()
	if category == "tree" or lower.begins_with("everfreetree") or lower.begins_with("tree0"):
		return "tree"
	if lower.contains("grass") or lower.contains("groundcover"): return "grass"
	if lower.begins_with("fern"): return "fern"
	if lower.contains("bramble") or lower.contains("thorn"):
		return "bramble"
	return "bush"


static func scale_for_bounds(bounds: AABB, name: String, at: Vector2, category := "") -> float:
	if _is_landmark(name): return 1.0
	var kind := scale_class(name, category)
	if kind == "tree":
		var span := maxf(bounds.size.x, bounds.size.z)
		if span <= 0.001: return 1.0
		var hero := _unit(at, name, 17) < HERO_TREE_CHANCE
		var target := lerpf(HERO_TREE_MIN_SPAN, HERO_TREE_MAX_SPAN, _unit(at, name, 19)) if hero else lerpf(TREE_MIN_SPAN, TREE_MAX_SPAN, _unit(at, name, 19))
		return minf(1.0, target / span)
	var height := bounds.size.y
	if height <= 0.001: return 1.0
	var low := BRAMBLE_MIN_HEIGHT if kind == "bramble" else FERN_MIN_HEIGHT if kind == "fern" else GRASS_MIN_HEIGHT if kind == "grass" else BUSH_MIN_HEIGHT
	var high := BRAMBLE_MAX_HEIGHT if kind == "bramble" else FERN_MAX_HEIGHT if kind == "fern" else GRASS_MAX_HEIGHT if kind == "grass" else BUSH_MAX_HEIGHT
	return minf(1.0, lerpf(low, high, _unit(at, name, 23)) / height)


## Scale a native subtree before its collision is built; preserve its visual bottom.
static func apply_native(node: Node3D, category := "", identity := "") -> float:
	if node.has_meta(APPLIED_META): return float(node.get_meta(APPLIED_META))
	var before := visual_bounds(node)
	# ZoneProcessor also runs while a fresh scene is detached from the tree, where
	# Godot deliberately has no global transform.  The full local path is stable
	# in both the baker and live runtime and is sufficient for deterministic picks.
	var at := local_origin(node)
	var factor := scale_for_bounds(before, identity if not identity.is_empty() else String(node.name), at, category)
	if not is_equal_approx(factor, 1.0):
		node.scale *= factor
		var after := visual_bounds(node)
		# Bounds are in detached scene-root space. Convert the correction through
		# the parent basis so rotated/scaled imported parents retain the visual base.
		var root_delta := Vector3(0, before.position.y - after.position.y, 0)
		node.position += parent_basis(node).inverse() * root_delta
	node.set_meta(APPLIED_META, factor)
	return factor

static func refine_groundcover(node: Node3D, identity := "") -> float:
	if source_scale_requested() or node.has_meta(GROUNDCOVER_META): return 1.0
	var name := identity if not identity.is_empty() else String(node.name)
	var kind := scale_class(name)
	if (kind != "fern" and kind != "grass") or _is_landmark(name): return 1.0
	var before := visual_bounds(node)
	if before.size.y <= 0.001: return 1.0
	var low := FERN_MIN_HEIGHT if kind == "fern" else GRASS_MIN_HEIGHT
	var high := FERN_MAX_HEIGHT if kind == "fern" else GRASS_MAX_HEIGHT
	var factor := minf(1.0, lerpf(low, high, _unit(local_origin(node), name, 97)) / before.size.y)
	if factor < 0.999:
		node.scale *= factor
		var after := visual_bounds(node)
		node.position += parent_basis(node).inverse() * Vector3(0, before.position.y - after.position.y, 0)
		node.set_meta(GROUNDCOVER_META, factor)
	return factor


static func visual_bounds(node: Node3D) -> AABB:
	var found := false
	var result := AABB()
	# ZoneProcessor works on detached scenes: construct the complete local chain
	# rather than reading Godot's unavailable global_transform.
	var stack: Array = [[node, local_transform(node)]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var current := item[0] as Node
		var transform: Transform3D = item[1]
		if current is MeshInstance3D:
			var mesh_node := current as MeshInstance3D
			if mesh_node.mesh != null and mesh_node.visible:
				var box := transform * mesh_node.get_aabb()
				result = box if not found else result.merge(box)
				found = true
		for child in current.get_children():
			stack.append([child, transform * child.transform if child is Node3D else transform])
	return result


static func local_origin(node: Node3D) -> Vector2:
	var origin := local_transform(node).origin
	return Vector2(origin.x, origin.z)


static func local_transform(node: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null:
		if current is Node3D: result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


static func parent_basis(node: Node3D) -> Basis:
	var parent := node.get_parent()
	return local_transform(parent as Node3D).basis if parent is Node3D else Basis.IDENTITY


static func _is_landmark(name: String) -> bool:
	var lower := name.to_lower()
	return lower.contains("zecora") or lower.contains("hut") or lower.contains("bridge") or lower.contains("entrance")


static func _unit(at: Vector2, name: String, salt: int) -> float:
	var h: int = (floori(at.x * 31.0) * 73856093) ^ (floori(at.y * 31.0) * 19349663) ^ (name.hash() * 83492791) ^ salt
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	return float(h % 100000) / 100000.0
