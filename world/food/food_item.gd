extends Node3D
## Visual wrapper for one portion. The container is never scaled down or eaten.
signal acquired
const IDENTITY := preload("res://world/inventory/item_identity.gd")
const MERGE := preload("res://world/food/food_mesh_merge.gd")
## Off restores the original one-node-per-part models (comparison/rollback).
static var merge_parts: bool = true
@export var food_id: String = ""
## Another food's model to show (definitions.json "model"); empty uses this food's own.
@export var model_slug: String = ""
var bounds: AABB
var edible_bounds: AABB
var _full_bounds: AABB
var _model: Node3D
var _edible: Array[MeshInstance3D] = []
var _containers: Array[MeshInstance3D] = []
var _bite_sources: Dictionary = {}
var _bite_anchor := Vector3.ZERO

func prepare() -> bool:
	if _model != null:
		return true
	food_id = IDENTITY.canonical(food_id)
	var slug: String = model_slug if not model_slug.is_empty() else IDENTITY.food_slug(food_id)
	var path: String = "res://world/props/food/" + slug + ".scn"
	if food_id in ["apple", "carrot"]:
		path = "res://world/inventory/assets/%s.tscn" % food_id
	if not ResourceLoader.exists(path):
		return false
	var measured: Array[AABB] = []
	var baked: Dictionary = MERGE.merged(path, food_id in ["apple", "carrot"]) if merge_parts else {}
	if not baked.is_empty():
		# Same triangles and materials, one draw per material instead of one per part.
		_model = Node3D.new()
		_model.name = "MergedFood"
		for part: Dictionary in baked.parts:
			var mesh: MeshInstance3D = MeshInstance3D.new()
			mesh.name = "%s_merged" % part.role
			mesh.mesh = part.mesh
			mesh.cast_shadow = part.shadow
			_model.add_child(mesh)
			if part.role == "edible":
				_edible.append(mesh)
			elif part.role == "container":
				_containers.append(mesh)
		add_child(_model)
		measured.append(baked.bounds)
	else:
		var packed: PackedScene = load(path)
		_model = packed.instantiate()
		add_child(_model)
		_collect(_model, Transform3D.IDENTITY, measured)
		if food_id in ["apple", "carrot"]:
			for mesh: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false):
				_edible.append(mesh)
	if measured.is_empty():
		return false
	var original: AABB = measured[0]
	for box: AABB in measured:
		original = original.merge(box)
	_model.position -= original.get_center()
	bounds = AABB(-original.size * 0.5, original.size)
	MERGE.fade_out_far(_model, maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z)))
	edible_bounds = bounds
	_full_bounds = bounds
	if food_id.begins_with("food-empty:"):
		show_empty()
	return true

func _collect(node: Node3D, parent_transform: Transform3D, measured: Array[AABB]) -> void:
	var transform_local: Transform3D = parent_transform * node.transform
	if node is MeshInstance3D and node.mesh != null:
		measured.append(transform_local * node.mesh.get_aabb())
		var at: Node = node
		while at != self and at != null:
			if str(at.name).begins_with("edible_"):
				_edible.append(node)
				break
			if str(at.name).begins_with("container_"):
				_containers.append(node)
				break
			at = at.get_parent()
	for child: Node in node.get_children():
		if child is Node3D:
			_collect(child, transform_local, measured)

func configure_body(body: RigidBody3D, collision: CollisionShape3D) -> bool:
	if not prepare():
		return false
	var shape: BoxShape3D = BoxShape3D.new()
	# Very thin cheese/lettuce still have a stable grasp/physics slab.
	shape.size = bounds.size.max(Vector3.ONE * 0.012)
	collision.shape = shape
	collision.position = bounds.get_center()
	body.set_meta("food_bounds", AABB(collision.position - shape.size * 0.5, shape.size))
	body.set_meta("food_visual", self)
	return true

func show_empty() -> void:
	for mesh: MeshInstance3D in _edible:
		mesh.hide()
	# Remain centred exactly where held: only collision extents change.
	var measured: bool = false
	for mesh: MeshInstance3D in _containers:
		var relative: Transform3D = _relative_transform(mesh)
		var box: AABB = relative * mesh.mesh.get_aabb()
		bounds = bounds.merge(box) if measured else box
		measured = true

## Filled again (a cider mug refilled at a keg, world/items/cider_keg.gd).
func show_full() -> void:
	if not prepare(): return
	for mesh: MeshInstance3D in _edible:
		mesh.show()
	bounds = _full_bounds
	edible_bounds = _full_bounds

## A completed bite changes size once. Scale all edible parts about their common base so
## frosting/toppings stay together; the real paper wrapper retains its authored transform.
func set_bite_stage(stage: int) -> void:
	if not prepare() or _edible.is_empty(): return
	if _bite_sources.is_empty():
		var original: AABB
		var measured := false
		for mesh: MeshInstance3D in _edible:
			var relative: Transform3D = _relative_transform(mesh)
			_bite_sources[mesh] = relative
			var box: AABB = relative * mesh.mesh.get_aabb()
			original = original.merge(box) if measured else box
			measured = true
		_bite_anchor = Vector3(original.get_center().x, original.position.y, original.get_center().z)
	var amount := pow(0.78, clampi(stage, 0, 2))
	var shrink := Transform3D(Basis.from_scale(Vector3.ONE * amount), _bite_anchor * (1.0 - amount))
	var measured := false
	for mesh: MeshInstance3D in _edible:
		var authored: Transform3D = _bite_sources[mesh]
		var relative: Transform3D = shrink * authored
		var parent_relative: Transform3D = _relative_transform(mesh.get_parent() as Node3D)
		mesh.transform = parent_relative.affine_inverse() * relative
		var box: AABB = relative * mesh.mesh.get_aabb()
		edible_bounds = edible_bounds.merge(box) if measured else box
		measured = true
	bounds = edible_bounds
	for mesh: MeshInstance3D in _containers:
		bounds = bounds.merge(_relative_transform(mesh) * mesh.mesh.get_aabb())

func _relative_transform(node: Node3D) -> Transform3D:
	var result: Transform3D = Transform3D.IDENTITY
	var at: Node = node
	while at != self and at is Node3D:
		result = at.transform * result
		at = at.get_parent()
	return result

func mouth_local() -> Vector3:
	# Cups meet the mouth at their rim/straw; solid servings at their upper edge.
	return Vector3(bounds.get_center().x, bounds.end.y, bounds.get_center().z)

func edible_mesh_count() -> int:
	return _edible.size()

func container_mesh_count() -> int:
	return _containers.size()

func visible_edible_count() -> int:
	var count: int = 0
	for mesh: MeshInstance3D in _edible:
		if mesh.visible:
			count += 1
	return count
