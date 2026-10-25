extends RefCounted
## Far tree meshes at about 1/20th of the near triangles (dev 2026-09-25: "apply the 1/20th far
## tree to our normal trees"). Used offline by tools/trees/build_far_trees.gd.
## - Leaf-card surfaces (the Grassy Fields billboard leaf shader) keep one card in 1/share,
##   with the cards enlarged so the crown stays about as full.
## - Every other surface (trunks, branches) is vertex-clustered on a grid that grows until it
##   fits `share` of its triangles.
## A 1/100th version was tried on the Everfree trees and dropped: too small and thin.

const LEAF_SHADER := "leaves.gdshader"
## Card size multiplier per 1/share cards: sqrt(1/share) would keep the exact coverage; the
## pack overlaps about 25 cards on any point, so 70 % of that still reads as a full crown.
const CARD_GROWTH := 0.7

## One mesh, in tree-root space, from `parts` ([mesh, transform] pairs of the near level).
static func build(parts: Array, share: float, seed := 1) -> ArrayMesh:
	var out := ArrayMesh.new()
	for part: Array in parts:
		var mesh: Mesh = part[0]
		var xform: Transform3D = part[1]
		for s in mesh.get_surface_count():
			var arrays := transformed(mesh.surface_get_arrays(s), xform)
			var material := mesh.surface_get_material(s)
			var leaf := material is ShaderMaterial and (material as ShaderMaterial).shader != null and (material as ShaderMaterial).shader.resource_path.ends_with(LEAF_SHADER)
			var reduced: Array
			if leaf:
				reduced = card_subset(arrays, share, seed + s)
				var bigger := (material as ShaderMaterial).duplicate() as ShaderMaterial
				bigger.set_shader_parameter("billboard_scale", float(bigger.get_shader_parameter("billboard_scale")) * CARD_GROWTH / sqrt(share))
				material = bigger
			else:
				var triangles := (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
				for k in [Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]: arrays[k] = null
				reduced = cluster_to(arrays, maxi(int(triangles * share), 12))
			if (reduced[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty(): continue
			# Card subsets keep the source's custom channels (Sakura leaves carry CUSTOM0),
			# which need their format bits; clustered surfaces drop them.
			var custom_bits := ((1 << (Mesh.ARRAY_FORMAT_CUSTOM_BITS * 4)) - 1) << Mesh.ARRAY_FORMAT_CUSTOM_BASE
			var flags: int = mesh.surface_get_format(s) & custom_bits if leaf else 0
			var before := out.get_surface_count()
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, reduced, [], {}, flags)
			if out.get_surface_count() == before:
				push_warning("far tree: surface %d of %s could not be rebuilt" % [s, mesh.resource_name]); continue
			out.surface_set_material(out.get_surface_count() - 1, material)
	# Enlarged cards reach past the vertex bounds; keep them from being culled early.
	out.custom_aabb = out.get_aabb().grow(2.0)
	return out

static func triangle_count(mesh: Mesh) -> int:
	var total := 0
	for s in mesh.get_surface_count(): total += mesh.surface_get_array_index_len(s) / 3
	return total

static func transformed(arrays: Array, xform: Transform3D) -> Array:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normal_basis := xform.basis.inverse().transposed()
	for i in v.size(): v[i] = xform * v[i]
	arrays[Mesh.ARRAY_VERTEX] = v
	if arrays[Mesh.ARRAY_NORMAL] != null:
		var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in n.size(): n[i] = (normal_basis * n[i]).normalized()
		arrays[Mesh.ARRAY_NORMAL] = n
	# Tangents would need the same rotation; the far level does without them.
	arrays[Mesh.ARRAY_TANGENT] = null
	if arrays[Mesh.ARRAY_INDEX] == null:
		var idx := PackedInt32Array(); idx.resize(v.size())
		for i in v.size(): idx[i] = i
		arrays[Mesh.ARRAY_INDEX] = idx
	return arrays

## Cards are quads: two consecutive triangles. Keep every (1/share)-th one, at a random offset.
static func card_subset(arrays: Array, share: float, seed: int) -> Array:
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var step := maxi(1, roundi(1.0 / share))
	var rng := RandomNumberGenerator.new(); rng.seed = seed
	var keep := PackedInt32Array()
	var quad := rng.randi_range(0, step - 1)
	while quad * 6 + 5 < idx.size():
		for k in 6: keep.append(idx[quad * 6 + k])
		quad += step
	var out := arrays.duplicate()
	out[Mesh.ARRAY_INDEX] = keep
	return out

## Vertex clustering on a grid that grows until the surface fits `target` triangles.
static func cluster_to(arrays: Array, target: int) -> Array:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var box := AABB(v[0], Vector3.ZERO)
	for p in v: box = box.expand(p)
	var cell := maxf(box.size.x, maxf(box.size.y, box.size.z)) / 40.0
	var out := cluster(arrays, cell)
	while (out[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3 > target and cell < 40.0:
		cell *= 1.15
		out = cluster(arrays, cell)
	return out

## Every vertex snaps to the average of its grid cell; collapsed or repeated triangles are
## dropped; normals are rebuilt from the kept faces; UVs are averaged per cell.
static func cluster(arrays: Array, cell: float) -> Array:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var cluster_of := PackedInt32Array(); cluster_of.resize(v.size())
	var keys := {}; var sums: Array[Vector3] = []; var uv_sums: Array[Vector2] = []; var uv2_sums: Array[Vector2] = []; var counts: Array[int] = []
	for i in v.size():
		var key := Vector3i(floori(v[i].x / cell), floori(v[i].y / cell), floori(v[i].z / cell))
		if not keys.has(key):
			keys[key] = sums.size(); sums.append(Vector3.ZERO); uv_sums.append(Vector2.ZERO); uv2_sums.append(Vector2.ZERO); counts.append(0)
		var c: int = keys[key]
		cluster_of[i] = c; sums[c] += v[i]; counts[c] += 1
		if not uv.is_empty(): uv_sums[c] += uv[i]
		if not uv2.is_empty(): uv2_sums[c] += uv2[i]
	var verts := PackedVector3Array(); var uvs := PackedVector2Array(); var uvs2 := PackedVector2Array()
	for c in sums.size():
		verts.append(sums[c] / counts[c]); uvs.append(uv_sums[c] / counts[c]); uvs2.append(uv2_sums[c] / counts[c])
	var normals := PackedVector3Array(); normals.resize(verts.size())
	var out_idx := PackedInt32Array(); var seen := {}
	for t in idx.size() / 3:
		var a := cluster_of[idx[t * 3]]; var b := cluster_of[idx[t * 3 + 1]]; var c := cluster_of[idx[t * 3 + 2]]
		if a == b or b == c or a == c: continue
		var sorted := [a, b, c]; sorted.sort()
		if seen.has(sorted): continue
		seen[sorted] = true
		out_idx.append_array([a, b, c])
		# Godot front faces are clockwise: (c - a) x (b - a) points out of the mesh.
		var face := (verts[c] - verts[a]).cross(verts[b] - verts[a])
		normals[a] += face; normals[b] += face; normals[c] += face
	for i in normals.size(): normals[i] = normals[i].normalized() if normals[i].length() > 0.0 else Vector3.UP
	var out := []; out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts; out[Mesh.ARRAY_NORMAL] = normals
	if not uv.is_empty(): out[Mesh.ARRAY_TEX_UV] = uvs
	if not uv2.is_empty(): out[Mesh.ARRAY_TEX_UV2] = uvs2
	out[Mesh.ARRAY_INDEX] = out_idx
	return out
