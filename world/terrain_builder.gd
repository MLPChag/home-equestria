extends RefCounted
## Builds terrain geometry from the files tools/extract_terrain.py emits.
##
## Unity Terrain is a heightmap component, not mesh geometry, so it is missing
## from the zone GLB entirely (see TECH.md). This rebuilds it.
##
## Placement is config, not derived from Unity's transform chain: the chain
## survives extraction badly and disagreed with the actual building geometry by
## ~108 m. tools/fit_terrain.gd measures the correct offset against the zone's
## own buildings, and the result is stored in the zone's zone.json.

## Two facts fix the placement, both verified against Ponyville's GLB rather than
## assumed:
##
## 1. AssetRipper's Unity->GLTF handedness conversion negates **X**, not Z. The
##    Terrain_Main node is at x=+466.81 in the GLB and x=-466.81 in the Unity
##    scene, with Y and Z untouched. So the terrain grows along -X and +Z from
##    its origin corner.
## 2. Unity Terrain ignores its transform's scale -- TerrainData.size is
##    authoritative. Ponyville's node carries scale 0.749, and applying it is what
##    put the ground ~108 m out. Only the position is used.
const SIGN_X := -1.0
const SIGN_Z := 1.0


static func load_meta(meta_path: String) -> Dictionary:
	if not FileAccess.file_exists(meta_path):
		push_error("[terrain] missing %s" % meta_path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## Normalised 0..1 heights as a square grid, row-major [z][x].
static func load_heights(dir_path: String, meta: Dictionary) -> PackedFloat32Array:
	var path := dir_path.path_join(str(meta.get("heights_file", "")))
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[terrain] cannot open %s" % path)
		return PackedFloat32Array()
	var res := int(meta.get("resolution", 0))
	var bytes := f.get_buffer(res * res * 4)
	return bytes.to_float32_array()


## cfg keys: origin (Vector3), scale (float, uniform XZ+height), y_offset (float),
## render_resolution (int), collision (bool).
static func build(dir_path: String, meta: Dictionary, cfg: Dictionary) -> MeshInstance3D:
	var res := int(meta.get("resolution", 0))
	var heights := load_heights(dir_path, meta)
	if res <= 1 or heights.size() != res * res:
		push_error("[terrain] bad height data")
		return null

	var origin := _to_vec3(cfg.get("origin", [0, 0, 0]))
	var y_offset: float = float(cfg.get("y_offset", 0.0))
	var size_x: float = float(meta.get("size_x", 0.0))
	var size_z: float = float(meta.get("size_z", 0.0))
	var height_scale: float = float(meta.get("height_scale", 0.0))

	# Render grid is decimated from the source heightmap: 1025^2 would be 2.1 M
	# triangles for ground alone, which the 3060 floor cannot afford in stereo.
	var n: int = clampi(int(cfg.get("render_resolution", 257)), 2, res)

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(n * n)
	uvs.resize(n * n)

	for j in n:
		for i in n:
			var u := float(i) / float(n - 1)
			var v := float(j) / float(n - 1)
			var h := sample_norm(heights, res, u, v)
			var idx := j * n + i
			verts[idx] = Vector3(
				origin.x + SIGN_X * u * size_x,
				origin.y + h * height_scale + y_offset,
				origin.z + SIGN_Z * v * size_z)
			uvs[idx] = Vector2(u, v)

	var indices := PackedInt32Array()
	indices.resize((n - 1) * (n - 1) * 6)
	var k := 0
	for j in n - 1:
		for i in n - 1:
			var a := j * n + i
			var b := j * n + i + 1
			var c := (j + 1) * n + i
			var d := (j + 1) * n + i + 1
			# An odd number of axis mirrors reverses handedness. With SIGN_X=-1 and
			# SIGN_Z=+1 the (a,b,c) winding is the one whose normals point up;
			# getting this backwards leaves the ground lit from below and reading
			# as near-black at noon.
			if SIGN_X * SIGN_Z < 0.0:
				indices[k] = a; indices[k + 1] = b; indices[k + 2] = c
				indices[k + 3] = b; indices[k + 4] = d; indices[k + 5] = c
			else:
				indices[k] = a; indices[k + 1] = c; indices[k + 2] = b
				indices[k + 3] = b; indices[k + 4] = c; indices[k + 5] = d
			k += 6

	var normals := _normals(verts, indices)

	# Ground must face up. Rather than reason about how many axis mirrors the
	# handedness conversion introduced, measure the result and correct it: a
	# downward-facing terrain is invisible under cull_back *and* untouchable by
	# one-sided concave collision, which reads as "the ground isn't there".
	var mean_up := 0.0
	for nrm in normals:
		mean_up += nrm.y
	if mean_up < 0.0:
		_reverse_winding(indices)
		for idx in normals.size():
			normals[idx] = -normals[idx]

	# Normals now point up, and the winding is counter-clockwise seen from above.
	# Godot treats *clockwise* as front-facing, so one more reversal is needed or
	# the whole surface is back-facing: invisible under cull_back and lit from
	# underneath. The normal attribute is left alone -- it is already correct.
	_reverse_winding(indices)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	arrays[Mesh.ARRAY_NORMAL] = normals

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.name = "Terrain_%s" % str(meta.get("name", "unnamed"))
	mi.mesh = mesh

	mi.material_override = _make_material(dir_path, meta)

	if bool(cfg.get("collision", true)):
		# Built explicitly instead of via create_trimesh_collision() so
		# backface_collision can be enabled -- terrain is the one surface where
		# a player must never fall through because of a winding mistake.
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(mesh.get_faces())
		shape.backface_collision = true
		var collider := CollisionShape3D.new()
		collider.shape = shape
		var body := StaticBody3D.new()
		body.name = "%s_col" % mi.name
		body.add_child(collider)
		mi.add_child(body)

	# Keep the original source mesh/collision for navigation and probes. Render
	# exact subsets so camera and shadow frusta can cull unseen terrain cells.
	var chunk_cells := int(cfg.get("render_chunk_cells", 0))
	var args := preload("res://world/dev_tools.gd").user_args()
	var chunk_arg := args.find("--terrain-chunk-cells")
	if chunk_arg >= 0 and chunk_arg + 1 < args.size():
		chunk_cells = int(args[chunk_arg + 1])
	if chunk_cells > 0 and chunk_cells < n - 1:
		_add_render_chunks(mi, arrays, n, chunk_cells)

	return mi


static func _add_render_chunks(source: MeshInstance3D, arrays: Array, n: int, cells: int) -> void:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var render_layers := source.layers
	# Visibility is inherited; layers are not. Zero layers suppress this one
	# renderer while its exact geometry remains available to existing consumers.
	source.layers = 0
	for z in range(0, n - 1, cells):
		for x in range(0, n - 1, cells):
			var width := mini(cells, n - 1 - x) + 1
			var depth := mini(cells, n - 1 - z) + 1
			var chunk_vertices := PackedVector3Array()
			var chunk_normals := PackedVector3Array()
			var chunk_uvs := PackedVector2Array()
			chunk_vertices.resize(width * depth)
			chunk_normals.resize(width * depth)
			chunk_uvs.resize(width * depth)
			for row in depth:
				for column in width:
					var index := row * width + column
					var original := (z + row) * n + x + column
					chunk_vertices[index] = vertices[original]
					# Reuse the global normal field at edges; recalculating normals
					# per chunk would leave visible lighting seams.
					chunk_normals[index] = normals[original]
					chunk_uvs[index] = uvs[original]
			var chunk_indices := PackedInt32Array()
			chunk_indices.resize((width - 1) * (depth - 1) * 6)
			for row in depth - 1:
				for column in width - 1:
					var original := ((z + row) * (n - 1) + x + column) * 6
					var index := (row * (width - 1) + column) * 6
					for corner in 6:
						var vertex := indices[original + corner]
						chunk_indices[index + corner] = (vertex / n - z) * width + vertex % n - x
			var chunk_arrays := []
			chunk_arrays.resize(Mesh.ARRAY_MAX)
			chunk_arrays[Mesh.ARRAY_VERTEX] = chunk_vertices
			chunk_arrays[Mesh.ARRAY_NORMAL] = chunk_normals
			chunk_arrays[Mesh.ARRAY_TEX_UV] = chunk_uvs
			chunk_arrays[Mesh.ARRAY_INDEX] = chunk_indices
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, chunk_arrays)
			var chunk := MeshInstance3D.new()
			chunk.name = "Render_%d_%d" % [x, z]
			chunk.mesh = mesh
			chunk.material_override = source.material_override
			chunk.layers = render_layers
			chunk.cast_shadow = source.cast_shadow
			chunk.set_meta("terrain_render_chunk", true)
			source.add_child(chunk)


