extends RefCounted
## The Cloudominium lounge (dev 2026-09-28), after user-lounge-cloud-sofa.png: a lavender cloud
## sofa and armchair with rolled swirl arms and white cloud pillows, round glass tables on brass
## tripod legs, a lamp with a green shade on a purple base, purple lightning-bolt curtains tied
## back at the windows, and a dark teal-blue swirl rug. The sofa and armchair are real seats
## (world/life/seat.gd); the sofa is also a couch (world/life/couch.gd) to recline on together.
## Pieces: origin on the floor, front (where a sitter faces) is local +Z.
const ROOM := preload("res://world/buildings/cloudominium/room_props.gd")
const TRIPO := preload("res://world/buildings/cloudominium/tripo_props.gd")
const SHAPES := preload("res://world/buildings/cloudominium/furniture_shapes.gd")

static func cloud_sofa(parent: Node3D, at: Transform3D) -> Node3D:
	var piece := Node3D.new()
	piece.name = "CloudSofa"
	piece.transform = at
	var mesh := SHAPES.new()
	mesh.blob(SHAPES.place(Vector3(0, 0.2, -0.03)), Vector3(0.84, 0.2, 0.41), "cloud_fabric", 3.0, 10, 24)
	mesh.blob(SHAPES.place(Vector3(0, 0.37, 0.05)), Vector3(0.72, 0.1, 0.33), "cloud_fabric", 3.5, 10, 24)
	# Camel back: three soft lobes, the middle one highest, leaning back a little.
	for lobe: Vector3 in [Vector3(-0.5, 0.66, 0.3), Vector3(0.0, 0.73, 0.34), Vector3(0.5, 0.66, 0.3)]:
		mesh.blob(Transform3D(Basis(Vector3.RIGHT, -0.16), Vector3(lobe.x, lobe.y, -0.3)), Vector3(0.43, lobe.z, 0.16), "cloud_fabric", 2.4, 10, 20)
	for side: float in [-1.0, 1.0]:
		_scroll_arm(mesh, side * 0.86)
		_cloud_pillow(mesh, Vector3(side * 0.56, 0.56, -0.1), 1.0)
	if not TRIPO.add_visual(piece, "sofa"):
		mesh.commit(piece, "Visual")
	# The cushion shows at 0.47 m; sitters rest at 0.42 m, a little down in the cloud.
	SHAPES.seating(piece, [Vector3(-0.42, 0.42, 0.12), Vector3(0.42, 0.42, 0.12)],
		[SHAPES.span(Vector3(0, 0.21, 0.02), Vector3(1.6, 0.42, 0.62)), SHAPES.span(Vector3(0, 0.15, -0.03), Vector3(1.96, 0.3, 0.82))],
		[SHAPES.span(Vector3(0, 0.74, -0.33), Vector3(1.9, 0.62, 0.28)), SHAPES.span(Vector3(-0.88, 0.52, 0.02), Vector3(0.28, 0.3, 0.74)),
			SHAPES.span(Vector3(0.88, 0.52, 0.02), Vector3(0.28, 0.3, 0.74))], true)
	parent.add_child(piece)
	return piece

static func cloud_armchair(parent: Node3D, at: Transform3D) -> Node3D:
	var piece := Node3D.new()
	piece.name = "CloudArmchair"
	piece.transform = at
	var mesh := SHAPES.new()
	mesh.blob(SHAPES.place(Vector3(0, 0.2, -0.01)), Vector3(0.44, 0.2, 0.41), "cloud_fabric", 3.0, 10, 20)
	mesh.blob(SHAPES.place(Vector3(0, 0.37, 0.05)), Vector3(0.3, 0.1, 0.33), "cloud_fabric", 3.5, 10, 20)
	for x: float in [-0.18, 0.18]:
		mesh.blob(Transform3D(Basis(Vector3.RIGHT, -0.16), Vector3(x, 0.7, -0.31)), Vector3(0.25, 0.32, 0.16), "cloud_fabric", 2.4, 10, 18)
	mesh.blob(Transform3D(Basis(Vector3.RIGHT, -0.16), Vector3(0, 0.92, -0.34)), Vector3(0.2, 0.2, 0.14), "cloud_fabric", 2.2, 10, 18)
	for side: float in [-1.0, 1.0]:
		_scroll_arm(mesh, side * 0.44)
	_cloud_pillow(mesh, Vector3(-0.17, 0.56, -0.08), 0.9)
	if not TRIPO.add_visual(piece, "armchair"):
		mesh.commit(piece, "Visual")
	SHAPES.seating(piece, [Vector3(0, 0.42, 0.12)],
		[SHAPES.span(Vector3(0, 0.21, 0.05), Vector3(0.62, 0.42, 0.66)), SHAPES.span(Vector3(0, 0.15, -0.01), Vector3(1.16, 0.3, 0.82))],
		[SHAPES.span(Vector3(0, 0.74, -0.33), Vector3(1.0, 0.62, 0.28)), SHAPES.span(Vector3(-0.46, 0.52, 0.02), Vector3(0.28, 0.3, 0.74)),
			SHAPES.span(Vector3(0.46, 0.52, 0.02), Vector3(0.28, 0.3, 0.74))], false)
	parent.add_child(piece)
	return piece

