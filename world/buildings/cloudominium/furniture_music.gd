extends RefCounted
## The Cloudominium music corner (dev 2026-09-28), after user-living-room-stair-poster.png:
## the red and gold chaise longue with a pink blanket, the rainbow flying-V guitar leaning on a
## small amp, the Wonderbolts poster and Princess Celestia's red sun banner on the wall, a pink
## star ball and a few books and comics on the floor, and the Wonderbolt helmet bust.
## Pieces: origin on the floor (wall art: at its centre or top), front is local +Z.
const ROOM := preload("res://world/buildings/cloudominium/room_props.gd")
const TRIPO := preload("res://world/buildings/cloudominium/tripo_props.gd")
const SHAPES := preload("res://world/buildings/cloudominium/furniture_shapes.gd")

## The chaise is a couch (world/life/couch.gd): two seats, recline together. `high_side` picks
## the end with the tall scroll arm (-1: local -X).
static func chaise(parent: Node3D, at: Transform3D, high_side: float = -1.0) -> Node3D:
	var piece := Node3D.new()
	piece.name = "RedChaise"
	piece.transform = at
	var hs := -1.0 if high_side < 0.0 else 1.0
	var mesh := SHAPES.new()
	# Gold frame and short curved legs.
	mesh.blob(SHAPES.place(Vector3(0, 0.28, 0)), Vector3(0.84, 0.09, 0.33), "gold_wood", 4.0, 8, 24)
	for x: float in [-0.7, 0.7]:
		for z: float in [-0.24, 0.24]:
			mesh.tube(PackedVector3Array([Vector3(x, 0.24, z), Vector3(x * 1.04, 0.12, z * 1.1), Vector3(x * 1.07, 0.03, z * 1.18)]), 0.03, "gold_wood", 8)
	# Red velvet seat and low back.
	mesh.blob(SHAPES.place(Vector3(0, 0.4, 0.02)), Vector3(0.78, 0.08, 0.3), "red_velvet", 4.0, 8, 24)
	mesh.blob(Transform3D(Basis(Vector3.RIGHT, -0.12), Vector3(0, 0.62, -0.27)), Vector3(0.78, 0.19, 0.075), "red_velvet", 3.5, 10, 24)
	# Gold back rail rising to the high end.
	var rail := PackedVector3Array()
	for p: Vector3 in [Vector3(-0.86, 0.66, -0.3), Vector3(-0.4, 0.8, -0.32), Vector3(0.2, 0.84, -0.33), Vector3(0.62, 0.9, -0.32), Vector3(0.86, 1.0, -0.26)]:
		rail.append(Vector3(p.x * hs, p.y, p.z))
	mesh.tube(rail, 0.034, "gold_wood", 10)
	# Arms: velvet pads under gold rolls, a swirl on each roll's front end.
	for arm: Vector4 in [Vector4(hs, 0.6, 0.24, 0.075), Vector4(-hs, 0.5, 0.14, 0.06)]:
		var x := arm.x * 0.83
		mesh.blob(SHAPES.place(Vector3(x, arm.y, 0.0)), Vector3(0.09, arm.z, 0.31), "red_velvet", 3.0, 10, 18)
		var roll := Vector3(arm.x * 0.88, arm.y + arm.z + arm.w * 0.3, 0.0)
		mesh.tube(PackedVector3Array([roll + Vector3(0, 0, -0.3), roll + Vector3(0, 0, 0.3)]), arm.w, "gold_wood", 14)
		mesh.swirl(roll + Vector3(0, 0, 0.3), arm.w, Basis.IDENTITY, "#b98b2c", 1.6, 0.78, 0.008)
	# Pale pillow against the low arm.
	mesh.blob(Transform3D(Basis(Vector3.BACK, 0.5 * hs), Vector3(-0.62 * hs, 0.56, -0.05)), Vector3(0.18, 0.08, 0.15), "cloud", 2.6, 10, 16)
	# The pink blanket across the high half, over the front edge and pooling on the floor.
	var rows: Array[PackedVector3Array] = []
	for p: Vector2 in [Vector2(-0.15, 0.495), Vector2(0.05, 0.5), Vector2(0.28, 0.49), Vector2(0.37, 0.36), Vector2(0.4, 0.18), Vector2(0.44, 0.05), Vector2(0.6, 0.012)]:
		var hang := clampf((0.49 - p.y) / 0.48, 0.0, 1.0)
		var row := PackedVector3Array()
		for c in 9:
			var u := float(c) / 8.0
			var wave := sin(u * TAU * 1.5 + p.x * 4.0)
			row.append(Vector3(hs * lerpf(0.05, 0.64, u) + hang * 0.04 * wave, p.y + wave * 0.006 * (1.0 - hang), p.x + wave * 0.035 * hang))
		rows.append(row)
	mesh.sheet(rows, "pink_blanket")
	if not TRIPO.add_visual(piece, "chaise"):
		mesh.commit(piece, "Visual")
	SHAPES.seating(piece, [Vector3(-0.4, 0.42, 0.06), Vector3(0.4, 0.42, 0.06)],
		[SHAPES.span(Vector3(0, 0.21, 0), Vector3(1.6, 0.42, 0.62))],
		[SHAPES.span(Vector3(0, 0.72, -0.28), Vector3(1.8, 0.5, 0.16)), SHAPES.span(Vector3(0.86 * hs, 0.66, 0), Vector3(0.22, 0.5, 0.66)),
			SHAPES.span(Vector3(-0.86 * hs, 0.55, 0), Vector3(0.22, 0.26, 0.66))], true)
	parent.add_child(piece)
	return piece

