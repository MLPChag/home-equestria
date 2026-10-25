extends Node3D
const CURRENCY := preload("res://world/ui/currency.gd")
## Standalone Hayburger room. Origin is the floor centre; the entrance faces +Z.
## _ready() calls the idempotent build(). No gameplay, save data or world integration.
## The RNL shell has a solid 20.25 x 6.8 x 11.25 m collision box; its front is -Z.
## Runtime owns the shell doorway/collider replacement and this room's placement.

const SIGN_FONT := preload("res://world/ui/fonts/PonyvilleMedium.ttf")
const ROOM_SIZE := Vector3(12.0, 3.4, 10.0)
const COUNTER_Z := -1.4
const STAFF_OPENING := Vector2(3.45, 5.85)
## Street windows in the front wall (dev 2026-10-14: "add windows to the hayburger where the
## textured windows are right now it feels so cramped"): centred on the front booths, behind the
## facade's painted glass bands, which the runtime/shell open to clear holes over them.
const WINDOW_X: Array[float] = [-4.05, 4.05]
const WINDOW_SIZE := Vector2(3.0, 1.6)
const WINDOW_SILL := 1.2
const WINDOW_FRAME := preload("res://world/buildings/hayburger/street_window.glb")
const WOOD_FLOOR := preload("res://world/buildings/textures/wood_floor.res")
const PLASTER_TEXTURE := preload("res://world/buildings/house_a/textures/plaster_albedo.png")
const TIMBER_TEXTURE := preload("res://world/buildings/house_a/textures/timber_albedo.png")
const FOOD_CATALOG: Script = preload("res://world/food/food_catalog.gd")

@export var lights_enabled: bool = true

var _built: bool = false
var _materials: Dictionary = {}
var _mesh_cache: Dictionary = {}
var _details: Dictionary = {}
var _architecture: Node3D
var _dining: Node3D
var _service: Node3D
var _kitchen: Node3D
var _decoration: Node3D
var _collision: StaticBody3D


func _ready() -> void:
	build()


func build() -> void:
	if _built:
		return
	_built = true
	_make_materials()
	_architecture = _group("Architecture")
	_dining = _group("Dining")
	_service = _group("ServiceCounter")
	_kitchen = _group("Kitchen")
	_decoration = _group("Decoration")
	_collision = StaticBody3D.new()
	_collision.name = "RoomCollision"
	_collision.collision_layer = 1
	_collision.collision_mask = 0
	add_child(_collision)
	_build_shell()
	_build_floor()
	_build_booths()
	_build_counter()
	_build_self_service()
	_build_kitchen()
	_build_wall_art()
	_build_lights()
	_flush_details()
	_batch_furnishings()
	_build_windows()
	_marker("EntrySpawn", Vector3(0.0, 0.0, 3.5))
	_marker("ExitPoint", Vector3(0.0, 1.0, 4.8))
	_marker("ShiftPoint", Vector3(2.3, 1.0, -2.3))
	_marker("CustomerPoint", Vector3(0.0, 0.0, -0.2))
	_marker("SelfServePoint", Vector3(-2.1, 0.0, 3.35))
	_marker("GrillPoint", Vector3(-4.55, 1.12, -4.43))
	_marker("TrayPoint", Vector3(2.2, 1.15, -4.4))
	_marker("ServicePoint", Vector3(1.65, 1.055, -1.4))
	_marker("SelfServeFoodPoint", Vector3(-2.34, 1.035, 4.1))


func _group(node_name: String) -> Node3D:
	var group := Node3D.new()
	group.name = node_name
	add_child(group)
	return group


func _marker(node_name: String, at: Vector3) -> void:
	var marker := Marker3D.new()
	marker.name = node_name
	marker.position = at
	add_child(marker)


func _make_materials() -> void:
	_material("plaster", Color("f3dec2"), 0.95, PLASTER_TEXTURE, 0.5)
	_material("timber", Color("b88868"), 0.86, TIMBER_TEXTURE, 0.65)
	_material("floor", Color("c7a077"), 0.87, WOOD_FLOOR, 0.3)
	# Ponyville restyle (dev 2026-09-30: "the sleek modern blue style is just not ponyville"):
	# the old burgundy vinyl is now red cushion cloth, the wine wainscot is dark wood panelling.
	_material("vinyl", Color("b0503d"), 0.9)
	_material("wine", Color("7d553a"), 0.85, TIMBER_TEXTURE, 0.65)
	_material("cream", Color("fff0d2"), 0.65)
	# Butcher-block worktops and terracotta splashback tiles (dev 2026-09-30 restyle).
	_material("butcher", Color("cfa06a"), 0.8, TIMBER_TEXTURE, 0.65)
	_material("terracotta", Color("c47a52"), 0.9)
	_material("sage", Color("a47650"), 0.86, TIMBER_TEXTURE, 0.65)
	_material("tile_dark", Color("68574e"), 0.78)
	_material("tile_light", Color("eee0c4"), 0.8)
	_material("chalkboard", Color("33342f"), 0.95)
	_material("brass", Color("c69b52"), 0.43)
	_material("steel", Color("8a8b84"), 0.62)
	_material("iron", Color("424443"), 0.87)
	_material("hay", Color("e8bd63"), 0.9)
	_material("hay_dark", Color("b1833c"), 0.92)
	_material("red", Color("c34c3c"), 0.51)
	_material("mustard", Color("deb950"), 0.56)
	_material("paper", Color("f7ebcf"), 0.93)
	_material("bun", Color("dfa351"), 0.83)
	_material("lettuce", Color("90ae54"), 0.8)
	_material("bulb", Color("ffe4a6"), 0.5)
	var bulb: StandardMaterial3D = _materials["bulb"]
	bulb.emission_enabled = true
	bulb.emission = Color("ffd998")
	bulb.emission_energy_multiplier = 0.65
	var metal: StandardMaterial3D = _materials["brass"]
	metal.metallic = 0.35
	metal = _materials["steel"]
	metal.metallic = 0.45