## Splat material from the four highest-coverage layers, falling back to flat
## green if the extractor did not resolve textures (flat green makes a broken
## placement obvious, where white would hide it).
static func _make_material(dir_path: String, meta: Dictionary) -> Material:
	var layers: Array = meta.get("layers", [])
	var alphamaps: Array = meta.get("alphamaps", [])
	# A layer's weight lives in a fixed packed channel (layer index N ->
	# alphamap N/4, component N%4). The shader is told which channel each
	# sampled layer reads, so picking the four by coverage is safe.
	var usable: Array = []
	for l in layers:
		if l.get("texture", null) != null:
			usable.append(l)
	usable.sort_custom(func(a, b): return float(a["coverage"]) > float(b["coverage"]))
	usable = usable.slice(0, 6)

	print("[terrain] '%s' layers=%d usable=%d alphamaps=%d" % [
		meta.get("name", "?"), layers.size(), usable.size(), alphamaps.size()])

	if usable.size() < 4 or alphamaps.size() < 2:
		var fallback := StandardMaterial3D.new()
		fallback.albedo_color = Color(0.33, 0.45, 0.22)
		fallback.roughness = 1.0
		fallback.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		return fallback

	var shader: Shader = load("res://shaders/terrain_splat.gdshader")
	var mat := ShaderMaterial.new()
	mat.shader = shader

	if shader == null:
		push_error("[terrain] shader failed to load")

	for a in 2:
		mat.set_shader_parameter(
			"splat%d" % a, load(dir_path.path_join(str(alphamaps[a]["file"]))))

	var tiles := Vector4(50.0, 5.0, 60.0, 5.0)
	var tiles_extra := Vector2(5.0, 3.0)
	# One-hot columns: mask[channel][slot] = 1. Column j of the matrix is the set
	# of sampled layers that read packed channel j. The "b" pair carries slots
	# 4 and 5, which the shader reads as .xy.
	var m0 := _zero_mask()
	var m1 := _zero_mask()
	var m0b := _zero_mask()
	var m1b := _zero_mask()

	for i in usable.size():
		var l: Dictionary = usable[i]
		mat.set_shader_parameter(
			"layer%d" % i, load(dir_path.path_join(str(l["texture"]))))
		var t: Array = l.get("tile_size", [10.0, 10.0])
		var tile: float = maxf(0.5, float(t[0]))
		var channel: int = int(l.get("index", i))
		var slot := i if i < 4 else i - 4
		if i < 4:
			tiles[i] = tile
			if channel < 4:
				m0[channel][slot] = 1.0
			else:
				m1[channel - 4][slot] = 1.0
		else:
			tiles_extra[slot] = tile
			if channel < 4:
				m0b[channel][slot] = 1.0
			else:
				m1b[channel - 4][slot] = 1.0
		print("[terrain]   layer%d <- %s  channel=%d tile=%.0fm cov=%.3f" % [
			i, l["texture"], channel, tile, float(l.get("coverage", 0.0))])

	mat.set_shader_parameter("tile_size", tiles)
	mat.set_shader_parameter("tile_size_extra", tiles_extra)
	mat.set_shader_parameter("use_extra_layers", usable.size() > 4)
	mat.set_shader_parameter("splat_mask0", _as_projection(m0))
	mat.set_shader_parameter("splat_mask1", _as_projection(m1))
	mat.set_shader_parameter("splat_mask0b", _as_projection(m0b))
	mat.set_shader_parameter("splat_mask1b", _as_projection(m1b))
	var dbg := int(OS.get_environment("HE_TERRAIN_DEBUG"))
	mat.set_shader_parameter("debug_view", dbg)
	print("[terrain]   masks m0=%s m1=%s debug_view=%d" % [m0, m1, dbg])
	return mat