## The rainbow flying V (materials.gd "guitar" paints diagonal rainbow bands on its body).
## Local: y up the neck, x across, front +Z, origin on the floor between the two tips.
static func flying_v(parent: Node3D, at: Transform3D) -> Node3D:
	var piece := Node3D.new()
	piece.name = "RainbowFlyingV"
	piece.transform = at
	var mesh := SHAPES.new()
	var body := PackedVector2Array([Vector2(-0.07, 0.44), Vector2(0.07, 0.44), Vector2(0.25, 0.04), Vector2(0.2, 0.0),
		Vector2(0.0, 0.24), Vector2(-0.2, 0.0), Vector2(-0.25, 0.04)])
	mesh.prism(Transform3D.IDENTITY, body, 0.04, "guitar", "#c8302c")
	for y: float in [0.3, 0.37]:
		mesh.box(SHAPES.place(Vector3(0, y, 0.023)), Vector3(0.1, 0.035, 0.008), "#222222")
	for x: float in [-0.12, 0.12]:
		mesh.blob(SHAPES.place(Vector3(x, 0.14, 0.024)), Vector3(0.018, 0.018, 0.01), "#efefef")
	mesh.box(SHAPES.place(Vector3(0, 0.71, 0)), Vector3(0.052, 0.62, 0.028), "#8b5a33")
	mesh.box(SHAPES.place(Vector3(0, 0.74, 0.016)), Vector3(0.046, 0.56, 0.006), "#3b2a20")
	mesh.prism(SHAPES.place(Vector3(0, 0, 0)), PackedVector2Array([Vector2(-0.035, 1.0), Vector2(0.035, 1.0), Vector2(0.055, 1.08),
		Vector2(0.0, 1.2), Vector2(-0.05, 1.1)]), 0.03, "#d63a30")
	for k in 3:
		for side: float in [-1.0, 1.0]:
			mesh.blob(SHAPES.place(Vector3(side * 0.045, 1.04 + k * 0.035, 0.0)), Vector3(0.012, 0.012, 0.012), "#d9d9d9")
	if not TRIPO.add_visual(piece, "guitar"):
		mesh.commit(piece, "Visual")
	parent.add_child(piece)
	return piece