func _material(key: String, color: Color, roughness: float,
		texture: Texture2D = null, texture_scale: float = 1.0) -> void:
	var material := StandardMaterial3D.new()
	material.resource_name = "Hayburger_" + key
	material.albedo_color = color
	material.roughness = roughness
	if texture != null:
		material.albedo_texture = texture
		material.uv1_triplanar = true
		material.uv1_scale = Vector3.ONE * texture_scale
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_materials[key] = material


func _build_shell() -> void:
	_box(_architecture, "FloorSlab", Vector3(0, -0.12, 0), Vector3(12.48, 0.24, 10.48), "floor", true)
	_box(_architecture, "LeftPlaster", Vector3(-6.12, 1.7, 0), Vector3(0.24, 3.4, 10.48), "plaster", true)
	_box(_architecture, "RightPlaster", Vector3(6.12, 1.7, 0), Vector3(0.24, 3.4, 10.48), "plaster", true)
	_box(_architecture, "BackPlaster", Vector3(0, 1.7, -5.12), Vector3(12, 3.4, 0.24), "plaster", true)
	for part: Array in [[Vector3(0, -0.12, 0), Vector3(12.48, 0.24, 10.48)], [Vector3(-6.12, 1.7, 0), Vector3(0.24, 3.4, 10.48)],
			[Vector3(6.12, 1.7, 0), Vector3(0.24, 3.4, 10.48)], [Vector3(0, 1.7, -5.12), Vector3(12, 3.4, 0.24)],
			[Vector3(0, 3.08, 5.12), Vector3(2.4, 0.64, 0.24)], [Vector3(0, 3.5, 0), Vector3(12.48, 0.2, 10.48)]]:
		_occluder(part[0], part[1])
	# An actual 2.4 m doorway, not an invisible barrier across the portal.
	for side: float in [-1.0, 1.0]:
		_front_wall(side)
		_box(_architecture, "FrontWainscot", Vector3(side * 3.63, 0.49, 4.975), Vector3(4.72, 0.98, 0.06), "wine")
		_box(_architecture, "FrontChairRail", Vector3(side * 3.63, 1.0, 4.92), Vector3(4.72, 0.08, 0.12), "timber")
		# The trim's inner face must stand proud of the plaster return at x=1.2.
		# Coincident faces flickered when looking through the doorway on LOW.
		_box(_architecture, "EntryPost", Vector3(side * 1.268, 1.37, 4.94), Vector3(0.16, 2.74, 0.19), "timber")
		_box(_architecture, "SideWainscot", Vector3(side * 5.975, 0.49, 1.85), Vector3(0.06, 0.98, 6.3), "wine")
		_box(_architecture, "SideChairRail", Vector3(side * 5.92, 1, 1.85), Vector3(0.12, 0.09, 6.3), "timber")
		_box(_architecture, "SideSkirting", Vector3(side * 5.94, 0.09, 0), Vector3(0.12, 0.18, 10), "timber")
		for z: float in [-4.9, -1.5, 1.9, 4.9]:
			_box(_architecture, "WallPost", Vector3(side * 5.9, 1.7, z), Vector3(0.19, 3.4, 0.19), "timber")
	_box(_architecture, "EntryLintel", Vector3(0, 3.08, 5.12), Vector3(2.4, 0.64, 0.24), "plaster")
	_box(_architecture, "Ceiling", Vector3(0, 3.5, 0), Vector3(12.48, 0.2, 10.48), "plaster")
	# Separate body lets floor sampling skip the ceiling without losing headroom collision.
	var ceiling_body := StaticBody3D.new()
	ceiling_body.name = "CeilingCollision"
	ceiling_body.collision_layer = 1
	ceiling_body.collision_mask = 0
	ceiling_body.set_meta("navigation_ceiling", true)
	var ceiling_shape := BoxShape3D.new()
	ceiling_shape.size = Vector3(12.48, 0.2, 10.48)
	var ceiling_collision := CollisionShape3D.new()
	ceiling_collision.name = "Ceiling"
	ceiling_collision.shape = ceiling_shape
	ceiling_collision.position = Vector3(0, 3.5, 0)
	ceiling_body.add_child(ceiling_collision)
	# The lintel is overhead collision too: otherwise the grid records its top as
	# the entrance floor and sends arriving customers away from the doorway.
	var lintel_shape: BoxShape3D = BoxShape3D.new()
	lintel_shape.size = Vector3(2.4, 0.64, 0.24)
	var lintel_collision: CollisionShape3D = CollisionShape3D.new()
	lintel_collision.name = "EntryLintel"
	lintel_collision.shape = lintel_shape
	lintel_collision.position = Vector3(0, 3.08, 5.12)
	ceiling_body.add_child(lintel_collision)
	add_child(ceiling_body)
	_box(_architecture, "BackSkirting", Vector3(0, 0.09, -4.94), Vector3(12, 0.18, 0.12), "timber")
	for z: float in [-3.15, -0.5, 2.6, 4.86]:
		_box(_architecture, "CrossBeam", Vector3(0, 3.26, z), Vector3(12, 0.28, 0.25), "timber")
		for side: float in [-1.0, 1.0]:
			_rod(_decoration, "BeamBrace", Vector3(side * 5.94, 2.67, z), Vector3(side * 5.32, 3.26, z), 0.075, "timber")
	for x: float in [-3.1, 3.1]:
		_box(_architecture, "LongBeam", Vector3(x, 3.33, 0), Vector3(0.16, 0.14, 10), "timber")
	# Soft horseshoe curve over the doorway, seen from inside.
	_arch_trim(Vector3(0, 2.72, 4.91), 1.29, 0.38, 0.065, "brass")


