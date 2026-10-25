extends Node3D
## Attach once to the EXISTING zecorahut_2_01 node. No new hut or moved saved actor.
## All coordinates are metres in its original, +Z-facing RNL frame.
const ASSET := preload("res://world/characters/zecora/source_asset.gd")
const HOME := preload("res://world/buildings/zecora/zecora_home.gd")
const DOOR := preload("res://world/buildings/hinged_door.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
const SOURCE_ID := "zecorahut_2_01"
const FLOOR := .08
var home: Node3D

static func attach(existing: Node3D) -> Node3D:
	assert(existing != null and str(existing.name) == SOURCE_ID)
	var installed := existing.get_node_or_null("UsableHut")
	if installed != null: return installed
	# Preload the replacement before disabling the source's fifteen filled boxes.
	var shell: PackedScene = ASSET.scene("res://world/buildings/zecora/assets/shell.glb")
	assert(shell != null)
	for collider: CollisionObject3D in existing.find_children("*", "CollisionObject3D", true, false):
		collider.collision_layer = 0
		collider.collision_mask = 0
	for mesh: MeshInstance3D in existing.find_children("*", "MeshInstance3D", true, false):
		mesh.visible = false
	var hut: Node3D = load("res://world/buildings/zecora/zecora_hut.gd").new()
	hut.name = "UsableHut"
	existing.add_child(hut)
	existing.set_meta("zecora_interior", true)
	return hut

func _ready() -> void:
	var shell: Node3D = ASSET.scene("res://world/buildings/zecora/assets/shell.glb").instantiate()
	shell.name = "OriginalTreeExterior"; add_child(shell)
	for mesh: MeshInstance3D in shell.find_children("*", "MeshInstance3D", true, false):
		var body := StaticBody3D.new(); body.name = "CarvedBarkCollision"; body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var triangles := mesh.mesh.create_trimesh_shape(); triangles.backface_collision = true
		shape.shape = triangles; body.add_child(shape); mesh.add_child(body)
	var wood := StandardMaterial3D.new(); wood.albedo_color = Color("6b4933"); wood.roughness = 1.0
	_box("RoomFloor", Vector3(-.425,.01,-1.05), Vector3(3.95,.14,5.1), wood)
	_box("RoomCeiling", Vector3(-.425,2.72,-1.05), Vector3(3.95,.08,5.1), wood)
	_box("LeftLining", Vector3(-2.43,1.38,-1.05), Vector3(.08,2.68,5.1), wood)
	_box("RightLining", Vector3(1.58,1.38,-1.05), Vector3(.08,2.68,5.1), wood)
	_box("BackLining", Vector3(-.425,1.38,-3.63), Vector3(4.03,2.68,.08), wood)
	_box("FrontLeftLining", Vector3(-1.76,1.38,1.53), Vector3(1.37,2.68,.08), wood)
	_box("FrontRightLining", Vector3(1.09,1.38,1.53), Vector3(.97,2.68,.08), wood)
	_box("EntryDeck", Vector3(-.235,.02,5.0), Vector3(1.68,.12,7.0), wood)
	# Original knob and leaf share a hinge at the right jamb and swing outwards.
	var door := DOOR.new(); door.name = "FrontDoor"; door.position = Vector3(.69,.08,2.31)
	door.handle = Vector3(-1.47,1.42,.18)
	door.navigation_box = AABB(Vector3(-1.85,0,-.1),Vector3(1.85,2.83,.25))
	var artwork: Node3D = ASSET.scene("res://world/buildings/zecora/assets/door.glb").instantiate()
	artwork.name = "SourceDoorLeaf"; door.add_child(artwork)
	var holder := CollisionShape3D.new(); holder.name = "LeafCollision"; var leaf := BoxShape3D.new(); leaf.size = Vector3(1.85,2.83,.14)
	holder.shape = leaf; holder.position = Vector3(-.925,1.415,0); door.add_child(holder)
	add_child(door)
	home = HOME.new(); home.name = "HouseInterior"; home.scale = Vector3.ONE * 10.0
	home.furnish = false; home.floor_y = FLOOR / 10.0
	home.floors.append(Rect2(-.24,-.36,.395,.51))
	home.floors.append(Rect2(-.1075,.15,.168,.085))
	home.doorway = Vector3(-.0235,FLOOR/10.0,.231)
	home.approach = Vector3(-.0235,FLOOR/10.0,.845)
	home.door_width = .168
	home.set_meta("reserved_for", "zecora")
	var bed := _prop("Bed", "bed", Vector3(-1.65,FLOOR,-2.28), .36, -PI*.5)
	bed.set_meta("mattress_top", .424)
	bed.set_meta("bed_size", Vector3(1.16,.12,2.06))
	bed.set_meta("side_local", Vector3(1.0,0,0))
	bed.set_meta("house", home); bed.set_meta("slot", "zecora_native_bed")
	_collider(bed,Vector3(0,.212,0),Vector3(1.05,.424,1.96))
	home.bed = bed
	add_child(home)
	home.set_sleepers(["zecora"])
	var kitchen := Node3D.new(); kitchen.name = "Kitchen"; kitchen.position = Vector3(-2.02,FLOOR,.15)
	kitchen.rotation.y = PI*.5; add_child(kitchen)
	kitchen.add_child((load("res://world/props/household/compact-kitchen.scn") as PackedScene).instantiate())
	kitchen.add_to_group("house_furniture"); kitchen.set_meta("kitchen",true); kitchen.set_meta("house",home)
	_collider(kitchen,Vector3(0,.52,0),Vector3(1.28,1.04,.65))
	_prop("Hearth", "hearth", Vector3(.65,FLOOR,-1.75), .40, 0)
	var cauldron := _prop("Cauldron", "cauldron", Vector3(.65,FLOOR+.10,-1.75), .45, 0)
	_collider(cauldron,Vector3(0,.23,0),Vector3(.78,.46,.61))
	cauldron.set_meta("activity", "herbal_brewing"); cauldron.set_meta("house", home)
	var light := OmniLight3D.new(); light.name = "HearthGlow"; light.position = Vector3(.65,.55,-1.75)
	light.light_color = Color("ffc986"); light.light_energy = .65; light.omni_range = 6; add_child(light)
	# Indoor props only (house_interior.gd PROP_RANGE); the hut is 1.3 km from town.
	for prop: Node in [bed, kitchen, get_node("Hearth"), cauldron]:
		HOUSE.limit_range(prop, HOUSE.PROP_RANGE, true)

func _prop(label_text: String, asset: String, at: Vector3, factor: float, yaw: float) -> Node3D:
	# Keep the wrapper in metre units so the existing bed APIs read correct metadata.
	var wrapper := Node3D.new(); wrapper.name = label_text; wrapper.position = at; add_child(wrapper)
	var art: Node3D = ASSET.scene("res://world/buildings/zecora/assets/" + asset + ".glb").instantiate()
	art.scale = Vector3.ONE * factor; art.rotation.y = yaw; wrapper.add_child(art)
	wrapper.add_to_group("house_furniture")
	return wrapper

func _collider(parent: Node3D, at: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new(); body.collision_mask = 0
	var shape := CollisionShape3D.new(); var box := BoxShape3D.new(); box.size = size
	shape.position = at; shape.shape = box; body.add_child(shape); parent.add_child(body)

func _box(label_text: String, at: Vector3, size: Vector3, material: Material) -> void:
	var view := MeshInstance3D.new(); view.name = label_text; view.position = at
	var box := BoxMesh.new(); box.size = size; view.mesh = box; view.material_override = material
	add_child(view); _collider(view,Vector3.ZERO,size)
