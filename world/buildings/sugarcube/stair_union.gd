extends RefCounted
## Offline union of convex planar stair slabs. Buried end faces never enter the
## single collision mesh; exterior top, side and underside faces stay solid.
const CUT := preload("res://tools/buildings/split_door.gd")
var _slabs: Array[Dictionary] = []

func add(corners: Array[Vector3], depth: float) -> void:
	assert(corners.size() >= 3 and depth > 0)
	var center := Vector3.ZERO
	var bounds := AABB(corners[0],Vector3.ZERO)
	var bottom: Array[Vector3] = []
	for point in corners:
		center += point
		bottom.append(point-Vector3.UP*depth)
		bounds = bounds.expand(point).expand(point-Vector3.UP*depth)
	center = center/corners.size()-Vector3.UP*depth*.5
	var faces: Array = [corners.duplicate(),bottom]
	for i in corners.size():
		var j := (i+1)%corners.size()
		faces.append([corners[i],corners[j],bottom[j],bottom[i]])
	var planes: Array = []
	for face: Array in faces:
		var normal := _normal(face)
		assert(normal.length_squared() > .9,"Degenerate stair slab face")
		if normal.dot(center-face[0]) < 0: normal = -normal
		var distance := normal.dot(face[0])
		for point in corners:
			assert(normal.dot(point)-distance >= -.00001,"Stair slab must be convex with a planar top")
		# Godot's front-face winding is clockwise viewed from outside.
		if _normal(face).dot(normal) < 0: face.reverse()
		planes.append([normal,distance])
	_slabs.append({"faces":faces,"planes":planes,"bounds":bounds})

func commit(material: Material) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_material(material)
	var input_faces := 0
	var output_triangles := 0
	for index in _slabs.size():
		var slab: Dictionary = _slabs[index]
		for f in slab.faces.size():
			input_faces += 1
			var plane: Array = slab.planes[f]
			var polygon: Array = []
			for point: Vector3 in slab.faces[f]:
				polygon.append({"p":point,"n":-Vector3(plane[0]),"uv":Vector2.ZERO})
			var pieces: Array = [polygon]
			for other_index in _slabs.size():
				if other_index == index: continue
				var other: Dictionary = _slabs[other_index]
				# Grow only the broad phase so exactly touching slabs are considered.
				# Actual clipping planes and admitted geometry are never expanded.
				if not (slab.bounds as AABB).grow(.000001).intersects(other.bounds): continue
				# Coincident outward faces belong to the earlier slab. Without this
				# tie break two coplanar surfaces could both erase the same patch.
				if index < other_index and _same_plane(plane,other.planes): continue
				var remaining: Array = []
				for piece: Array in pieces:
					if CUT.outside_volume(piece,other.planes): remaining.append(piece); continue
					for cut: Array in other.planes:
						if piece.size() < 3: break
						var halves: Array = CUT.divide(piece,cut[0],cut[1])
						if halves[1].size() >= 3: remaining.append(halves[1])
						piece = halves[0]
				pieces = remaining
				if pieces.is_empty(): break
			for piece: Array in pieces: output_triangles += CUT.emit(surface,piece)
	surface.index()
	print("STAIR_UNION slabs=",_slabs.size()," input_faces=",input_faces," triangles=",output_triangles)
	return surface.commit()

static func _same_plane(plane: Array, others: Array) -> bool:
	for other: Array in others:
		if Vector3(plane[0]).dot(other[0]) > .999999 and absf(float(plane[1])-float(other[1])) < .000001: return true
	return false

static func _normal(face: Array) -> Vector3:
	for i in range(1,face.size()-1):
		var normal := (Vector3(face[i])-Vector3(face[0])).cross(Vector3(face[i+1])-Vector3(face[0]))
		if normal.length_squared() > .000000000001: return normal.normalized()
	return Vector3.ZERO