## One side of the front wall (x from the 2.4 m doorway to the side wall) with its window opening.
func _front_wall(side: float) -> void:
	var near: float = 1.2
	var far: float = 6.0
	var centre: float = absf(WINDOW_X[0 if side < 0 else 1])
	var left: float = centre - WINDOW_SIZE.x * .5
	var right: float = centre + WINDOW_SIZE.x * .5
	var top: float = WINDOW_SILL + WINDOW_SIZE.y
	var wall_z: float = 5.12
	var height: float = ROOM_SIZE.y
	_box(_architecture, "FrontPlaster", Vector3(side * (near + left) * .5, height * .5, wall_z), Vector3(left - near, height, .24), "plaster", true)
	_box(_architecture, "FrontPlaster", Vector3(side * (right + far) * .5, height * .5, wall_z), Vector3(far - right, height, .24), "plaster", true)
	_box(_architecture, "FrontPlasterBelowWindow", Vector3(side * centre, WINDOW_SILL * .5, wall_z), Vector3(WINDOW_SIZE.x, WINDOW_SILL, .24), "plaster", true)
	_box(_architecture, "FrontPlasterAboveWindow", Vector3(side * centre, (top + height) * .5, wall_z), Vector3(WINDOW_SIZE.x, height - top, .24), "plaster", true)
	_occluder(Vector3(side * (near + left) * .5, height * .5, wall_z), Vector3(left - near, height, .24))
	_occluder(Vector3(side * (right + far) * .5, height * .5, wall_z), Vector3(far - right, height, .24))
	_occluder(Vector3(side * centre, WINDOW_SILL * .5, wall_z), Vector3(WINDOW_SIZE.x, WINDOW_SILL, .24))
	_occluder(Vector3(side * centre, (top + height) * .5, wall_z), Vector3(WINDOW_SIZE.x, height - top, .24))
	# The clear pane is solid: nothing passes the window either way.
	_collider("WindowGlass", Vector3(side * centre, WINDOW_SILL + WINDOW_SIZE.y * .5, 5.15), Vector3(WINDOW_SIZE.x, WINDOW_SIZE.y, .05))

## Frames (Blender MCP model, art-source/hayburger-2026-10-14) and clear glass. Added after
## batching: the runtime keeps them visible from the street when the furnished room is culled.
func _build_windows() -> void:
	var holder := Node3D.new()
	holder.name = "StreetWindows"
	add_child(holder)
	var glass := StandardMaterial3D.new()
	glass.resource_name = "Hayburger_window_glass"
	glass.albedo_color = Color(0.86, 0.9, 1.0, 0.16)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.roughness = 0.05
	glass.metallic = 0.2
	glass.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pane := BoxMesh.new()
	pane.size = Vector3(WINDOW_SIZE.x, WINDOW_SIZE.y, 0.012)
	for x: float in WINDOW_X:
		var frame: Node3D = WINDOW_FRAME.instantiate()
		frame.name = "StreetWindowFrame"
		frame.position = Vector3(x, WINDOW_SILL + WINDOW_SIZE.y * .5, ROOM_SIZE.z * .5)
		holder.add_child(frame)
		var glazing := MeshInstance3D.new()
		glazing.name = "StreetWindowGlass"
		glazing.mesh = pane
		glazing.material_override = glass
		glazing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		glazing.position = Vector3(x, WINDOW_SILL + WINDOW_SIZE.y * .5, 5.15)
		holder.add_child(glazing)


func _build_floor() -> void:
	# Plank floor: the FloorSlab's own wood shows through. The checkerboard tiles, brass aisle
	# strips and "HAY THERE!" mat were diner styling (dev 2026-09-30); a woven hay rug remains.
	_rounded(_decoration, "WelcomeMat", Vector3(0, 0.012, 4.28), Vector3(2.1, 0.016, 0.74), 0.17, "hay")


func _build_booths() -> void:
	for side: float in [-1.0, 1.0]:
		for z: float in [1.55, 3.75]:
			var x: float = side * 4.05
			var booth := Node3D.new()
			booth.name = "Booth_%s_%s" % ["Left" if side < 0 else "Right", "Rear" if z < 2 else "Front"]
			_dining.add_child(booth)
			for facing: float in [-1.0, 1.0]:
				var seat_z: float = z + facing * 0.64
				_rounded(booth, "TimberSeatBase", Vector3(x, 0.2, seat_z), Vector3(2.46, 0.3, 0.59), 0.14, "timber", true)
				_rounded(booth, "VinylSeat", Vector3(x, 0.405, seat_z), Vector3(2.43, 0.15, 0.62), 0.16, "vinyl", true)
				_rounded(booth, "CreamPiping", Vector3(x, 0.385, seat_z), Vector3(2.45, 0.023, 0.63), 0.17, "timber")
				var back_at := Vector3(x, 0.77, z + facing * 0.86)
				var back := _rounded(booth, "CurvedBoothBack", back_at, Vector3(2.46, 0.19, 0.93), 0.2, "timber")
				back.rotation.x = PI * 0.5
				_collider("BoothBack", back_at, Vector3(2.46, 0.93, 0.19))
				_rod(booth, "BackCrownPiping", back_at + Vector3(-1.04, 0.43, -facing * 0.1), back_at + Vector3(1.04, 0.43, -facing * 0.1), 0.018, "timber")
				for offset: float in [-0.75, 0.0, 0.75]:
					_detail_sphere(back_at + Vector3(offset, 0.02, -facing * 0.102), Vector3(0.044, 0.044, 0.02), "brass")
			_rounded(booth, "TableBrassRim", Vector3(x, 0.765, z), Vector3(1.92, 0.1, 0.76), 0.26, "timber", true)
			_rounded(booth, "CreamTabletop", Vector3(x, 0.82, z), Vector3(1.88, 0.035, 0.72), 0.24, "butcher")
			_cylinder(booth, "Pedestal", Vector3(x, 0.38, z), 0.075, 0.7, "timber")
			_cylinder(booth, "PedestalFoot", Vector3(x, 0.044, z), 0.31, 0.06, "timber")
			_collider("TablePedestal", Vector3(x, 0.36, z), Vector3(0.2, 0.72, 0.2))
			_condiments(booth, Vector3(x + side * 0.56, 0.845, z))