## Small practice amp (materials.gd "amp": grille and control strip on its +Z/-Z faces).
static func amp(parent: Node3D, at: Transform3D) -> Node3D:
	var piece := Node3D.new()
	piece.name = "PracticeAmp"
	piece.transform = at
	var size := Vector3(0.5, 0.42, 0.26)
	var replaced := TRIPO.add_visual(piece, "amp")
	if not replaced:
		SHAPES.box_mesh(piece, "Cabinet", size, SHAPES.place(Vector3(0, size.y * 0.5, 0)), "amp")
	var mesh := SHAPES.new()
	var handle := PackedVector3Array()
	for k in 9:
		var angle := PI * float(k) / 8.0
		handle.append(Vector3(cos(angle) * 0.1, size.y + sin(angle) * 0.035, 0))
	mesh.tube(handle, 0.012, "iron", 6)
	if not replaced: mesh.commit(piece, "Visual")
	SHAPES.box_shape(SHAPES.body(piece, "Solid"), size, SHAPES.place(Vector3(0, size.y * 0.5, 0)))
	parent.add_child(piece)
	return piece

## The actual Wonderbolts poster, with the requested 10-degree roll on solid lining.
static func poster(parent:Node3D,at:Transform3D)->Node3D:
	var piece:=Node3D.new();piece.name="WonderboltsPoster"
	piece.transform=at*Transform3D(Basis(Vector3.BACK,deg_to_rad(10)),Vector3.ZERO)
	ROOM.add_visual(piece,"wonderbolts_poster");parent.add_child(piece);return piece

## The source rainbow drape; origin at its top centre.
static func banner(parent:Node3D,at:Transform3D)->Node3D:
	var piece:=Node3D.new();piece.name="RainbowDrape";piece.transform=at
	ROOM.add_visual(piece,"rainbow_flag");parent.add_child(piece);return piece

## The pink play ball with pale stars; `at` is the ball's centre (0.16 m above the floor).
static func star_ball(parent: Node3D, at: Vector3) -> Node3D:
	var piece := Node3D.new()
	piece.name = "StarBall"
	piece.position = at
	var mesh := SHAPES.new()
	var radius := 0.16
	mesh.blob(Transform3D.IDENTITY, Vector3.ONE * radius, "#cf2f73", 2.0, 14, 22)
	var outline := SHAPES.star(5, 0.05, 0.022)
	for i in 8:
		# Fibonacci directions spread the stars evenly over the ball.
		var y := 1.0 - 2.0 * (float(i) + 0.5) / 8.0
		var ring := sqrt(maxf(1.0 - y * y, 0.0))
		var turn := float(i) * 2.39996
		var toward := Vector3(cos(turn) * ring, y, sin(turn) * ring)
		var across := Vector3.UP.cross(toward)
		if across.length_squared() < 0.01:
			across = Vector3.RIGHT.cross(toward)
		across = across.normalized()
		mesh.prism(Transform3D(Basis(across, toward.cross(across), toward), toward * radius), outline, 0.014, "#f7b3d2")
	mesh.commit(piece, "Visual")
	parent.add_child(piece)
	return piece

## An open comic, a Daring Do-brown book with a bolt, and a purple book on the floor.
static func floor_books(parent: Node3D, at: Transform3D) -> Node3D:
	var piece := Node3D.new()
	piece.name = "FloorBooksAndComics"
	piece.transform = at
	var mesh := SHAPES.new()
	for side: float in [-1.0, 1.0]:
		var page := Transform3D(Basis(Vector3.BACK, side * 0.08), Vector3(side * 0.085, 0.012, 0))
		mesh.box(page * SHAPES.place(Vector3(0, -0.004, 0)), Vector3(0.17, 0.004, 0.25), "#e8413d")
		mesh.box(page * SHAPES.place(Vector3(0, 0.002, 0)), Vector3(0.16, 0.008, 0.24), "#fbf6e6")
		mesh.box(page * SHAPES.place(Vector3(-0.03, 0.0065, -0.05)), Vector3(0.07, 0.001, 0.08), "#3a9be0")
		mesh.box(page * SHAPES.place(Vector3(0.035, 0.0065, 0.06)), Vector3(0.06, 0.001, 0.09), "#f5cf3a")
	mesh.book(SHAPES.place(Vector3(0.42, 0, 0.18), 0.5), Vector3(0.24, 0.05, 0.18), "#7b4a2e")
	mesh.prism(SHAPES.place(Vector3(0.42, 0.052, 0.18), 0.5, -PI * 0.5), SHAPES.bolt(0.1), 0.004, "#f5cf3a")
	mesh.book(SHAPES.place(Vector3(-0.3, 0, 0.3), -0.3), Vector3(0.2, 0.035, 0.15), "book")
	mesh.commit(piece, "Visual")
	parent.add_child(piece)
	return piece

