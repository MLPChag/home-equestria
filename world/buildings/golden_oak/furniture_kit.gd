extends RefCounted
## Golden Oak's authored placements reuse the household kit's dimensions and physical seats.
## The returned frame is in real metres. Set its transform BEFORE adding it to the world.

const FURNISHER := preload("res://world/interiors/interior_furnisher.gd")
const BED := preload("res://world/props/ponyville/pony_bed.scn")
const BOOKS := preload("res://world/books/shelf_books.gd")
const SEAT := preload("res://world/life/seat.gd")
var _stylist := FURNISHER.new()

func _init() -> void:
	FURNISHER.load_kit()
	_stylist.finish_name = "golden oak carved cherry"
	_stylist.finish = {"color": "b45253", "contrast": 0.5, "roughness": 0.85}
	_stylist.palette_name = "golden oak plum and linen"
	_stylist.palette = {"fabric": "994979", "linen": "f7e3be"}

func prop(id: String, at: Vector3, yaw: float = 0.0) -> Node3D:
	var frame := Node3D.new()
	frame.name = id.to_pascal_case()
	frame.transform = Transform3D(Basis(Vector3.UP, yaw), at)
	frame.set_meta("furniture", id)
	frame.add_to_group("house_furniture")
	var scene: PackedScene = FURNISHER._scene(id)
	if scene == null:
		return frame
	var model := scene.instantiate() as Node3D
	var box: AABB = FURNISHER._model_box(id, model)
	var size: Vector3 = FURNISHER._sizes.get(id, box.size)
	var k := maxf(size.x, maxf(size.y, size.z)) / maxf(box.size.x, maxf(box.size.y, box.size.z))
	model.transform = Transform3D(Basis.from_scale(Vector3.ONE * k), -Vector3(box.get_center().x, box.position.y, box.get_center().z) * k)
	var spec: Dictionary = FURNISHER._kit.props.get(id, {})
	var seating: Dictionary = spec.get("seating", {})
	if not seating.is_empty():
		FURNISHER._add_seating(model, seating, box, k, id == "sofa")
	elif bool(spec.get("collide", false)):
		# Keep collision in the unit-scale frame, independent of imported mesh scale.
		box_body(frame, "Solid", box.size * k, Vector3(0, box.size.y * k * 0.5, 0))
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null:
			continue
		for surface in mesh.mesh.get_surface_count():
			mesh.set_surface_override_material(surface, _stylist._material(id, mesh.mesh.surface_get_material(surface)))
		mesh.visibility_range_end = 60.0
	frame.add_child(model)
	return frame

func bed(at: Vector3, yaw: float, label_text: String, twilight: bool) -> Node3D:
	var result := BED.instantiate() as Node3D
	result.name = label_text
	result.transform = Transform3D(Basis(Vector3.UP, yaw), at)
	result.set_meta("bed_size", result.get_meta("size", Vector3(2.05, 1.1, 2.1)))
	result.set_meta("side_local", Vector3(1.55, 0, 0.15))
	_stylist.palette = {"fabric": "34566c" if twilight else "a97b9d", "linen": "f7e3be"}
	_stylist._dress_bed(result)
	_stylist.palette = {"fabric": "994979", "linen": "f7e3be"}
	return result

static func material(colour: String) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = Color(colour)
	result.roughness = 0.88
	return result

static func box_body(parent: Node3D, label_text: String, size: Vector3, at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = label_text
	body.position = at
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)
	return body

static func box(parent: Node3D, label_text: String, size: Vector3, at: Vector3, finish: Material, solid: bool = false) -> MeshInstance3D:
	var visual := MeshInstance3D.new()
	visual.name = label_text
	visual.position = at
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = finish
	visual.mesh = mesh
	parent.add_child(visual)
	if solid:
		box_body(parent, label_text + "Solid", size, at)
	return visual

static func tube(parent: Node3D, label_text: String, points: PackedVector3Array, radius: float, finish: Material, solid: bool = false) -> void:
	# Shared tangent frames at every joint avoid gaps between independent tube sections.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(finish)
	var rings: Array[PackedVector3Array] = []
	var normals: Array[PackedVector3Array] = []
	var previous_side := Vector3.ZERO
	for index in points.size():
		var tangent := (points[mini(index + 1, points.size() - 1)] - points[maxi(index - 1, 0)]).normalized()
		var side := previous_side - tangent * previous_side.dot(tangent)
		if side.length_squared() < 0.01:
			var reference := Vector3.UP if absf(tangent.y) < 0.95 else Vector3.RIGHT
			side = tangent.cross(reference)
		side = side.normalized()
		var other := tangent.cross(side).normalized()
		previous_side = side
		var ring_points := PackedVector3Array()
		var ring_normals := PackedVector3Array()
		for ring in 8:
			var angle := TAU * ring / 8.0
			var normal := side * cos(angle) + other * sin(angle)
			ring_points.append(points[index] + normal * radius)
			ring_normals.append(normal)
		rings.append(ring_points)
		normals.append(ring_normals)
	for index in points.size() - 1:
		for ring in 8:
			var next := (ring + 1) % 8
			for vertex: Vector2i in [Vector2i(index, ring), Vector2i(index + 1, ring), Vector2i(index + 1, next), Vector2i(index, ring), Vector2i(index + 1, next), Vector2i(index, next)]:
				st.set_normal(normals[vertex.x][vertex.y])
				st.add_vertex(rings[vertex.x][vertex.y])
	for end in [0, points.size() - 1]:
		var normal := (points[0] - points[1]).normalized() if end == 0 else (points[-1] - points[-2]).normalized()
		for ring in 8:
			var a := ring if end == 0 else (ring + 1) % 8
			var b := (ring + 1) % 8 if end == 0 else ring
			for point: Vector3 in [points[end], rings[end][a], rings[end][b]]:
				st.set_normal(normal)
				st.add_vertex(point)
	st.index()
	var visual := MeshInstance3D.new()
	visual.name = label_text
	visual.mesh = st.commit()
	parent.add_child(visual)
	if solid:
		visual.create_trimesh_collision()

static func disc(parent: Node3D, label_text: String, radius: float, height: float, at: Vector3, finish: Material, solid: bool = false) -> MeshInstance3D:
	var visual := MeshInstance3D.new()
	visual.name = label_text
	visual.position = at
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 40
	mesh.material = finish
	visual.mesh = mesh
	parent.add_child(visual)
	if solid:
		var body := StaticBody3D.new()
		body.position = at
		body.collision_layer = 1
		body.collision_mask = 0
		var collision := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = radius
		shape.height = height
		collision.shape = shape
		body.add_child(collision)
		parent.add_child(body)
	return visual

static func marker(parent: Node3D, label_text: String, at: Vector3, activity: String = "") -> Marker3D:
	var result := Marker3D.new()
	result.name = label_text
	result.position = at
	if not activity.is_empty():
		result.set_meta("activity", activity)
		result.add_to_group("house_activity_spots")
	parent.add_child(result)
	return result