func _condiments(parent: Node3D, at: Vector3) -> void:
	_rounded(parent, "CondimentTray", at, Vector3(0.4, 0.025, 0.28), 0.06, "timber")
	for i in 2:
		var p: Vector3 = at + Vector3(-0.105 + float(i) * 0.15, 0.106, 0)
		_cylinder(parent, "SauceBottle", p, 0.045, 0.185, "red" if i == 0 else "mustard", 0.029)
		_cylinder(parent, "SauceNozzle", p + Vector3(0, 0.108, 0), 0.012, 0.035, "cream", 0.005)
	_box(parent, "NapkinHolder", at + Vector3(0.095, 0.06, 0.083), Vector3(0.16, 0.09, 0.065), "steel")
	_box(parent, "Napkins", at + Vector3(0.095, 0.117, 0.083), Vector3(0.145, 0.085, 0.035), "paper")


func _build_counter() -> void:
	# Full clear staff opening: x=3.45..5.85 (right when entering from +Z).
	# Seat the existing plinth below the front's .125m lower edge: its old
	# .24m top left two visible faces sharing the same plane for .115m.
	_rounded(_service, "CounterPlinth", Vector3(-1.22, 0.005, COUNTER_Z), Vector3(9.12, 0.24, 0.86), 0.22, "timber", true)
	_rounded(_service, "BurgundyCounterFront", Vector3(-1.22, 0.54, COUNTER_Z), Vector3(9.1, 0.83, 0.86), 0.22, "wine", true)
	_rounded(_service, "BrassCounterRim", Vector3(-1.22, 0.98, COUNTER_Z), Vector3(9.34, 0.09, 0.94), 0.28, "brass", true)
	_rounded(_service, "ServiceWorktop", Vector3(-1.22, 1.035, COUNTER_Z), Vector3(9.29, 0.035, 0.89), 0.26, "butcher")
	for x: float in [-5.25, -3.75, -2.25, -0.75, 0.75, 2.25]:
		_detail_box(Vector3(x, 0.53, -0.965), Vector3(0.038, 0.61, 0.018), "brass")
	for y: float in [0.25, 0.8]:
		_rod(_service, "CounterTrim", Vector3(-5.44, y, -0.957), Vector3(2.96, y, -0.957), 0.025, "timber")
	_hay_emblem(Vector3(-1.1, 0.54, -0.93), 0.36)
	# Decorative register occupies the far left; the centre/right worktop stays usable.
	_rounded(_service, "TillBase", Vector3(-4.88, 1.13, -1.43), Vector3(0.55, 0.16, 0.42), 0.07, "sage")
	_box(_service, "TillDisplay", Vector3(-4.88, 1.34, -1.53), Vector3(0.39, 0.3, 0.1), "timber")
	_box(_service, "TillGlass", Vector3(-4.88, 1.34, -1.472), Vector3(0.33, 0.21, 0.013), "chalkboard")
	_cylinder(_service, "ServiceBellFoot", Vector3(-4.35, 1.083, -1.27), 0.105, 0.045, "iron")
	_sphere(_service, "ServiceBell", Vector3(-4.35, 1.12, -1.27), Vector3(0.18, 0.1, 0.18), "brass")
	_cylinder(_service, "BellButton", Vector3(-4.35, 1.188, -1.27), 0.022, 0.04, "brass")
	var menus: Array[Dictionary] = [
		{"x": -3.65, "title": "FROM THE GRIDDLE", "text": "Classic hayburger   %d \nGarden hayburger   %d \nExtra-crunch hay fries   %d " % [FOOD_CATALOG.price_bits("food:hayburger"), FOOD_CATALOG.price_bits("food:hayburger"), FOOD_CATALOG.price_bits("food:hay-fries")]},
		{"x": -0.85, "title": "FROM THE KITCHEN", "text": "Carrot dog   %d \nFlower sandwich   %d \nGrass pancakes   %d " % [FOOD_CATALOG.price_bits("food:carrot-dog"), FOOD_CATALOG.price_bits("food:daffodil-daisy-sandwich"), FOOD_CATALOG.price_bits("food:grass-pancakes")]},
		{"x": 1.95, "title": "SOUP & SWEET", "text": "Flat noodle soup   %d \nSweet carrot pancakes   %d " % [FOOD_CATALOG.price_bits("food:spicy-flat-noodle-soup"), FOOD_CATALOG.price_bits("food:sweet-carrot-pancakes")]},
	]
	for spec: Dictionary in menus:
		var x: float = float(spec["x"])
		var board := _rounded(_service, "MenuTimberFrame", Vector3(x, 2.48, -1.6), Vector3(2.58, 0.12, 0.93), 0.13, "timber")
		board.rotation.x = PI * 0.5
		_box(_service, "MenuBoard", Vector3(x, 2.48, -1.53), Vector3(2.39, 0.74, 0.024), "chalkboard")
		_label(_service, "MenuTitle", str(spec["title"]), Vector3(x, 2.71, -1.505), 36, 0.0034, Color("e8bd63"))
		_label(_service, "MenuDishes", str(spec["text"]), Vector3(x, 2.4, -1.502), 30, 0.0031, Color("fff0d2"))
		for dx: float in [-0.83, 0.83]:
			_rod(_service, "MenuHanger", Vector3(x + dx, 2.97, -1.6), Vector3(x + dx, 3.38, -1.6), 0.015, "brass")