## The living-room reference's Wonderbolt helmet bust: a blue pony head in the winged helmet,
## goggles on the brow, on a round pedestal. She looks along local +Z.
static func helmet_bust(parent: Node3D, at: Transform3D) -> Node3D:
	var piece := Node3D.new()
	piece.name = "WonderboltHelmetBust"
	piece.transform = at
	var mesh := SHAPES.new()
	var blue := "#5f86cf"
	mesh.lathe(Transform3D.IDENTITY, PackedVector2Array([Vector2(0, 0), Vector2(0.27, 0), Vector2(0.27, 0.07), Vector2(0.21, 0.11), Vector2(0.15, 0.17),
		Vector2(0.13, 0.7), Vector2(0.18, 0.76), Vector2(0.23, 0.8), Vector2(0.23, 0.86), Vector2(0, 0.86)]), "column", 28)
	mesh.commit(piece, "Pedestal")
	mesh = SHAPES.new()
	mesh.lathe(SHAPES.place(Vector3(0, 0.86, 0)), PackedVector2Array([Vector2(0, 0), Vector2(0.17, 0), Vector2(0.15, 0.05), Vector2(0.1, 0.08), Vector2(0, 0.09)]), blue, 24, true)
	mesh.tube(PackedVector3Array([Vector3(0, 0.92, -0.03), Vector3(0, 1.08, 0.0), Vector3(0, 1.22, 0.06)]), 0.12, blue, 14, PackedFloat32Array([0.13, 0.115, 0.105]))
	mesh.blob(SHAPES.place(Vector3(0, 1.33, 0.1)), Vector3(0.13, 0.13, 0.18), blue, 2.0, 12, 18)
	mesh.blob(SHAPES.place(Vector3(0, 1.27, 0.25)), Vector3(0.09, 0.08, 0.1), blue, 2.0, 10, 16)
	# Helmet dome, gold band, goggles and swept gold wings.
	mesh.blob(SHAPES.place(Vector3(0, 1.4, 0.07)), Vector3(0.15, 0.1, 0.2), "#3f63b5", 2.2, 12, 18)
	var band := PackedVector3Array()
	for k in 25:
		var angle := TAU * float(k) / 24.0
		band.append(Vector3(sin(angle) * 0.135, 1.37, 0.1 + cos(angle) * 0.182))
	mesh.tube(band, 0.013, "brass", 6, PackedFloat32Array(), false)
	for side: float in [-1.0, 1.0]:
		mesh.lathe(Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(side * 0.06, 1.38, 0.24)), PackedVector2Array([Vector2(0, 0), Vector2(0.042, 0), Vector2(0.042, 0.03), Vector2(0, 0.03)]), "#a9cdef", 16)
		var wing_frame := Basis(Vector3(0, 0, -1), side * 0.3) * Basis(Vector3(0, 0, -1), Vector3.UP, Vector3.RIGHT)
		mesh.prism(Transform3D(wing_frame, Vector3(side * 0.13, 1.42, 0.04)), PackedVector2Array([Vector2(0.0, 0.0), Vector2(0.04, 0.12), Vector2(0.1, 0.22),
			Vector2(0.16, 0.28), Vector2(0.14, 0.2), Vector2(0.2, 0.22), Vector2(0.17, 0.14), Vector2(0.23, 0.14), Vector2(0.17, 0.06), Vector2(0.1, 0.0)]), 0.02, "brass")
	if not TRIPO.add_visual(piece, "helmet_bust", Vector3(0, 0.86, 0)):
		mesh.commit(piece, "Visual")
	SHAPES.cylinder_shape(SHAPES.body(piece, "Solid"), 0.27, 0.86, Vector3(0, 0.43, 0))
	parent.add_child(piece)
	return piece
