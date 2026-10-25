extends RefCounted
## Reference-led Sugarcube shop floor in real metres. The outer shell retains its
## source frosting, timber and tower; these room faces supply readable shop space.
const KIT := preload("res://world/buildings/golden_oak/furniture_kit.gd")
const DETAILS := preload("res://world/buildings/sugarcube/kitchen_details.gd")
const SEAT := preload("res://world/life/seat.gd")
const FLOOR := 0.90
const LEFT := -6.4
const RIGHT := 5.1
const BACK := -3.95
const FRONT := 4.05
const CEILING := 5.6

static func _box(parent: Node3D, name: String, size: Vector3, at: Vector3, material: Material, solid := false) -> MeshInstance3D:
	return KIT.box(parent, name, size, at, material, solid)

static func _prop(parent: Node3D, id: String, at: Vector3, yaw := 0.0) -> Node3D:
	var path := "res://world/buildings/shop_furnishings/models/" + id + ".scn"
	var prop: Node3D = load(path).instantiate()
	prop.name = id.to_pascal_case(); prop.position = at; prop.rotation.y = yaw
	parent.add_child(prop)
	return prop

static func _chair(parent: Node3D, at: Vector3, yaw: float, index: int) -> void:
	var chair := Node3D.new(); chair.name = "CafeChair%d" % index; chair.position = at; chair.rotation.y = yaw; parent.add_child(chair)
	var wood := KIT.material("9f6547"); var pink := KIT.material("e590be"); var gold := KIT.material("f3d998")
	_box(chair, "CushionedSeat", Vector3(0.56, 0.11, 0.55), Vector3(0, 0.46, 0), pink, true)
	for x: float in [-0.21, 0.21]:
		for z: float in [-0.20, 0.20]:
			KIT.tube(chair, "CurvedLeg", PackedVector3Array([Vector3(x * 1.12, 0.02, z * 1.15), Vector3(x * 0.85, 0.22, z), Vector3(x, 0.43, z)]), 0.045, wood)
		KIT.tube(chair, "BackPost", PackedVector3Array([Vector3(x, 0.42, 0.22), Vector3(x * 1.2, 0.82, 0.27), Vector3(x * 0.8, 1.03, 0.28)]), 0.045, wood)
	_box(chair, "RoseBack", Vector3(0.42, 0.29, 0.075), Vector3(0, 0.82, 0.265), pink)
	KIT.tube(chair, "GoldCrest", PackedVector3Array([Vector3(-0.18, 1.02, 0.28), Vector3(0, 1.09, 0.29), Vector3(0.18, 1.02, 0.28)]), 0.035, gold)
	var upper := KIT.box_body(chair, "SeatUpper", Vector3(0.52, 0.51, 0.12), Vector3(0, 0.8, 0.27))
	upper.set_meta("seat_upper", true)
	var seat := SEAT.new(); seat.name = "Seat"; seat.position = Vector3(0, 0.515, -0.01); seat.depth = 0.55; chair.add_child(seat)

static func _frieze() -> Material:
	var image := Image.new()
	assert(image.load_svg_from_string(FileAccess.get_file_as_string("res://world/buildings/sugarcube/art/candy_frieze.svg")) == OK)
	image.generate_mipmaps()
	var material := StandardMaterial3D.new(); material.albedo_texture = ImageTexture.create_from_image(image); material.roughness = 0.95
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

static func _ornament(parent: Node3D, at: Vector3, width: float, yaw: float, material: Material) -> void:
	var mesh := QuadMesh.new(); mesh.size = Vector2(width, 0.53); mesh.material = material
	var visual := MeshInstance3D.new(); visual.name = "PaintedCandyFrieze"; visual.mesh = mesh; visual.position = at; visual.rotation.y = yaw; parent.add_child(visual)