func _build_kitchen() -> void:
	# Back line only: a 1.8 m working aisle remains behind the service counter.
	_box(_kitchen, "TiledSplashback", Vector3(-1.1, 1.39, -4.97), Vector3(9.35, 0.9, 0.055), "terracotta")
	for x: float in [-5.25, -4.65, -4.05, -3.45, -2.85, -2.25, -1.65, -1.05, -0.45, 0.15, 0.75, 1.35, 1.95, 2.55, 3.15]:
		_detail_box(Vector3(x, 1.39, -4.934), Vector3(0.016, 0.87, 0.012), "cream")
	for y: float in [1.12, 1.42, 1.72]:
		_detail_box(Vector3(-1.1, y, -4.928), Vector3(9.35, 0.016, 0.012), "cream")
	for x: float in [-4.55, -2.22, 0.12, 2.46]:
		_box(_kitchen, "LowerCupboard", Vector3(x, 0.49, -4.45), Vector3(2.18, 0.89, 0.98), "sage", true)
		_box(_kitchen, "CupboardToe", Vector3(x, 0.07, -4.49), Vector3(2.08, 0.14, 0.85), "timber")
		for dx: float in [-0.54, 0.54]:
			_box(_kitchen, "FramedCabinetDoor", Vector3(x + dx, 0.5, -3.947), Vector3(1.01, 0.72, 0.045), "timber")
			_box(_kitchen, "CabinetInset", Vector3(x + dx, 0.5, -3.916), Vector3(0.87, 0.59, 0.025), "sage")
			_rod(_kitchen, "CabinetHandle", Vector3(x + dx - 0.13, 0.74, -3.88), Vector3(x + dx + 0.13, 0.74, -3.88), 0.02, "brass")
		if x > -1:
			_rounded(_kitchen, "PrepWorktop", Vector3(x, 0.984, -4.43), Vector3(2.28, 0.1, 1.08), 0.065, "butcher", true)
	# Grill: dark cast plate and raised parallel bars, with a sloped extraction canopy.
	_rounded(_kitchen, "GrillSurround", Vector3(-4.55, 0.995, -4.43), Vector3(2.28, 0.12, 1.08), 0.08, "steel", true)
	_box(_kitchen, "GrillPlate", Vector3(-4.55, 1.071, -4.43), Vector3(1.96, 0.04, 0.76), "iron")
	for i in 18:
		_detail_box(Vector3(-5.43 + float(i) * 0.104, 1.102, -4.43), Vector3(0.026, 0.024, 0.7), "steel")
	_box(_kitchen, "GrillFascia", Vector3(-4.55, 0.91, -3.897), Vector3(2.2, 0.2, 0.08), "steel")
	for x: float in [-5.25, -4.8, -4.35, -3.9]:
		_detail_sphere(Vector3(x, 0.92, -3.832), Vector3(0.09, 0.09, 0.055), "iron")
	var hood_mesh := PrismMesh.new()
	hood_mesh.size = Vector3(2.48, 0.48, 1.3)
	hood_mesh.left_to_right = 0.5
	_part(_kitchen, "GrillCanopy", hood_mesh, Vector3(-4.55, 2.38, -4.37), "steel")
	_box(_kitchen, "CanopyLip", Vector3(-4.55, 2.14, -4.37), Vector3(2.52, 0.12, 1.32), "iron")
	_box(_kitchen, "CanopyFlue", Vector3(-4.55, 2.93, -4.65), Vector3(0.62, 0.67, 0.54), "steel")
	# A recessed basin with a real dark bottom and four rim strips, not a solid slab.
	_box(_kitchen, "SinkBasin", Vector3(-2.22, 0.965, -4.46), Vector3(1.26, 0.08, 0.64), "iron")
	for dx: float in [-0.91, 0.91]:
		_box(_kitchen, "SinkDrainingBoard", Vector3(-2.22 + dx, 1.015, -4.43), Vector3(0.47, 0.1, 1.08), "steel")
	for z: float in [-4.9, -3.96]:
		_box(_kitchen, "SinkRim", Vector3(-2.22, 1.015, z), Vector3(1.36, 0.1, 0.14), "steel")
	_cylinder(_kitchen, "TapUpright", Vector3(-2.22, 1.22, -4.83), 0.028, 0.4, "brass")
	_rod(_kitchen, "TapSpout", Vector3(-2.22, 1.4, -4.83), Vector3(-2.22, 1.4, -4.51), 0.029, "brass")
	_cylinder(_kitchen, "TapOutlet", Vector3(-2.22, 1.36, -4.51), 0.028, 0.08, "brass")
	for x: float in [-2.48, -1.96]:
		_cylinder(_kitchen, "TapHandle", Vector3(x, 1.09, -4.81), 0.053, 0.05, "brass")
	for x: float in [0.12, 2.46]:
		_box(_kitchen, "UpperCupboard", Vector3(x, 2.28, -4.75), Vector3(2.06, 0.72, 0.47), "timber", true)
		for dx: float in [-0.51, 0.51]:
			_box(_kitchen, "UpperCreamDoor", Vector3(x + dx, 2.28, -4.504), Vector3(0.95, 0.63, 0.03), "cream")
			_detail_sphere(Vector3(x + dx, 2.12, -4.477), Vector3(0.055, 0.055, 0.035), "brass")
	_rounded(_kitchen, "ChoppingBoard", Vector3(0.1, 1.058, -4.34), Vector3(0.78, 0.04, 0.5), 0.07, "timber")
	for i in 4:
		_rounded(_kitchen, "ServingTray", Vector3(2.2, 1.061 + float(i) * 0.025, -4.4), Vector3(0.59, 0.022, 0.41), 0.065, "timber")
	# Pantry stays at the rear right, outside the staff portal and ShiftPoint.
	_box(_kitchen, "PantryBack", Vector3(5.37, 1.07, -4.78), Vector3(0.97, 2.14, 0.13), "timber", true)
	for x: float in [4.85, 5.89]:
		_box(_kitchen, "PantryUpright", Vector3(x, 1.09, -4.43), Vector3(0.1, 2.18, 0.85), "timber", true)
	for y: float in [0.12, 0.82, 1.5, 2.14]:
		_box(_kitchen, "PantryShelf", Vector3(5.37, y, -4.43), Vector3(1.04, 0.08, 0.85), "timber", true)
	for y: float in [0.37, 1.04]:
		_rounded(_kitchen, "HayBasket", Vector3(5.37, y, -4.4), Vector3(0.8, 0.37, 0.64), 0.1, "hay_dark")
		for i in 9:
			var px: float = 5.06 + float(i) * 0.075
			_detail_box(Vector3(px, y + 0.2, -4.4), Vector3(0.036, 0.035, 0.51), "hay", float(i % 3 - 1) * 0.09)
	for i in 3:
		_cylinder(_kitchen, "PantryJar", Vector3(5.08 + float(i) * 0.28, 1.7, -4.4), 0.103, 0.3, "cream")
		_cylinder(_kitchen, "JarLid", Vector3(5.08 + float(i) * 0.28, 1.865, -4.4), 0.109, 0.03, "vinyl")


