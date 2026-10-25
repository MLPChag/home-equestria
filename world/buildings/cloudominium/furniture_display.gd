extends RefCounted
## Rainbow Dash's display pieces in the Cloudominium (dev 2026-09-28): the Wonderbolt statue in
## the entrance hall (user-entrance-hall-statue.png: dark grey flyer, goggles on, wings spread,
## on a stone pedestal), the closet with Wonderbolts uniforms and her trophy shelf (living-room
## reference and dev's brief). Broad statue forms; the game's ink outline draws the lines.
## Pieces: origin on the floor (the shelf: at its lowest board), front is local +Z.
const ROOM := preload("res://world/buildings/cloudominium/room_props.gd")
const TRIPO := preload("res://world/buildings/cloudominium/tripo_props.gd")
const SHAPES := preload("res://world/buildings/cloudominium/furniture_shapes.gd")
## Statue wing outline in its own plane: x along the span, y along the chord (+y leading edge),
## the trailing edge in broad feather scallops.
const WING := [Vector2(0.0, 0.1), Vector2(0.2, 0.17), Vector2(0.45, 0.2), Vector2(0.68, 0.17), Vector2(0.85, 0.1),
	Vector2(0.8, 0.02), Vector2(0.73, 0.04), Vector2(0.68, -0.06), Vector2(0.6, -0.03), Vector2(0.54, -0.13),
	Vector2(0.46, -0.08), Vector2(0.38, -0.17), Vector2(0.3, -0.1), Vector2(0.2, -0.16), Vector2(0.1, -0.08), Vector2(0.0, -0.06)]