static func build(parent: Node3D) -> Node3D:
	var room := Node3D.new(); room.name = "BakeryRoom"; room.scale = Vector3.ONE / 14.0; parent.add_child(room)
	var cream := KIT.material("e2dfb4"); var timber := KIT.material("8c573b"); var pink := KIT.material("d979aa")
	var pale := KIT.material("f4e9d2"); var mint := KIT.material("8dbdaf"); var dark_mint := KIT.material("78a899")
	var width := RIGHT - LEFT; var depth := FRONT - BACK; var mid := Vector3((LEFT + RIGHT) * 0.5, 0, (FRONT + BACK) * 0.5)
	# The expanded footprint extends beyond the old town plinth on its low bank.
	_box(room, "InsetBakeryFoundation", Vector3(width - 0.04, 1.60, depth - 0.04), mid + Vector3.UP * -0.10, KIT.material("bb8ca6"), true)
	_box(room, "ShopFloor", Vector3(width, 0.20, depth), mid + Vector3.UP * (FLOOR - 0.10), mint, true)
	for i in 14:
		var x := LEFT + 0.1 + i * 0.82
		_box(room, "MintFloorboardSeam", Vector3(0.012, 0.002, depth), Vector3(x, FLOOR + 0.002, mid.z), dark_mint)
	_box(room, "CreamCeiling", Vector3(width, 0.18, depth), mid + Vector3.UP * (CEILING + 0.09), pale, true)
	_box(room, "BackRoomWall", Vector3(width, CEILING - FLOOR, 0.18), Vector3(mid.x, (FLOOR + CEILING) * 0.5, BACK), cream, true)
	for x: float in [LEFT, RIGHT]:
		_box(room, "SideRoomWall", Vector3(0.18, CEILING - FLOOR, depth), Vector3(x, (FLOOR + CEILING) * 0.5, mid.z), cream, true)
		_box(room, "ChocolateWainscot", Vector3(0.20, 0.85, depth), Vector3(x, FLOOR + 0.425, mid.z), timber)
	# Front panels flank the moving source leaf. Window bands remain open above the
	# sill on either side, preserving the source glazing instead of painting it over.
	_box(room, "FrontLeftBase", Vector3(5.20, 1.9, 0.12), Vector3(-3.80, FLOOR + 0.95, FRONT), cream, true)
	_box(room, "FrontRightTop", Vector3(3.75, 2.2, 0.12), Vector3(3.22, CEILING - 1.1, FRONT), cream, true)
	_box(room, "FrontLeftJamb", Vector3(0.13, CEILING - FLOOR, 0.12), Vector3(-1.135, (FLOOR + CEILING) * 0.5, FRONT), cream, true)
	_box(room, "FrontRightJamb", Vector3(1.90, CEILING - FLOOR, 0.12), Vector3(2.25, (FLOOR + CEILING) * 0.5, FRONT), cream, true)
	# Source glazing stays visible; solid thin panes also block from the room side.
	KIT.box_body(room, "FrontRightGlazing", Vector3(2.44, 2.35, 0.045), Vector3(4.44, 1.93, 4.145))
	KIT.box_body(room, "FrontLeftGlazing", Vector3(1.74, 2.03, 0.045), Vector3(-4.09, 4.22, 4.145))
	_box(room, "DoorLintel", Vector3(2.45, 1.62, 0.12), Vector3(0.12, CEILING - 0.81, FRONT), pink, true)
	_box(room, "BackChocolateRail", Vector3(width, 0.26, 0.22), Vector3(mid.x, 4.75, BACK + 0.05), timber)
	var frieze := _frieze()
	for x: float in [-4.7, -1.2, 2.3]: _ornament(room, Vector3(x, 4.33, BACK + 0.16), 3.5, 0, frieze)
	for z: float in [-2.0, 1.7]:
		_box(room, "CeilingChocolateBeam", Vector3(width, 0.22, 0.22), Vector3(mid.x, CEILING - 0.12, z), timber)
		for x: float in [LEFT + 0.25, RIGHT - 0.25]:
			var toward := 1.0 if x < 0 else -1.0
			var scroll := PackedVector3Array()
			for i in 19:
				var angle := float(i) / 18.0 * PI * 1.6
				var radius := lerpf(0.45, 0.06, float(i) / 18.0)
				scroll.append(Vector3(x + toward * (0.5 + cos(angle) * radius), CEILING - 0.65 + sin(angle) * radius, z))
			KIT.tube(room, "GingerbreadScrollBracket", scroll, 0.11, timber)
	# Move the complete display composition together; paid stock shares this offset.
	var display := Node3D.new(); display.name = "DisplayComposition"; display.position.x = -.6; room.add_child(display)
	for x: float in [-1.10, 2.10]:
		var counter := _prop(display, "bakery_counter", Vector3(x, FLOOR, -0.85)); counter.scale.z = 1.70
		KIT.box_body(display, "CounterBase", Vector3(3.12, 0.94, 1.24), Vector3(x, FLOOR + 0.47, -0.85))
		_prop(display, "candy_shelf", Vector3(x, FLOOR, BACK + 0.45))
		KIT.box_body(display, "CandyShelfBody", Vector3(2.75, 2.18, 0.42), Vector3(x, FLOOR + 1.09, BACK + 0.45))
	_box(display, "CreamDisplayTop", Vector3(6.34, 0.035, 1.32), Vector3(0.50, 1.96, -0.85), pale, true)
	# Broad candy-coloured canopy and scalloped lower edge echo the PPP shop.
	_box(display, "RoseDisplayCanopy", Vector3(6.60, 0.55, 0.62), Vector3(0.50, 3.72, -3.36), pink)
	for i in 22:
		DETAILS.cylinder(display, "CanopyScallop", Vector3(-2.66 + i * 0.30, 3.43, -3.04), 0.155, 0.035, pink).rotation.x = PI * 0.5
	_ornament(display, Vector3(0.50, 3.73, -3.03), 6.3, 0, frieze)
	for x: float in [-2.90, 3.90]:
		_box(display, "ChocolateDisplayPost", Vector3(0.21, 2.70, 0.21), Vector3(x, 2.25, -3.10), timber)
		for i in 9:
			_box(display, "PeppermintPostBand", Vector3(0.235, 0.13, 0.235), Vector3(x, 1.05 + i * 0.29, -3.10), pale if i % 2 == 0 else pink)
	_prop(room, "mint_pantry", Vector3(4.15, FLOOR, BACK + 0.53))
	KIT.box_body(room, "PantryBody", Vector3(1.04, 1.85, 0.46), Vector3(4.15, FLOOR + 0.925, BACK + 0.53))
	_prop(room, "cake_table", Vector3(-3.95, FLOOR, -1.10))
	KIT.box_body(room, "CakeTableBody", Vector3(0.90, 0.79, 0.90), Vector3(-3.95, FLOOR + 0.395, -1.10))
	# Mint worktop, sink and open shelving make the back-left corner a kitchen.
	_box(room, "KitchenMintBase", Vector3(3.1, 0.86, 0.72), Vector3(-4.35, FLOOR + 0.43, BACK + 0.54), mint, true)
	_box(room, "WorktopLeft", Vector3(0.99, 0.075, 0.84), Vector3(-5.415, FLOOR + 0.90, BACK + 0.54), pale, true)
	_box(room, "WorktopRight", Vector3(1.43, 0.075, 0.84), Vector3(-3.465, FLOOR + 0.90, BACK + 0.54), pale, true)
	for z: float in [-3.78, -3.04]: _box(room, "WorktopSinkBridge", Vector3(0.74, 0.075, 0.10), Vector3(-4.55, FLOOR + 0.90, z), pale, true)
	KIT.tube(room, "CurvedTap", PackedVector3Array([Vector3(-4.55, FLOOR + 0.94, BACK + 0.21), Vector3(-4.55, FLOOR + 1.25, BACK + 0.21), Vector3(-4.55, FLOOR + 1.30, BACK + 0.46), Vector3(-4.55, FLOOR + 1.15, BACK + 0.50)]), 0.025, KIT.material("899b9a"))
	for y: float in [2.6, 3.25]:
		_box(room, "MintKitchenShelf", Vector3(2.5, 0.10, 0.32), Vector3(-4.35, y, BACK + 0.28), mint)
	DETAILS.build(room)
	# Two tables, eight physical seats; the wide central entrance aisle stays clear.
	var chair_index := 0
	# Keep the east table and all four seats together, leaving a full body-width
	# aisle beside the wall for the counter's staff route and upstairs access.
	for at: Vector3 in [Vector3(-3.8, FLOOR, 1.6), Vector3(2.1, FLOOR, 2.67)]:
		_prop(room, "cafe_table", at)
		KIT.box_body(room, "CafeTableTop", Vector3(1.06, 0.075, 1.06), at + Vector3.UP * .682)
		for j in 4:
			var angle := float(j) * PI * 0.5
			var offset := Vector3(sin(angle), 0, cos(angle)) * 0.94
			_chair(room, at + offset, angle, chair_index); chair_index += 1
	for at: Vector3 in [Vector3(-3.6, 4.5, 0.6), Vector3(2.7, 4.5, 0.6), Vector3(-0.3, 4.5, -2.6)]:
		var light := OmniLight3D.new(); light.name = "BakeryWarmLight"; light.position = at; light.omni_range = 6.0
		light.light_color = Color("ffe7bf"); light.light_energy = 1.15; light.shadow_enabled = false; room.add_child(light)
	for mesh: GeometryInstance3D in room.find_children("*", "GeometryInstance3D", true, false):
		mesh.visibility_range_end = 250.0 if mesh.name == "InsetBakeryFoundation" else 60.0
	return room
