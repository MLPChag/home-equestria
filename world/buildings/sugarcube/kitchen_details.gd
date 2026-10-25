extends RefCounted
## Authored bakery tools and crockery: silhouettes carry detail at room distance.
const KIT := preload("res://world/buildings/golden_oak/furniture_kit.gd")
static func cylinder(parent: Node3D, label: String, at: Vector3, radius: float, height: float, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new(); mesh.top_radius = radius; mesh.bottom_radius = radius; mesh.height = height; mesh.radial_segments = 20; mesh.material = material
	var node := MeshInstance3D.new(); node.name = label; node.mesh = mesh; node.position = at; parent.add_child(node); return node
static func bowl(parent: Node3D, at: Vector3, radius: float, material: Material) -> void:
	# Open lathed profile, including the inside wall; never a solid painted disk.
	var profile := [Vector2(0, 0), Vector2(radius * 0.50, 0), Vector2(radius, radius * 0.75), Vector2(radius - 0.018, radius * 0.75), Vector2(radius * 0.43, 0.035), Vector2(0, 0.035)]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES); st.set_material(material)
	for ring in profile.size() - 1:
		for i in 24:
			var a := TAU * i / 24.0; var b := TAU * (i + 1) / 24.0
			var p: Vector2 = profile[ring]; var q: Vector2 = profile[ring + 1]
			var vertices := [Vector3(p.x * cos(a), p.y, p.x * sin(a)), Vector3(q.x * cos(a), q.y, q.x * sin(a)), Vector3(q.x * cos(b), q.y, q.x * sin(b)), Vector3(p.x * cos(b), p.y, p.x * sin(b))]
			for index in [0, 1, 2, 0, 2, 3]: st.add_vertex(vertices[index])
	st.generate_normals()
	var visual := MeshInstance3D.new(); visual.name = "OpenMixingBowl"; visual.mesh = st.commit(); visual.position = at; parent.add_child(visual)
static func build(room: Node3D) -> void:
	var mint := KIT.material("8fbfb0"); var pale := KIT.material("fff0d2"); var pink := KIT.material("e297b6")
	var metal := KIT.material("647b77"); var wood := KIT.material("b07849"); var dark := KIT.material("453e40")
	# Panelled cabinetry rather than an undifferentiated mint box.
	for x: float in [-5.40, -4.42, -3.43]:
		KIT.box(room, "RaisedCabinetPanel", Vector3(0.88, 0.64, 0.045), Vector3(x, 1.35, -2.99), pale)
		KIT.box(room, "MintPanelInset", Vector3(0.74, 0.48, 0.05), Vector3(x, 1.35, -2.96), mint)
		cylinder(room, "CabinetKnob", Vector3(x + 0.29, 1.55, -2.92), 0.035, 0.075, wood).rotation.x = PI * 0.5
	# A real shallow sink well, raised rim, and separate work surface.
	KIT.box(room, "SinkWellBottom", Vector3(0.66, 0.035, 0.44), Vector3(-4.55, 1.735, -3.41), metal)
	for x: float in [-4.90, -4.20]: KIT.box(room, "SinkSide", Vector3(0.035, 0.16, 0.50), Vector3(x, 1.815, -3.41), pale)
	for z: float in [-3.67, -3.15]: KIT.box(room, "SinkRim", Vector3(0.74, 0.055, 0.045), Vector3(-4.55, 1.89, z), pale)
	cylinder(room, "SinkDrain", Vector3(-4.55, 1.756, -3.41), 0.038, 0.006, dark)
	# Side-wall oven with visible glazed door, brass handle and four hob rings.
	var oven := Node3D.new(); oven.name = "BakeryOven"; oven.position = Vector3(-5.64, 0.9, -1.55); oven.rotation.y = PI * 0.5; room.add_child(oven)
	KIT.box(oven, "EnamelOven", Vector3(1.2, 0.91, 0.76), Vector3(0, 0.455, 0), pale, true)
	KIT.box(oven, "OvenWindow", Vector3(0.86, 0.45, 0.025), Vector3(0, 0.40, 0.391), dark)
	KIT.box(oven, "WarmOvenGlass", Vector3(0.73, 0.32, 0.028), Vector3(0, 0.40, 0.41), KIT.material("67544d"))
	KIT.tube(oven, "OvenHandle", PackedVector3Array([Vector3(-0.43, 0.69, 0.4), Vector3(-0.43, 0.69, 0.50), Vector3(0.43, 0.69, 0.50), Vector3(0.43, 0.69, 0.4)]), 0.032, wood)
	for x: float in [-0.37, 0, 0.37]: cylinder(oven, "OvenDial", Vector3(x, 0.82, 0.40), 0.045, 0.05, metal).rotation.x = PI * 0.5
	for x: float in [-0.30, 0.30]:
		for z: float in [-0.18, 0.18]:
			cylinder(oven, "HobRing", Vector3(x, 0.925, z), 0.12, 0.018, metal)
			cylinder(oven, "HobInset", Vector3(x, 0.936, z), 0.085, 0.012, dark)
	KIT.box(oven, "ApronHood", Vector3(1.30, 0.20, 0.9), Vector3(0, 2.1, 0), mint)
	KIT.box(oven, "HoodFlue", Vector3(0.48, 1.2, 0.40), Vector3(0, 2.78, -0.18), pale)
	# Open shelves have stacked plates, mixing bowls, lidded flour/cocoa jars.
	for y: float in [2.65, 3.30]:
		for x: float in [-5.24, -4.72]:
			for level in 4: cylinder(room, "StackedPlate", Vector3(x, y + 0.015 + level * 0.025, -3.59), 0.18, 0.025, pale)
		bowl(room, Vector3(-4.15, y + 0.01, -3.59), 0.19, pink)
		for x: float in [-3.68, -3.31]:
			cylinder(room, "BakingJar", Vector3(x, y + 0.17, -3.58), 0.12, 0.32, pale)
			cylinder(room, "JarLid", Vector3(x, y + 0.34, -3.58), 0.135, 0.05, mint)
			KIT.box(room, "JarLabel", Vector3(0.13, 0.10, 0.008), Vector3(x, y + 0.17, -3.455), pink)
	KIT.box(room, "WoodPreparationBoard", Vector3(0.68, 0.035, 0.47), Vector3(-3.48, 1.86, -3.40), wood)
	cylinder(room, "RollingPin", Vector3(-3.48, 1.94, -3.38), 0.065, 0.47, pale).rotation.z = PI * 0.5
	cylinder(room, "RollingPinHandles", Vector3(-3.48, 1.94, -3.38), 0.028, 0.68, wood).rotation.z = PI * 0.5
	bowl(room, Vector3(-5.40, 1.84, -3.43), 0.21, pink)
	KIT.tube(room, "WoodMixingSpoon", PackedVector3Array([Vector3(-5.39, 1.87, -3.43), Vector3(-5.20, 2.27, -3.41)]), 0.021, wood)
	# Trays and rack communicate working bakery storage at the side of the oven.
	for y: float in [1.13, 1.46, 1.79]:
		KIT.box(room, "BakingTray", Vector3(0.68, 0.025, 0.48), Vector3(-5.73, y, -0.44), metal)
		for z: float in [-0.69, -0.19]: KIT.box(room, "TrayLip", Vector3(0.70, 0.055, 0.018), Vector3(-5.73, y + 0.025, z), metal)
	for x: float in [-6.03, -5.43]: KIT.box(room, "TrayRackPost", Vector3(0.04, 1.0, 0.04), Vector3(x, 1.36, -0.65), wood)