## The flyer faces local +X (seen side-on from the room's front, as in the reference).
static func wonderbolt_statue(parent: Node3D, at: Transform3D) -> Node3D:
	var piece := Node3D.new()
	piece.name = "WonderboltStatue"
	piece.transform = at
	var mesh := SHAPES.new()
	var top := 1.04
	mesh.lathe(Transform3D.IDENTITY, PackedVector2Array([Vector2(0, 0), Vector2(0.46, 0), Vector2(0.46, 0.1), Vector2(0.4, 0.14), Vector2(0.4, 0.2),
		Vector2(0.2, 0.26), Vector2(0.17, 0.3), Vector2(0.15, 0.78), Vector2(0.19, 0.82), Vector2(0.36, 0.92), Vector2(0.44, 0.95),
		Vector2(0.44, top), Vector2(0, top)]), "stone", 32)
	mesh.commit(piece, "Pedestal")
	mesh = SHAPES.new()
	var s := "statue"
	var o := Vector3(0, top, 0)
	mesh.tube(PackedVector3Array([o, o + Vector3(0, 0.3, 0)]), 0.05, s, 10)
	# Barrel, chest and rump.
	mesh.blob(SHAPES.place(o + Vector3(0, 0.45, 0)), Vector3(0.34, 0.17, 0.16), s, 2.0, 12, 20)
	mesh.blob(SHAPES.place(o + Vector3(0.24, 0.48, 0)), Vector3(0.17, 0.18, 0.16), s, 2.0, 12, 18)
	mesh.blob(SHAPES.place(o + Vector3(-0.24, 0.47, 0)), Vector3(0.19, 0.19, 0.17), s, 2.0, 12, 18)
	# Neck, head, muzzle and ears.
	mesh.tube(PackedVector3Array([o + Vector3(0.28, 0.52, 0), o + Vector3(0.38, 0.66, 0), o + Vector3(0.45, 0.75, 0)]), 0.09, s, 12, PackedFloat32Array([0.1, 0.085, 0.075]))
	mesh.blob(SHAPES.place(o + Vector3(0.5, 0.8, 0)), Vector3(0.15, 0.13, 0.12), s, 2.0, 12, 18)
	mesh.blob(SHAPES.place(o + Vector3(0.62, 0.74, 0)), Vector3(0.1, 0.075, 0.085), s, 2.0, 10, 16)
	for side: float in [-1.0, 1.0]:
		mesh.blob(Transform3D(Basis(Vector3.BACK, 0.35), o + Vector3(0.44, 0.93, side * 0.06)), Vector3(0.03, 0.07, 0.025), s, 2.0, 8, 12)
	# Mane swept back along the neck, tail streaming behind.
	mesh.tube(PackedVector3Array([o + Vector3(0.46, 0.9, 0), o + Vector3(0.36, 0.84, 0), o + Vector3(0.28, 0.72, 0), o + Vector3(0.2, 0.62, 0)]), 0.045, s, 10)
	mesh.tube(PackedVector3Array([o + Vector3(-0.4, 0.5, 0), o + Vector3(-0.56, 0.53, 0), o + Vector3(-0.72, 0.58, 0), o + Vector3(-0.86, 0.54, 0),
		o + Vector3(-0.96, 0.46, 0)]), 0.06, s, 10, PackedFloat32Array([0.07, 0.07, 0.06, 0.05, 0.035]))
	# Forelegs reaching forward (one bent), hind legs trailing.
	mesh.tube(PackedVector3Array([o + Vector3(0.24, 0.38, -0.08), o + Vector3(0.38, 0.28, -0.08), o + Vector3(0.52, 0.27, -0.08)]), 0.045, s, 10)
	mesh.tube(PackedVector3Array([o + Vector3(0.24, 0.38, 0.08), o + Vector3(0.38, 0.33, 0.08), o + Vector3(0.44, 0.4, 0.08)]), 0.045, s, 10)
	for z: float in [-0.08, 0.08]:
		mesh.tube(PackedVector3Array([o + Vector3(-0.28, 0.36, z), o + Vector3(-0.46, 0.3, z), o + Vector3(-0.62, 0.3 + (0.05 if z > 0.0 else 0.0), z)]), 0.05, s, 10)
	# Goggles: two lenses on the brow and a strap around the head.
	var goggle := "#9aa4ad"
	var along_x := Basis(Vector3.BACK, -PI * 0.5)
	for side: float in [-1.0, 1.0]:
		mesh.lathe(Transform3D(along_x, o + Vector3(0.59, 0.85, side * 0.065)), PackedVector2Array([Vector2(0, 0), Vector2(0.045, 0), Vector2(0.045, 0.045), Vector2(0, 0.045)]), goggle, 16)
	mesh.torus(Transform3D(along_x, o + Vector3(0.5, 0.81, 0)), 0.135, 0.012, goggle, 28, 6)
	# Wings spread high.
	var outline := PackedVector2Array(WING)
	for side: float in [-1.0, 1.0]:
		var spread := Vector3(0, 0.74, side * 0.67).normalized()
		var chord := Vector3.RIGHT
		mesh.prism(Transform3D(Basis(spread, chord, spread.cross(chord)), o + Vector3(0.08, 0.58, side * 0.1)), outline, 0.035, s)
	if not TRIPO.add_visual(piece, "statue", Vector3(0, top, 0)):
		mesh.commit(piece, "Visual")
	var solid := SHAPES.body(piece, "Solid")
	SHAPES.cylinder_shape(solid, 0.46, top, Vector3(0, top * 0.5, 0))
	SHAPES.box_shape(solid, Vector3(1.4, 0.55, 0.36), SHAPES.place(o + Vector3(-0.1, 0.52, 0)))
	parent.add_child(piece)
	return piece

## Arched closet, both doors swung open, two Wonderbolts uniforms and her rainbow scarf inside.
static func uniform_closet(parent:Node3D,at:Transform3D)->Node3D:
	var piece:=Node3D.new();piece.name="BedroomDresser";piece.transform=at
	ROOM.add_visual(piece,"rd_comode")
	SHAPES.box_shape(SHAPES.body(piece,"Solid"),Vector3(1.2,2.1,.6),SHAPES.place(Vector3(0,1.05,0)))
	parent.add_child(piece);return piece