## A rolled cloud arm: a soft block under a fat roll whose front end carries a swirl.
static func _scroll_arm(mesh: SHAPES, x: float) -> void:
	var side := signf(x)
	var roll := Vector3(x + side * 0.02, 0.52, 0.0)
	mesh.blob(SHAPES.place(Vector3(x, 0.24, 0.02)), Vector3(0.13, 0.24, 0.37), "cloud_fabric", 3.0, 10, 18)
	mesh.tube(PackedVector3Array([roll + Vector3(0, 0, -0.33), roll + Vector3(0, 0, 0.34)]), 0.15, "cloud_fabric", 16)
	mesh.swirl(roll + Vector3(0, 0, 0.34), 0.15, Basis.IDENTITY, "#e4e0fc", 1.7, 0.78, 0.011)

## White cloud pillow: a small cluster of puffs.
static func _cloud_pillow(mesh: SHAPES, at: Vector3, size: float) -> void:
	for puff: Vector4 in [Vector4(0, 0, 0, 0.13), Vector4(-0.1, -0.02, 0.03, 0.1), Vector4(0.1, -0.01, 0.02, 0.1), Vector4(0.01, 0.09, -0.01, 0.09)]:
		mesh.blob(SHAPES.place(at + Vector3(puff.x, puff.y, puff.z) * size), Vector3.ONE * puff.w * size, "cloud", 2.0, 8, 14)

## Round glass top on a brass stem with three curled tripod feet.
static func glass_table(parent: Node3D, label_text: String, at: Vector3, radius: float, height: float) -> Node3D:
	var piece := Node3D.new()
	piece.name = label_text
	piece.position = at
	var mesh := SHAPES.new()
	mesh.lathe(Transform3D.IDENTITY, PackedVector2Array([Vector2(0, height - 0.028), Vector2(radius, height - 0.028), Vector2(radius, height), Vector2(0, height)]), "glass", 40)
	mesh.torus(SHAPES.place(Vector3(0, height - 0.045, 0)), radius * 0.42, 0.014, "brass", 28, 6)
	mesh.lathe(Transform3D.IDENTITY, PackedVector2Array([Vector2(0.0, 0.16), Vector2(0.05, 0.17), Vector2(0.07, 0.24), Vector2(0.045, 0.32),
		Vector2(0.032, height * 0.62), Vector2(0.06, height * 0.7), Vector2(0.035, height * 0.78), Vector2(0.05, height - 0.05), Vector2(0.0, height - 0.035)]), "brass", 20, true)
	for leg in 3:
		var angle := TAU * float(leg) / 3.0
		var out := Vector3(sin(angle), 0.0, cos(angle))
		var points := PackedVector3Array()
		for step: Vector2 in [Vector2(0.03, 0.26), Vector2(0.11, 0.2), Vector2(0.2, 0.1), Vector2(0.27, 0.045), Vector2(0.32, 0.06), Vector2(0.34, 0.1)]:
			points.append(out * step.x + Vector3.UP * step.y)
		mesh.tube(points, 0.022, "brass", 8)
		mesh.blob(SHAPES.place(out * 0.27 + Vector3.UP * 0.025), Vector3(0.035, 0.025, 0.035), "brass")
		var spoke := TAU * (float(leg) + 0.5) / 3.0
		var toward := Vector3(sin(spoke), 0.0, cos(spoke))
		mesh.tube(PackedVector3Array([Vector3.UP * (height - 0.08) + toward * 0.03, Vector3.UP * (height - 0.045) + toward * radius * 0.42]), 0.01, "brass", 6)
	if not TRIPO.add_visual(piece, "glass_table", Vector3.ZERO, Vector3(radius / 0.34, height / 0.6, radius / 0.34)):
		mesh.commit(piece, "Visual")
	SHAPES.cylinder_shape(SHAPES.body(piece, "Solid"), radius, height, Vector3(0, height * 0.5, 0))
	parent.add_child(piece)
	return piece

