extends RefCounted
## Spawn one physical portion on a caller-selected surface; paid unless explicitly free.
const CATALOG: Script = preload("res://world/food/food_catalog.gd")

static func spawn(parent: Node3D, id: String, surface: Transform3D, for_sale: bool = true) -> RigidBody3D:
	id = CATALOG.IDENTITY.canonical(id)
	if not is_instance_valid(parent) or not parent.is_inside_tree() or not surface.is_finite():
		return null
	var packed: PackedScene = CATALOG.scene(id)
	if packed == null:
		return null
	var visual: Node3D = packed.instantiate()
	var item: RigidBody3D = RigidBody3D.new()
	item.name = "Food_" + CATALOG.slug(id).replace("-", "_")
	item.set_meta("item_id", id)
	item.set_meta("food_for_sale", for_sale)
	item.collision_layer = 1 << 17
	item.collision_mask = 1
	item.mass = float(CATALOG.definition(id).get("mass", 0.15))
	item.continuous_cd = true
	item.freeze = true
	var collision: CollisionShape3D = CollisionShape3D.new()
	item.add_child(collision)
	item.add_child(visual)
	if not visual.configure_body(item, collision):
		item.free()
		return null
	var bounds: AABB = visual.bounds
	# Assets are metres even when the display is attached to a 10x house node.
	item.top_level = true
	item.transform = surface.orthonormalized()
	item.position += item.basis.y * (-bounds.position.y + 0.008)
	parent.add_child(item)
	item.add_to_group("world_food")
	return item