## One Wonderbolts flight suit on a hanger; `at` is the hook on the rail.
static func _uniform(mesh: SHAPES, at: Transform3D) -> void:
	var blue := "#2f5fb5"
	var yellow := "#f4d03c"
	mesh.tube(PackedVector3Array([at * Vector3(0, 0.02, 0), at * Vector3(0, -0.07, 0)]), 0.008, "iron", 6)
	mesh.tube(PackedVector3Array([at * Vector3(-0.19, -0.16, 0), at * Vector3(0, -0.07, 0), at * Vector3(0.19, -0.16, 0)]), 0.009, "iron", 6)
	mesh.blob(at * SHAPES.place(Vector3(0, -0.36, 0)), Vector3(0.21, 0.22, 0.075), blue, 2.4, 10, 18)
	mesh.torus(at * SHAPES.place(Vector3(0, -0.15, 0)), 0.07, 0.014, yellow, 20, 6)
	for x: float in [-0.13, 0.13]:
		mesh.tube(PackedVector3Array([at * Vector3(x, -0.5, 0.01), at * Vector3(x * 1.08, -0.78, 0.015), at * Vector3(x * 1.12, -0.96, 0.02)]), 0.04, blue, 10)
		mesh.blob(at * SHAPES.place(Vector3(x * 1.12, -0.97, 0.02)), Vector3(0.046, 0.03, 0.046), yellow)
	mesh.prism(at * SHAPES.place(Vector3(0, -0.36, 0.072)), SHAPES.bolt(0.22), 0.012, yellow)

## Wall-hung trophy shelf: three boards under an arched back, gold trophies on them.
static func trophy_shelf(parent: Node3D, at: Transform3D) -> Node3D:
	var piece := Node3D.new()
	piece.name = "TrophyShelf"
	piece.transform = at
	var mesh := SHAPES.new()
	var half := 0.66
	var back := PackedVector2Array([Vector2(-half, -0.1), Vector2(half, -0.1)])
	for k in 13:
		var angle := PI * float(k) / 12.0
		back.append(Vector2(cos(angle) * half, 1.05 + sin(angle) * 0.2))
	mesh.prism(SHAPES.place(Vector3(0, 0, -0.165)), back, 0.03, "column")
	for side: float in [-1.0, 1.0]:
		mesh.box(SHAPES.place(Vector3(side * (half - 0.02), 0.475, 0)), Vector3(0.04, 1.15, 0.3), "column")
		# Iron scroll bracket under the lowest board.
		mesh.tube(PackedVector3Array([Vector3(side * 0.45, -0.02, 0.12), Vector3(side * 0.45, -0.08, 0.03), Vector3(side * 0.45, -0.17, -0.08),
			Vector3(side * 0.45, -0.26, -0.14)]), 0.018, "iron", 8)
	for y: float in [0.0, 0.45, 0.9]:
		mesh.box(SHAPES.place(Vector3(0, y, 0)), Vector3(half * 2.0 - 0.06, 0.04, 0.3), "column")
		mesh.tube(PackedVector3Array([Vector3(-half + 0.05, y + 0.025, 0.15), Vector3(half - 0.05, y + 0.025, 0.15)]), 0.01, "brass", 6)
	if TRIPO.add_visual(piece, "trophy", Vector3(-0.36, 0.02, 0)):
		TRIPO.add_visual(piece, "trophy", Vector3(0.08, 0.02, 0), Vector3.ONE * 0.7)
		_plaque(mesh, Vector3(0.42, 0.02, -0.06))
		TRIPO.add_visual(piece, "trophy", Vector3(-0.2, 0.47, 0), Vector3.ONE * 0.9)
		TRIPO.add_visual(piece, "trophy", Vector3(0.3, 0.47, 0), Vector3.ONE * 0.72)
		TRIPO.add_visual(piece, "trophy", Vector3(0, 0.92, 0), Vector3.ONE * 0.82)
	else:
		_cup(mesh, Vector3(-0.36, 0.02, 0.0), 0.34)
		_star_trophy(mesh, Vector3(0.08, 0.02, 0.0))
		_plaque(mesh, Vector3(0.42, 0.02, -0.06))
		_wing_trophy(mesh, Vector3(-0.2, 0.47, 0.0))
		_cup(mesh, Vector3(0.3, 0.47, 0.0), 0.24)
		_cup(mesh, Vector3(0.0, 0.92, 0.0), 0.28)
	mesh.commit(piece, "Visual")
	SHAPES.box_shape(SHAPES.body(piece, "Solid"), Vector3(half * 2.0, 1.2, 0.34), SHAPES.place(Vector3(0, 0.5, -0.01)))
	parent.add_child(piece)
	return piece