## Purple bulb base, brass stem and a lit pale-green shade; one small shadowless light.
static func lamp(parent:Node3D,at:Vector3)->Node3D:
	var piece:=preload("res://world/props/lamps/lamp.gd").new()
	piece.name="GreenShadeLamp";piece.position=at
	var visual:=ROOM.add_visual(piece,"rd_lamp")
	var light:=OmniLight3D.new();light.name="LampLight";light.position=Vector3(0,.48,0)
	light.light_color=Color("ffefc8");light.light_energy=.6;light.omni_range=3.2;light.omni_attenuation=.8
	light.shadow_enabled=false;light.distance_fade_enabled=true;light.distance_fade_begin=25;light.distance_fade_length=10
	piece.add_child(light);piece.configure(visual,light);parent.add_child(piece);return piece

## following the round wall a little in front of the window trim.
static func curtains(parent: Node3D, window: Dictionary, wall_radius: float, floor_y: float) -> Node3D:
	var angle := float(window.get("angle", 0.0))
	var half := float(window.get("width", 1.3)) * 0.5
	var top := float(window.get("y", 2.0)) + float(window.get("height", 2.4)) * 0.5 + 0.24
	var bottom := floor_y + 0.1
	var tie := lerpf(bottom, top, 0.36)
	var reach := half + 0.5
	var hang := wall_radius - 0.15
	var piece := Node3D.new()
	piece.name = "LightningCurtains"
	piece.transform = SHAPES.facing_centre(hang, angle, 0.0)
	var mesh := SHAPES.new()
	var row_count := 16
	var columns := 9
	for side: float in [-1.0, 1.0]:
		var rows: Array[PackedVector3Array] = []
		for r in row_count:
			var y := lerpf(top - 0.03, bottom, float(r) / float(row_count - 1))
			var width := _drape_width(y, bottom, tie, top)
			var row := PackedVector3Array()
			for c in columns:
				var u := float(c) / float(columns - 1)
				var s := side * lerpf(reach, reach - width, u)
				var fold := 0.035 * sin(u * TAU * 2.0 + side) * (0.35 + 0.65 * clampf(absf(y - tie) / 1.2, 0.0, 1.0))
				row.append(_on_arc(hang, hang - fold, s, y))
			rows.append(row)
		mesh.sheet(rows, "fabric_lightning")
		# Yellow tie-back around the gathered drape.
		var loop := PackedVector3Array()
		for k in 17:
			var t := TAU * float(k) / 16.0
			loop.append(_on_arc(hang, hang - 0.01 + sin(t) * 0.07, side * (reach - 0.08) + cos(t) * 0.11, tie))
		mesh.tube(loop, 0.018, "#e5c84a", 6, PackedFloat32Array(), false)
	var rod := PackedVector3Array()
	for k in 11:
		rod.append(_on_arc(hang, hang + 0.02, lerpf(-reach - 0.1, reach + 0.1, float(k) / 10.0), top))
	mesh.tube(rod, 0.022, "brass", 8)
	for s: float in [-(reach + 0.1), reach + 0.1]:
		mesh.blob(SHAPES.place(_on_arc(hang, hang + 0.02, s + signf(s) * 0.05, top)), Vector3.ONE * 0.045, "brass")
		mesh.tube(PackedVector3Array([_on_arc(hang, hang + 0.02, s, top), _on_arc(hang, hang + 0.14, s, top)]), 0.012, "brass", 6)
	mesh.commit(piece, "Visual")
	parent.add_child(piece)
	return piece

## Drape width from its outer edge: wide under the rod, gathered at the tie, flared below.
static func _drape_width(y: float, bottom: float, tie: float, top: float) -> float:
	if y >= tie:
		return lerpf(0.16, 0.62, pow(clampf((y - tie) / maxf(top - tie, 0.01), 0.0, 1.0), 0.8))
	return lerpf(0.16, 0.4, pow(clampf((tie - y) / maxf(tie - bottom, 0.01), 0.0, 1.0), 0.9))

## Piece-local point at arc length `s` (positive: toward larger room angles) on a circle of
## `radius` about the room centre, for a piece standing at `origin_radius` facing the centre.
static func _on_arc(origin_radius: float, radius: float, s: float, y: float) -> Vector3:
	var delta := s / origin_radius
	return Vector3(-radius * sin(delta), y, origin_radius - radius * cos(delta))

## A flat oval rug with a pale border (visual only: feet sink a centimetre into it).
static func oval_rug(parent: Node3D, label_text: String, at: Transform3D, radii: Vector2) -> Node3D:
	var piece := Node3D.new()
	piece.name = label_text
	piece.transform = at
	var mesh := SHAPES.new()
	mesh.rug(Transform3D.IDENTITY, radii + Vector2(0.07, 0.07), 0.008, "#7fb6c4")
	mesh.rug(Transform3D.IDENTITY, radii, 0.014, "rug")
	mesh.commit(piece, "Visual")
	parent.add_child(piece)
	return piece
