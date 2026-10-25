extends Node3D
## Seeded lunar landscape, in metres relative to the dream's landing point.
## One curved mesh owns both the crater shapes and collision; dust is a synchronous
## generated texture, so no worker or imported image can outlive a dream visit.
const RADIUS := 700.0
const DETAIL_RADIUS := 192.0
const RADIAL_STEP := 1.5
const SEGMENTS := 320
const DUST := preload("res://shaders/moon_regolith.gdshader")
var craters: Array[Vector4] = [] # x, z, radius, depth
var _noise := FastNoiseLite.new()
var _material: ShaderMaterial
var _built := false

func _init() -> void:
	_noise.seed = 1969
	_noise.frequency = 0.045
	_noise.fractal_octaves = 3
	craters.assign([
		Vector4(15, -20, 8, 2.0), Vector4(-27, -42, 16, 3.6),
		Vector4(57, -103, 34, 7.0), Vector4(-69, 34, 23, 5.0),
		Vector4(34, 26, 10, 2.4), Vector4(-16, 15, 5, 1.1),
	])
	var rng := RandomNumberGenerator.new(); rng.seed = 1969
	for i in 26:
		var angle := rng.randf() * TAU
		var distance := rng.randf_range(55, 178)
		var radius := rng.randf_range(3.0, 13.0)
		craters.append(Vector4(cos(angle) * distance, sin(angle) * distance, radius, radius * rng.randf_range(0.15, 0.25)))

## Continuous surface height used for player/pony placement and physical props.
func height_at(point: Vector2) -> float:
	var curved := sqrt(maxf(1.0, RADIUS * RADIUS - point.length_squared())) - RADIUS
	var detail := smoothstep(5.0, 11.0, point.length()) * (1.0 - smoothstep(176.0, DETAIL_RADIUS, point.length()))
	if detail <= 0.0: return curved
	var relief := _noise.get_noise_2d(point.x, point.y) * 0.38
	for crater: Vector4 in craters:
		var offset := point - Vector2(crater.x, crater.y)
		if offset.length_squared() > crater.z * crater.z * 1.8: continue
		var angle := atan2(offset.y, offset.x)
		var radial := offset.length() / (crater.z * (1.0 + 0.035 * sin(angle * 5.0 + crater.x)))
		if radial < 1.0:
			var bowl := 1.0 - radial * radial
			relief -= crater.w * bowl * bowl
		var rim := (radial - 1.01) / 0.16
		relief += crater.w * 0.27 * exp(-rim * rim)
	return curved + relief * detail

func build() -> void:
	if _built: return
	_built = true
	_material = ShaderMaterial.new(); _material.shader = DUST
	var image := _noise.get_seamless_image(512, 512)
	image.generate_mipmaps()
	_material.set_shader_parameter("dust_map", ImageTexture.create_from_image(image))
	var mesh := _terrain_mesh()
	var ground := StaticBody3D.new(); ground.name = "MoonGround"; add_child(ground)
	var surface := MeshInstance3D.new(); surface.name = "CrateredRegolith"; surface.mesh = mesh
	ground.add_child(surface)
	var collision := CollisionShape3D.new(); collision.shape = mesh.create_trimesh_shape()
	ground.add_child(collision)
	_add_rocks()

func _terrain_mesh() -> ArrayMesh:
	var rings := PackedFloat32Array()
	for i in range(1, int(DETAIL_RADIUS / RADIAL_STEP) + 1): rings.append(i * RADIAL_STEP)
	# The same surface continues into the horizon, with progressively cheaper rings.
	for radius: float in [208.0, 232.0, 264.0, 304.0, 352.0, 408.0, 472.0, 544.0, 620.0, 680.0, 699.0]: rings.append(radius)
	var vertices := PackedVector3Array(); vertices.resize(1 + rings.size() * SEGMENTS)
	vertices[0] = Vector3.ZERO
	for ring in rings.size():
		var radius := rings[ring]
		for j in SEGMENTS:
			var angle := float(j) * TAU / SEGMENTS
			var point := Vector2(cos(angle), sin(angle)) * radius
			vertices[1 + ring * SEGMENTS + j] = Vector3(point.x, height_at(point), point.y)
	var indices := PackedInt32Array()
	for j in SEGMENTS:
		indices.append_array(PackedInt32Array([0, 1 + j, 1 + (j + 1) % SEGMENTS]))
	for ring in range(1, rings.size()):
		for j in SEGMENTS:
			var a := 1 + (ring - 1) * SEGMENTS + j
			var b := 1 + (ring - 1) * SEGMENTS + (j + 1) % SEGMENTS
			var c := 1 + ring * SEGMENTS + j
			var d := 1 + ring * SEGMENTS + (j + 1) % SEGMENTS
			indices.append_array(PackedInt32Array([a, c, b, b, c, d]))
	var arrays: Array = []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices; arrays[Mesh.ARRAY_INDEX] = indices
	var raw := ArrayMesh.new(); raw.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var tool := SurfaceTool.new(); tool.create_from(raw, 0); tool.generate_normals()
	var mesh := tool.commit(); mesh.surface_set_material(0, _material)
	return mesh

func _rock_mesh(variant: int) -> ArrayMesh:
	var base := SphereMesh.new(); base.radial_segments = 7; base.rings = 3; base.radius = 1.0; base.height = 2.0
	var arrays := base.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in vertices.size():
		var at := vertices[i]
		var shape := 0.85 + _noise.get_noise_3d(at.x * 20 + variant * 40, at.y * 20, at.z * 20) * 0.28
		vertices[i] = at * Vector3(shape, shape * 0.7, shape * 0.87)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var raw := ArrayMesh.new(); raw.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var tool := SurfaceTool.new(); tool.create_from(raw, 0); tool.deindex(); tool.set_smooth_group(-1); tool.generate_normals()
	var mesh := tool.commit(); mesh.surface_set_material(0, _material)
	return mesh

func _add_rocks() -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 1972
	for variant in 4:
		var mesh := _rock_mesh(variant)
		var multi := MultiMesh.new(); multi.transform_format = MultiMesh.TRANSFORM_3D; multi.mesh = mesh; multi.instance_count = 105
		for i in multi.instance_count:
			var angle := rng.randf() * TAU
			var distance := rng.randf_range(7.0, 152.0)
			var point := Vector2(cos(angle), sin(angle)) * distance
			var size := rng.randf_range(0.05, 0.22) if i > 13 else rng.randf_range(0.4, 1.2)
			var basis := Basis.from_euler(Vector3(rng.randf_range(-0.25, 0.25), rng.randf() * TAU, rng.randf_range(-0.25, 0.25))).scaled(Vector3.ONE * size)
			var at := Vector3(point.x, height_at(point) + size * 0.24, point.y)
			multi.set_instance_transform(i, Transform3D(basis, at))
			if i <= 13:
				var rock := StaticBody3D.new(); rock.transform = Transform3D(basis, at)
				var shape := CollisionShape3D.new(); shape.shape = mesh.create_convex_shape()
				rock.add_child(shape); add_child(rock)
		var scatter := MultiMeshInstance3D.new(); scatter.name = "BasaltRocks%d" % variant; scatter.multimesh = multi
		add_child(scatter)
