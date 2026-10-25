extends RefCounted
## Visible reference furniture, in metres. Does not alter the tested traversal collision.
const KIT := preload("res://world/buildings/golden_oak/furniture_kit.gd")
const OPEN_BOOK := preload("res://world/books/open_book.gd")

static func lathe(parent: Node3D, label_text: String, profile: PackedVector2Array, finish: Material, at: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(finish)
	for row: int in profile.size() - 1:
		for side: int in 32:
			var a: float = TAU * side / 32.0
			var b: float = TAU * (side + 1) / 32.0
			var lower: Vector2 = profile[row]
			var upper: Vector2 = profile[row + 1]
			var points: Array[Vector3] = [Vector3(sin(a) * lower.x, lower.y, cos(a) * lower.x), Vector3(sin(b) * lower.x, lower.y, cos(b) * lower.x), Vector3(sin(b) * upper.x, upper.y, cos(b) * upper.x), Vector3(sin(a) * upper.x, upper.y, cos(a) * upper.x)]
			for index: int in [0, 2, 1, 0, 3, 2]:
				st.add_vertex(points[index])
	st.generate_normals()
	var result := MeshInstance3D.new()
	result.name = label_text
	result.position = at
	result.mesh = st.commit()
	parent.add_child(result)
	return result

static func rooted_table(parent: Node3D, centre: Vector3) -> void:
	var wood := KIT.material("a84243")
	var grain := KIT.material("7e323b")
	var golden := KIT.material("f2b679")
	lathe(parent, "ReadingStump", PackedVector2Array([Vector2(0, 0.035), Vector2(0.43, 0.035), Vector2(0.35, 0.12), Vector2(0.27, 0.3), Vector2(0.29, 0.49), Vector2(0.46, 0.555), Vector2(0, 0.555)]), wood, centre)
	for root: int in 7:
		var angle: float = TAU * root / 7.0
		var direction: Vector3 = Vector3(sin(angle), 0, cos(angle))
		KIT.tube(parent, "TableRoot", PackedVector3Array([centre + direction * 0.15 + Vector3.UP * 0.38, centre + direction * 0.28 + Vector3.UP * 0.18, centre + direction * 0.46 + Vector3.UP * 0.075]), 0.085, wood)
		KIT.tube(parent, "TableGrain", PackedVector3Array([centre + direction * 0.3 + Vector3.UP * 0.50, centre + direction * 0.285 + Vector3.UP * 0.34, centre + direction * 0.41 + Vector3.UP * 0.1]), 0.008, grain)
	for radius: float in [0.37, 0.68, 0.84]:
		var ring := PackedVector3Array()
		for index: int in 65:
			var angle: float = TAU * index / 64.0
			var r: float = radius + sin(angle * 3.0) * 0.012
			ring.append(centre + Vector3(sin(angle) * r, 0.660, cos(angle) * r))
		KIT.tube(parent, "TableGrowthRing", ring, 0.0045, golden)

static func reading_stand(parent: Node3D, at: Vector3) -> void:
	var frame := Node3D.new()
	frame.name = "RootReadingStand"
	frame.position = at
	parent.add_child(frame)
	var wood := KIT.material("ad4747")
	for side: float in [-1.0, 1.0]:
		KIT.tube(frame, "StandRoot", PackedVector3Array([Vector3(side * 0.2, 0.015, 0.13), Vector3(side * 0.12, 0.08, 0.01), Vector3(side * 0.08, 0.15, -0.04)]), 0.035, wood)
	var desk := Node3D.new()
	desk.name = "SlopingBookRest"
	desk.position = Vector3(0, 0.15, 0)
	desk.rotation.x = deg_to_rad(18.0)
	frame.add_child(desk)
	KIT.box(desk, "CarvedDesk", Vector3(0.49, 0.032, 0.36), Vector3.ZERO, KIT.material("d47554"))
	KIT.tube(desk, "BookLip", PackedVector3Array([Vector3(-0.235, 0.023, 0.165), Vector3(0.235, 0.023, 0.165)]), 0.016, wood)
	var book := OPEN_BOOK.new()
	book.name = "OpenReferenceBook"
	book.position.y = 0.047
	desk.add_child(book)
	book.build(Color("586841"))
	book.open_amount = 1.0
	# Printed constellation marks on the actual open pages; library books remain
	# available beside the stand through the unchanged physical shelf-book system.
	var ink := KIT.material("655340")
	for side: float in [-1.0, 1.0]:
		for row: int in 6:
			var length: float = 0.1 - float(row % 3) * 0.012
			KIT.box(desk, "PrintedPageLine", Vector3(length, 0.001, 0.002), Vector3(side * 0.105, 0.056, -0.085 + row * 0.025), ink)

static func lantern(parent: Node3D, at: Vector3, ceiling_y: float) -> void:
	var frame := Node3D.new()
	frame.name = "ElongatedLibraryLantern"
	frame.position = at
	parent.add_child(frame)
	var purple := KIT.material("61264f")
	var gold := KIT.material("dcad53")
	var glass := KIT.material("f1cf73")
	glass.emission_enabled = true
	glass.emission = Color("ffd285")
	glass.emission_energy_multiplier = 0.45
	lathe(frame, "AmberLanternGlass", PackedVector2Array([Vector2(0, -0.33), Vector2(0.09, -0.28), Vector2(0.155, -0.1), Vector2(0.155, 0.12), Vector2(0.095, 0.32), Vector2(0, 0.35)]), glass)
	lathe(frame, "PlumLanternCap", PackedVector2Array([Vector2(0, 0.24), Vector2(0.105, 0.24), Vector2(0.12, 0.27), Vector2(0.08, 0.35), Vector2(0, 0.43)]), purple)
	lathe(frame, "PlumLanternBase", PackedVector2Array([Vector2(0, -0.43), Vector2(0.065, -0.37), Vector2(0.115, -0.27), Vector2(0.10, -0.24)]), purple)
	for side: int in 4:
		var angle: float = TAU * side / 4.0
		var rib := PackedVector3Array()
		for index: int in 17:
			var t: float = index / 16.0
			var r: float = 0.085 + sin(PI * t) * 0.075
			var twist: float = angle + sin(t * PI * 2.0) * 0.25
			rib.append(Vector3(sin(twist) * r, lerpf(-0.28, 0.30, t), cos(twist) * r))
		KIT.tube(frame, "SweptLanternRib", rib, 0.016, purple)
	KIT.disc(frame, "LanternGoldCollar", 0.11, 0.025, Vector3(0, 0.30, 0), gold)
	var loop := PackedVector3Array()
	for index: int in 25:
		var angle: float = TAU * index / 24.0
		loop.append(Vector3(cos(angle) * 0.065, 0.47 + sin(angle) * 0.085, 0))
	KIT.tube(frame, "LanternHangingLoop", loop, 0.016, purple)
	KIT.tube(frame, "LanternChain", PackedVector3Array([Vector3(0, 0.55, 0), Vector3(0, ceiling_y - at.y - 0.05, 0)]), 0.009, purple)

static func guest_curtains(parent: Node3D, loft_y: float) -> void:
	var gold := KIT.material("e7b04e")
	gold.cull_mode = BaseMaterial3D.CULL_DISABLED
	var tie := KIT.material("cc7850")
	# All cloth lies outside the established 1.55,-1.35 bed approach and opening.
	for side: float in [-1.0, 1.0]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(gold)
		for row: int in 20:
			for column: int in 14:
				var corners: Array[Vector3] = []
				for uv: Vector2 in [Vector2(column, row), Vector2(column + 1, row), Vector2(column + 1, row + 1), Vector2(column, row + 1)]:
					var u: float = uv.x / 14.0
					var v: float = uv.y / 20.0
					var width: float = 0.48 + 0.29 * pow(absf(v - 0.52) * 2.0, 1.4)
					var x: float = 1.55 + side * (1.28 - width * u)
					corners.append(Vector3(x, lerpf(0.16, loft_y - 0.25, v), -1.97 + sin(u * TAU * 3.0) * (0.04 + 0.03 * absf(v - 0.52))))
				for index: int in [0, 1, 2, 0, 2, 3]:
					st.add_vertex(corners[index])
		st.generate_normals()
		var curtain := MeshInstance3D.new()
		curtain.name = "GuestNookGoldenCurtain"
		curtain.mesh = st.commit()
		parent.add_child(curtain)
		KIT.tube(parent, "CurtainTie", PackedVector3Array([Vector3(1.55 + side * 1.3, 1.56, -1.89), Vector3(1.55 + side * 0.85, 1.49, -1.89)]), 0.035, tie)
	KIT.tube(parent, "GuestCurtainBough", PackedVector3Array([Vector3(0.22, loft_y - 0.2, -1.96), Vector3(1.55, loft_y - 0.17, -1.96), Vector3(2.87, loft_y - 0.2, -1.96)]), 0.07, KIT.material("ce775d"))

static func telescope(parent: Node3D, at: Vector3) -> void:
	var frame := Node3D.new()
	frame.name = "TwilightTelescope"
	frame.position = at
	frame.rotation.y = deg_to_rad(-45.0)
	parent.add_child(frame)
	var dark := KIT.material("332c44")
	var brass := KIT.material("c89a57")
	for index: int in 3:
		var angle: float = TAU * index / 3.0
		KIT.tube(frame, "TelescopeTripod", PackedVector3Array([Vector3(sin(angle) * 0.26, 0.03, cos(angle) * 0.26), Vector3(0, 0.8, 0)]), 0.026, dark)
	var barrel := Node3D.new()
	barrel.position = Vector3(0, 0.87, 0)
	barrel.rotation.x = deg_to_rad(65.0)
	frame.add_child(barrel)
	lathe(barrel, "OpticalTube", PackedVector2Array([Vector2(0.046, -0.42), Vector2(0.046, -0.26), Vector2(0.085, -0.24), Vector2(0.085, 0.32), Vector2(0.12, 0.34), Vector2(0.12, 0.43)]), dark)
	for y: float in [-0.23, 0.28, 0.42]:
		KIT.disc(barrel, "TelescopeBrassBand", 0.12 if y > 0.4 else 0.092, 0.035, Vector3(0, y, 0), brass)
	KIT.disc(barrel, "ObjectiveLens", 0.109, 0.008, Vector3(0, 0.445, 0), KIT.material("6ca7aa"))

static func fireplace(parent: Node3D, at: Vector3, yaw: float) -> void:
	var frame := Node3D.new()
	frame.name = "ReferenceFireplace"
	frame.transform = Transform3D(Basis(Vector3.UP, yaw), at)
	parent.add_child(frame)
	var stone := KIT.material("c3bba0")
	var light_stone := KIT.material("e6d7b2")
	var soot := KIT.material("382936")
	var arch := PackedVector3Array([Vector3(-0.46, 0.08, 0), Vector3(-0.48, 0.58, 0)])
	for index: int in 21:
		var angle: float = PI - PI * index / 20.0
		arch.append(Vector3(cos(angle) * 0.46, 0.72 + sin(angle) * 0.54, 0))
	arch.append(Vector3(0.47, 0.08, 0))
	KIT.tube(frame, "RoundedStoneHearth", arch, 0.16, stone)
	KIT.box(frame, "FireplaceRecess", Vector3(0.91, 1.13, 0.035), Vector3(0, 0.59, -0.15), soot)
	KIT.disc(frame, "Hearthstone", 0.64, 0.07, Vector3(0, 0.035, 0.02), light_stone)
	KIT.tube(frame, "SculptedMantel", PackedVector3Array([Vector3(-0.72, 1.30, 0.03), Vector3(-0.3, 1.4, 0.03), Vector3(0.3, 1.4, 0.03), Vector3(0.72, 1.3, 0.03)]), 0.105, light_stone)
	for index: int in 3:
		KIT.tube(frame, "HearthLog", PackedVector3Array([Vector3(-0.30, 0.15 + index * 0.035, -0.05 + index * 0.1), Vector3(0.30, 0.15 + index * 0.035, 0.08 - index * 0.04)]), 0.065, KIT.material("755047"))
	var ember := KIT.material("d58a4e")
	ember.emission_enabled = true
	ember.emission = Color("d27835")
	ember.emission_energy_multiplier = 0.25
	lathe(frame, "BankedHearthEmber", PackedVector2Array([Vector2(0, 0.16), Vector2(0.2, 0.18), Vector2(0.13, 0.28), Vector2(0, 0.37)]), ember, Vector3(0, 0, 0.02))