func _build_self_service() -> void:
	# A freestanding timber order stand, facing into the room (-Z). Its nearest
	# edge is x=-1.66, leaving the entire 3 m central checker aisle unobstructed.
	var at := Vector3(-2.1, 0, 4.4)
	_rounded(_dining, "SelfServiceFoot", at + Vector3(0, 0.065, 0), Vector3(0.8, 0.13, 0.66), 0.18, "timber", true)
	_rounded(_dining, "SelfServiceStand", at + Vector3(0, 0.57, 0), Vector3(0.65, 1.04, 0.45), 0.13, "wine", true)
	_rounded(_dining, "SelfServiceShelf", at + Vector3(0, 0.98, -0.12), Vector3(0.88, 0.08, 0.74), 0.15, "brass", true)
	var frame := _rounded(_dining, "SelfServiceFrame", at + Vector3(0, 1.39, 0.05), Vector3(0.88, 0.11, 0.65), 0.13, "timber")
	frame.rotation.x = PI * 0.5
	_collider("SelfServiceFrame", at + Vector3(0, 1.39, 0.05), Vector3(0.88, 0.65, 0.11))
	_box(_dining, "SelfServiceMenu", at + Vector3(0, 1.39, -0.015), Vector3(0.76, 0.53, 0.025), "chalkboard")
	var title := _label(_dining, "SelfServiceLabel", "SELF SERVICE", at + Vector3(0, 1.55, -0.034), 30, 0.0027, Color("e8bd63"))
	title.rotation.y = PI
	var choices := _label(_dining, "SelfServiceChoices", "Hayburger   %d \nHay fries   %d \nOrder at your own pace" % [FOOD_CATALOG.price_bits("food:hayburger"), FOOD_CATALOG.price_bits("food:hay-fries")], at + Vector3(0, 1.34, -0.036), 22, 0.0023, Color("fff0d2"))
	choices.rotation.y = PI
	for dx: float in [0.07, 0.2, 0.33]:
		_sphere(_dining, "KioskOrderButton", at + Vector3(dx, 1.035, -0.2), Vector3(0.085, 0.038, 0.085), "cream")
	_build_kiosk_sample()


func _build_kiosk_sample() -> void:
	# A 20 cm finished hayburger on the clear left/front part of the kiosk shelf.
	var sample := Node3D.new()
	sample.name = "SelfServeSample"
	sample.position = Vector3(-2.34, 1.02, 4.1)
	_dining.add_child(sample)
	_cylinder(sample, "SamplePlate", Vector3(0, 0.008, 0), 0.135, 0.014, "cream")
	_cylinder(sample, "PlateInset", Vector3(0, 0.016, 0), 0.113, 0.004, "paper")
	# The real hayburger model (hay patty with straws, dev 2026-10-20), merged into a few draws,
	# standing on the plate inset.
	var burger_path := "res://world/props/food/hayburger.scn"
	var merged: Dictionary = preload("res://world/food/food_mesh_merge.gd").merged(burger_path, true)
	var burger := Node3D.new()
	burger.name = "Hayburger"
	sample.add_child(burger)
	if merged.is_empty():
		burger.add_child((load(burger_path) as PackedScene).instantiate())
		burger.position.y = 0.018
	else:
		burger.position.y = 0.018 - (merged.bounds as AABB).position.y
		for part: Dictionary in merged.parts:
			var mesh := MeshInstance3D.new()
			mesh.mesh = part.mesh
			mesh.cast_shadow = part.shadow
			burger.add_child(mesh)


func _build_wall_art() -> void:
	# Arched panels echo the RNL shell's curved window trims and warm painted wood.
	for side: float in [-1.0, 1.0]:
		for z: float in [1.4, 3.72]:
			var plaque := Node3D.new()
			plaque.name = "MeadowPlaque"
			_decoration.add_child(plaque)
			plaque.position = Vector3(side * 5.88, 2.11, z)
			plaque.rotation.y = -side * PI * 0.5
			var rim := _rounded(plaque, "PlaqueFrame", Vector3.ZERO, Vector3(1.75, 0.12, 1.24), 0.33, "timber")
			rim.rotation.x = PI * 0.5
			var inner := _rounded(plaque, "PlaqueEnamel", Vector3(0, 0, 0.071), Vector3(1.58, 0.04, 1.07), 0.29, "sage")
			inner.rotation.x = PI * 0.5
			# One stylized stalk with broad oat grains, the plaque's only art (no slogan).
			_rod(plaque, "OatStem", Vector3(0, -0.3, 0.111), Vector3(0, 0.3, 0.111), 0.018, "hay")
			for i in 3:
				for sign_value: float in [-1.0, 1.0]:
					var grain := _sphere(plaque, "OatGrain", Vector3(sign_value * 0.105, -0.04 + float(i) * 0.12, 0.117), Vector3(0.2, 0.095, 0.045), "hay")
					grain.rotation.z = sign_value * 0.48
	# The two wooden "Hayburger" signboards on the front wall are gone (dev 2026-10-14:
	# "remove the hayburger wooden signs on the walls too"); the front wall has windows now.


func _hay_emblem(at: Vector3, size: float) -> void:
	for side: float in [-1.0, 1.0]:
		_rod(_decoration, "HayStem", at + Vector3(side * 0.02, -size * 0.64, 0), at + Vector3(side * size * 0.56, size * 0.67, 0), 0.013, "hay")
		for i in 4:
			var grain_at: Vector3 = at + Vector3(side * size * (0.14 + float(i) * 0.12), size * (-0.16 + float(i) * 0.24), 0.005)
			var grain := _sphere(_decoration, "HayGrain", grain_at, Vector3(size * 0.3, size * 0.19, 0.035), "hay")
			grain.rotation.z = side * 0.65