static func _zero_mask() -> Array:
	return [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0],
		[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]


static func _as_projection(cols: Array) -> Projection:
	return Projection(
		Vector4(cols[0][0], cols[0][1], cols[0][2], cols[0][3]),
		Vector4(cols[1][0], cols[1][1], cols[1][2], cols[1][3]),
		Vector4(cols[2][0], cols[2][1], cols[2][2], cols[2][3]),
		Vector4(cols[3][0], cols[3][1], cols[3][2], cols[3][3]))


static func _reverse_winding(indices: PackedInt32Array) -> void:
	for t in range(0, indices.size(), 3):
		var tmp := indices[t + 1]
		indices[t + 1] = indices[t + 2]
		indices[t + 2] = tmp


static func _to_vec3(a: Variant) -> Vector3:
	if a is Vector3:
		return a
	if typeof(a) == TYPE_ARRAY and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


## Bilinear sample of the source heightmap. Decimating by nearest-neighbour
## would alias the riverbanks into visible stair-stepping.
static func sample_norm(heights: PackedFloat32Array, res: int, u: float, v: float) -> float:
	var fx: float = clampf(u, 0.0, 1.0) * float(res - 1)
	var fz: float = clampf(v, 0.0, 1.0) * float(res - 1)
	var x0 := int(fx)
	var z0 := int(fz)
	var x1: int = mini(x0 + 1, res - 1)
	var z1: int = mini(z0 + 1, res - 1)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var h00 := heights[z0 * res + x0]
	var h10 := heights[z0 * res + x1]
	var h01 := heights[z1 * res + x0]
	var h11 := heights[z1 * res + x1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


static func _normals(verts: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	var i := 0
	while i < indices.size():
		var ia := indices[i]
		var ib := indices[i + 1]
		var ic := indices[i + 2]
		# Unnormalised cross product weights each face by its area, which is the
		# cheap way to get a smooth field without a separate accumulation pass.
		var face := (verts[ib] - verts[ia]).cross(verts[ic] - verts[ia])
		normals[ia] += face
		normals[ib] += face
		normals[ic] += face
		i += 3
	for idx in normals.size():
		normals[idx] = normals[idx].normalized()
	return normals