static func _plinth(mesh: SHAPES, at: Vector3, radius: float, height: float) -> void:
	mesh.lathe(SHAPES.place(at), PackedVector2Array([Vector2(0, 0), Vector2(radius, 0), Vector2(radius, height * 0.75), Vector2(radius * 0.8, height), Vector2(0, height)]), "#3a3550", 20)

static func _cup(mesh: SHAPES, at: Vector3, height: float) -> void:
	var k := height / 0.3
	_plinth(mesh, at, 0.06 * k, 0.045 * k)
	var profile := PackedVector2Array()
	for p: Vector2 in [Vector2(0, 0.045), Vector2(0.035, 0.045), Vector2(0.013, 0.075), Vector2(0.012, 0.12), Vector2(0.03, 0.145), Vector2(0.07, 0.2),
			Vector2(0.086, 0.27), Vector2(0.088, 0.3), Vector2(0.076, 0.3), Vector2(0.07, 0.26), Vector2(0.055, 0.2), Vector2(0, 0.18)]:
		profile.append(p * k)
	mesh.lathe(SHAPES.place(at), profile, "brass", 24, true)
	for side: float in [-1.0, 1.0]:
		mesh.tube(PackedVector3Array([at + Vector3(side * 0.075, 0.26, 0) * k, at + Vector3(side * 0.125, 0.25, 0) * k, at + Vector3(side * 0.12, 0.19, 0) * k,
			at + Vector3(side * 0.06, 0.16, 0) * k]), 0.009 * k, "brass", 6)

static func _star_trophy(mesh: SHAPES, at: Vector3) -> void:
	_plinth(mesh, at, 0.06, 0.04)
	mesh.lathe(SHAPES.place(at), PackedVector2Array([Vector2(0, 0.04), Vector2(0.03, 0.04), Vector2(0.014, 0.08), Vector2(0.012, 0.19), Vector2(0.025, 0.21), Vector2(0, 0.22)]), "brass", 16, true)
	mesh.prism(SHAPES.place(at + Vector3(0, 0.285, 0)), SHAPES.star(5, 0.075, 0.032), 0.025, "brass")

static func _wing_trophy(mesh: SHAPES, at: Vector3) -> void:
	_plinth(mesh, at, 0.065, 0.045)
	mesh.lathe(SHAPES.place(at), PackedVector2Array([Vector2(0, 0.045), Vector2(0.03, 0.045), Vector2(0.012, 0.09), Vector2(0.012, 0.17), Vector2(0, 0.18)]), "brass", 16, true)
	mesh.blob(SHAPES.place(at + Vector3(0, 0.215, 0)), Vector3.ONE * 0.045, "brass", 2.0, 10, 16)
	var feather := PackedVector2Array([Vector2(0, 0), Vector2(0.05, 0.06), Vector2(0.12, 0.1), Vector2(0.1, 0.05), Vector2(0.15, 0.04), Vector2(0.09, 0.0),
		Vector2(0.12, -0.03), Vector2(0.05, -0.03)])
	for side: float in [-1.0, 1.0]:
		var mirrored := PackedVector2Array()
		for p: Vector2 in feather:
			mirrored.append(Vector2(p.x * side, p.y))
		mesh.prism(SHAPES.place(at + Vector3(side * 0.03, 0.225, 0)), mirrored, 0.014, "brass")

static func _plaque(mesh: SHAPES, at: Vector3) -> void:
	var lean := Transform3D(Basis(Vector3.RIGHT, -0.18), at + Vector3(0, 0.1, 0))
	mesh.box(lean, Vector3(0.17, 0.2, 0.025), "#3a3550")
	mesh.prism(lean * SHAPES.place(Vector3(0, 0, 0.014)), SHAPES.bolt(0.15), 0.006, "brass")