func _build_lights() -> void:
	# Five pendant meshes, three modest room lights. No point-light shadows.
	for at: Vector3 in [Vector3(-4.05, 0, 2.65), Vector3(4.05, 0, 2.65), Vector3(0, 0, 2.65), Vector3(-2.6, 0, -2.65), Vector3(2.6, 0, -2.65)]:
		_cylinder(_decoration, "PendantRose", at + Vector3(0, 3.37, 0), 0.13, 0.05, "brass")
		_rod(_decoration, "PendantCord", at + Vector3(0, 2.72, 0), at + Vector3(0, 3.35, 0), 0.014, "iron")
		_cylinder(_decoration, "PendantShade", at + Vector3(0, 2.68, 0), 0.32, 0.24, "hay", 0.09)
		_cylinder(_decoration, "PendantRim", at + Vector3(0, 2.553, 0), 0.327, 0.028, "brass")
		_cylinder(_decoration, "PendantDiffuser", at + Vector3(0, 2.54, 0), 0.287, 0.018, "bulb")
	for at: Vector3 in [Vector3(-3.2, 2.55, 1.9), Vector3(3.2, 2.55, 1.9), Vector3(0, 2.78, -3.12)]:
		var light := OmniLight3D.new()
		light.name = "WarmRoomLight"
		light.position = at
		light.light_color = Color("ffe3b5")
		light.light_energy = 1.15
		light.omni_range = 6.3
		light.omni_attenuation = 1.3
		light.shadow_enabled = false
		light.visible = lights_enabled
		light.light_bake_mode = Light3D.BAKE_DISABLED
		_decoration.add_child(light)


func _part(parent: Node3D, node_name: String, mesh: Mesh, at: Vector3, material_key: String) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.name = node_name
	part.mesh = mesh
	part.material_override = _materials[material_key]
	part.position = at
	parent.add_child(part)
	return part


## The room's walls, floor and ceiling as occluders, with the doorway and street windows left open
## (2026-10-23 GPU pass: inside, 1.8M triangles of town still rendered behind the walls).
func _occluder(at: Vector3, size: Vector3) -> void:
	var box := BoxOccluder3D.new()
	box.size = size
	var occluder := OccluderInstance3D.new()
	occluder.name = "WallOccluder"
	occluder.occluder = box
	occluder.position = at
	_architecture.add_child(occluder)


func _box(parent: Node3D, node_name: String, at: Vector3, size: Vector3, material_key: String, solid: bool = false) -> MeshInstance3D:
	var cache_key: String = "box:%s" % size
	if not _mesh_cache.has(cache_key):
		var mesh := BoxMesh.new()
		mesh.size = size
		_mesh_cache[cache_key] = mesh
	var mesh: Mesh = _mesh_cache[cache_key]
	var part := _part(parent, node_name, mesh, at, material_key)
	if solid:
		_collider(node_name, at, size)
	return part


func _cylinder(parent: Node3D, node_name: String, at: Vector3, radius: float, height: float, material_key: String, top_radius: float = -1.0) -> MeshInstance3D:
	var top: float = radius if top_radius < 0 else top_radius
	var key: String = "cylinder:%f:%f:%f" % [radius, height, top]
	if not _mesh_cache.has(key):
		var mesh := CylinderMesh.new()
		mesh.bottom_radius = radius
		mesh.top_radius = top
		mesh.height = height
		mesh.radial_segments = 16
		mesh.rings = 1
		_mesh_cache[key] = mesh
	var mesh: Mesh = _mesh_cache[key]
	return _part(parent, node_name, mesh, at, material_key)


func _sphere(parent: Node3D, node_name: String, at: Vector3, size: Vector3, material_key: String) -> MeshInstance3D:
	var part := _part(parent, node_name, _unit_sphere(), at, material_key)
	part.scale = size
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return part


func _unit_sphere() -> SphereMesh:
	if not _mesh_cache.has("sphere"):
		var mesh := SphereMesh.new()
		mesh.radius = 0.5
		mesh.height = 1.0
		mesh.radial_segments = 12
		mesh.rings = 6
		_mesh_cache["sphere"] = mesh
	return _mesh_cache["sphere"] as SphereMesh


func _rod(parent: Node3D, node_name: String, start: Vector3, end: Vector3, radius: float, material_key: String) -> void:
	var delta: Vector3 = end - start
	var part := _cylinder(parent, node_name, (start + end) * 0.5, radius, delta.length(), material_key)
	part.quaternion = Quaternion(Vector3.UP, delta.normalized())


func _rounded(parent: Node3D, node_name: String, at: Vector3, size: Vector3, radius: float, material_key: String, solid: bool = false) -> MeshInstance3D:
	var key: String = "rounded:%s:%f" % [size, radius]
	if not _mesh_cache.has(key):
		_mesh_cache[key] = _rounded_mesh(size, radius)
	var mesh: Mesh = _mesh_cache[key]
	var part := _part(parent, node_name, mesh, at, material_key)
	if solid:
		_collider(node_name, at, size)
	return part


func _rounded_mesh(size: Vector3, radius: float) -> ArrayMesh:
	var r: float = minf(radius, minf(size.x, size.z) * 0.49)
	var ring := PackedVector3Array()
	for corner in 4:
		var angle: float = float(corner) * PI * 0.5
		var cx: float = (size.x * 0.5 - r) * (1.0 if corner == 0 or corner == 3 else -1.0)
		var cz: float = (size.z * 0.5 - r) * (1.0 if corner < 2 else -1.0)
		for step in 6:
			var a: float = angle + float(step) * PI * 0.1
			ring.append(Vector3(cx + cos(a) * r, 0, cz + sin(a) * r))
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_y: float = size.y * 0.5
	for i in ring.size():
		var a: Vector3 = ring[i]
		var b: Vector3 = ring[(i + 1) % ring.size()]
		var up := Vector3(0, half_y, 0)
		_triangle(surface, up, a + up, b + up, Vector3.UP)
		_triangle(surface, -up, b - up, a - up, Vector3.DOWN)
		var normal: Vector3 = Vector3(b.z - a.z, 0, a.x - b.x).normalized()
		_triangle(surface, a - up, b - up, b + up, normal)
		_triangle(surface, a - up, b + up, a + up, normal)
	return surface.commit()


func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> void:
	surface.set_normal(normal)
	for vertex: Vector3 in [a, b, c]:
		surface.set_uv(Vector2(vertex.x, vertex.z))
		surface.add_vertex(vertex)


func _arch_trim(at: Vector3, width_radius: float, rise: float, thickness: float, material_key: String) -> void:
	for i in 18:
		var a: float = float(i) * PI / 18.0
		var b: float = float(i + 1) * PI / 18.0
		_rod(_decoration, "ArchedDoorTrim", at + Vector3(cos(a) * width_radius, sin(a) * rise, 0), at + Vector3(cos(b) * width_radius, sin(b) * rise, 0), thickness, material_key)


func _collider(node_name: String, at: Vector3, size: Vector3) -> void:
	var collision := CollisionShape3D.new()
	collision.name = node_name
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	collision.position = at
	_collision.add_child(collision)


func _label(parent: Node3D, node_name: String, words: String, at: Vector3, font_size: int, pixel_size: float, color: Color) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = words
	label.position = at
	label.font_size = font_size
	label.pixel_size = pixel_size
	label.modulate = color
	label.outline_size = 0
	label.no_depth_test = false
	label.shaded = true
	label.double_sided = false
	# Sign titles in the show's hand-lettered Ponyville face; menus stay in the default font.
	if node_name in ["HouseName", "MenuTitle", "SelfServiceLabel"]: label.font = SIGN_FONT
	parent.add_child(label)
	CURRENCY.apply(label)
	return label


func _detail_box(at: Vector3, size: Vector3, material_key: String, yaw: float = 0.0) -> void:
	if not _mesh_cache.has("unit_box"):
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE
		_mesh_cache["unit_box"] = mesh
	var mesh: Mesh = _mesh_cache["unit_box"]
	_detail("box:" + material_key, mesh, Transform3D(Basis(Vector3.UP, yaw).scaled(size), at), material_key)


func _detail_sphere(at: Vector3, size: Vector3, material_key: String) -> void:
	_detail("sphere:" + material_key, _unit_sphere(), Transform3D(Basis.from_scale(size), at), material_key)


func _detail(key: String, mesh: Mesh, transform: Transform3D, material_key: String) -> void:
	if not _details.has(key):
		_details[key] = {"mesh": mesh, "material": material_key, "transforms": []}
	var batch: Dictionary = _details[key]
	var transforms: Array = batch["transforms"]
	transforms.append(transform)


func _flush_details() -> void:
	for key: String in _details:
		var batch: Dictionary = _details[key]
		var transforms: Array = batch["transforms"]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = batch["mesh"] as Mesh
		multimesh.instance_count = transforms.size()
		# One upload (buffer rows as set_instance_transform writes them): a first per-instance
		# set on a new MultiMesh reads its GPU buffer back, a render stall per batch at load.
		var data := PackedFloat32Array()
		data.resize(transforms.size() * 12)
		for i in transforms.size():
			var transform: Transform3D = transforms[i]
			var b := transform.basis
			var o := transform.origin
			var k := i * 12
			data[k] = b.x.x; data[k + 1] = b.y.x; data[k + 2] = b.z.x; data[k + 3] = o.x
			data[k + 4] = b.x.y; data[k + 5] = b.y.y; data[k + 6] = b.z.y; data[k + 7] = o.y
			data[k + 8] = b.x.z; data[k + 9] = b.y.z; data[k + 10] = b.z.z; data[k + 11] = o.z
		multimesh.buffer = data
		var instances := MultiMeshInstance3D.new()
		instances.name = "Detail_" + key.replace(":", "_")
		instances.multimesh = multimesh
		instances.material_override = _materials[batch["material"]]
		instances.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_decoration.add_child(instances)
	_details.clear()

## Room furniture is static. Keep colliders/markers and labels separate; combine
## opaque geometry by material and shadow setting once, rather than hundreds of draws.
func _batch_furnishings() -> void:
	var batches: Dictionary = {}
	var indexed_meshes: Dictionary = {}
	for part: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
		if part.mesh == null: continue
		var transform_to_room: Transform3D = global_transform.affine_inverse() * part.global_transform
		var cast: int = part.cast_shadow
		if (transform_to_room * part.get_aabb()).get_longest_axis_size() < 1.6:
			cast = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material: Material = part.material_override
		if material == null: continue  # model meshes with their own surface materials (the kiosk hayburger) stay as they are
		var key: String = str(material.get_instance_id()) + ":" + str(cast)
		if not batches.has(key):
			var tool := SurfaceTool.new(); tool.begin(Mesh.PRIMITIVE_TRIANGLES)
			tool.set_material(material)
			batches[key] = {"tool":tool,"shadow":cast}
		var tool: SurfaceTool = batches[key].tool
		# append_from must not mix indexed primitives with the unindexed rounded
		# furniture: otherwise the latter has vertices but no draw indices.
		if not indexed_meshes.has(part.mesh):
			var indexed := ArrayMesh.new()
			for surface: int in part.mesh.get_surface_count():
				var arrays: Array = part.mesh.surface_get_arrays(surface)
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
				if indices.is_empty():
					indices.resize(arrays[Mesh.ARRAY_VERTEX].size())
					for i: int in indices.size(): indices[i] = i
					arrays[Mesh.ARRAY_INDEX] = indices
				indexed.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
			indexed_meshes[part.mesh] = indexed
		var source: ArrayMesh = indexed_meshes[part.mesh]
		for surface: int in source.get_surface_count():
			tool.append_from(source,surface,transform_to_room)
		# Leave named nodes intact for measurements; they no longer draw individually.
		part.mesh = null
	for key: String in batches:
		var entry: Dictionary = batches[key]
		var mesh := MeshInstance3D.new(); mesh.name = "FurnitureBatch"
		mesh.mesh = entry.tool.commit(); mesh.cast_shadow = entry.shadow
		add_child(mesh)
