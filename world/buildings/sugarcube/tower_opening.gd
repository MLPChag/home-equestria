extends RefCounted
## Offline cuts bounded by the original enclosing wall rims. Roof components only;
## source walls, window trim and tower posts remain byte-for-byte geometry.
const CUT := preload("res://tools/buildings/split_door.gd")
const SCALE := 14.0
const CREAM_RIM := [Vector2(-1.79112109,1.32457222), Vector2(-2.05808120,0.37707963), Vector2(-2.10749921,-0.52213916), Vector2(-2.00318799,-1.22881392), Vector2(-1.99985394,-1.22688331), Vector2(-1.54500014,-2.25439250), Vector2(-0.99388106,-2.75333510), Vector2(-0.43232263,-2.98374206), Vector2(0.12170087,-2.91992367), Vector2(0.69010788,-2.57395655), Vector2(1.11810643,-2.00150775), Vector2(1.50398695,-1.06773816), Vector2(1.55590843,-1.13113774), Vector2(1.63704402,-0.27774135), Vector2(1.52499915,0.63787700), Vector2(1.07490638,1.61010948), Vector2(0.45405022,2.25367106), Vector2(-0.19589648,2.48576741), Vector2(-0.72674644,2.41689491), Vector2(-1.26178476,2.07287190), Vector2(-1.76182067,1.38608625)]
const CUPCAKE_RIM := [Vector2(-1.06872112,-0.93186239), Vector2(-0.86185285,-1.41646507), Vector2(-0.55455793,-1.73784116), Vector2(-0.19579000,-1.84954304), Vector2(0.16297778,-1.73784120), Vector2(0.47027284,-1.41645516), Vector2(0.67714113,-0.93186231), Vector2(0.74999914,-0.35856998), Vector2(0.67714112,0.21473233), Vector2(0.47027284,0.69932516), Vector2(0.16297778,1.02071120), Vector2(-0.19579000,1.13241304), Vector2(-0.55455778,1.02071120), Vector2(-0.86185284,0.69932516), Vector2(-1.06872112,0.21473233), Vector2(-1.14157914,-0.35856998)]
## Original roof/icing component seeds in metre coordinates. Connectivity is
## discovered on the actual baked mesh, not inferred from normals or material.
const ROOF_SEEDS := [
	[Vector3(-8.72758825,8.01093726,-3.83420320), Vector3(-8.66084757,7.98319287,-3.76541462), Vector3(-8.98149171,9.73224611,-2.67639377)],
	[Vector3(8.01314509,8.31648707,3.77401915), Vector3(8.09831350,8.21118956,3.44004700), Vector3(7.94734321,7.66934147,4.15861874)],
	[Vector3(-2.60212374,11.74393234,-0.38157755), Vector3(-2.41829116,11.74393234,1.06494395), Vector3(-2.38931979,12.13423362,-0.38157902)],
]

const TOWER_SEEDS := [
	[Vector3(0.16359537,12.95158172,1.39467466), Vector3(-0.07655911,13.09045930,1.45268108), Vector3(0.16251460,12.94545989,1.46023439)], # 7950
	[Vector3(-0.58410748,12.92656183,1.45220804), Vector3(-0.33518302,13.06725359,1.51098661), Vector3(-0.60236878,12.94393592,1.45917052)], # 46
	[Vector3(0.15745501,9.68577957,-3.15553780), Vector3(-0.45087553,9.68577957,-3.22776432), Vector3(0.16277313,9.69214296,-3.19394574)], # 6004
	[Vector3(-0.23246599,13.32193761,1.61971865), Vector3(-0.20237052,13.32194328,1.62013932), Vector3(-0.23312728,13.59534297,1.73486438)], # 66
	[Vector3(0.91097163,10.69342146,2.43430316), Vector3(0.96469973,10.83082776,2.42612329), Vector3(0.98758682,10.67886024,2.57045853)], # 5263
	[Vector3(-2.71089889,11.21561518,0.15351414), Vector3(-2.55455409,11.34564075,0.36036157), Vector3(-2.58934661,11.33693304,-0.01089681)], # 3046
	[Vector3(-1.59832026,9.95775175,1.79378918), Vector3(-1.67809744,9.94027390,1.97224481), Vector3(-1.75068682,10.29432249,2.04823802)], # 8129
	[Vector3(-0.39753244,13.15595684,1.56451246), Vector3(-0.34484945,13.03369460,1.51258435), Vector3(-0.36291143,13.15595684,1.56451278)], # 606
	[Vector3(-1.68265420,9.18370147,-2.23700631), Vector3(-1.72071921,9.82980704,-2.29422684), Vector3(-1.50970032,8.98254209,-2.48175273)], # 946
	[Vector3(-0.21788890,13.59499927,1.68444239), Vector3(-0.21788773,13.58889122,1.74891679), Vector3(-0.42552670,13.53701053,1.65981402)], # 5403
	[Vector3(-0.85886011,8.63028336,2.44074368), Vector3(-0.89007552,9.82980866,2.60732024), Vector3(-0.79410731,8.63028336,2.08585889)], # 1240
	[Vector3(1.53619378,9.36128063,-1.36031835), Vector3(1.59646707,9.82980785,-1.41836758), Vector3(1.64803030,9.64500685,-1.04084988)], # 1636
	[Vector3(-2.60212374,11.74393234,-0.38157755), Vector3(-2.41829116,11.74393234,1.06494395), Vector3(-2.38931979,12.13423362,-0.38157902)], # 3838
	[Vector3(-0.29301255,16.50467520,-0.45756887), Vector3(-0.25891568,16.50467520,-0.43546296), Vector3(-0.29462618,16.38802652,-0.43576308)], # 3422
	[Vector3(-1.76587934,14.15642309,0.63625286), Vector3(-1.61080799,13.97735643,1.18307111), Vector3(-1.67033687,14.19416895,0.62971342)], # 4340
	[Vector3(1.41108879,9.74357619,0.51337904), Vector3(1.41906075,9.82980785,0.53020701), Vector3(1.62721143,9.73320751,0.64787380)], # 3868
	[Vector3(-0.72455757,16.13745480,-0.80349621), Vector3(-0.65836676,15.34757872,-0.72340261), Vector3(-0.80554273,16.13282776,-0.76943001)], # 3926
	[Vector3(-0.29698760,16.39299726,-0.65085722), Vector3(-0.29690137,15.36629925,-0.58807459), Vector3(-0.38309347,16.39299726,-0.61474519)], # 3960
	[Vector3(0.20965672,15.87293711,-0.76937229), Vector3(0.06449142,15.26629753,-0.68310161), Vector3(0.12921166,15.88124924,-0.73530604)], # 3992
	[Vector3(0.21627152,15.97216387,-0.56928733), Vector3(0.19573717,15.86891804,-0.57446877), Vector3(0.18958785,15.97491999,-0.53477953)], # 4056
	[Vector3(-0.73363997,16.23105907,-0.62319742), Vector3(-0.70147815,16.23095694,-0.60234421), Vector3(-0.71763662,16.12665730,-0.60262703)], # 4068
	[Vector3(-1.16174045,12.40513659,-0.35856636), Vector3(-1.08821213,12.40513659,0.22002091), Vector3(-1.54446651,13.98966494,-0.35855800)], # 4691
	[Vector3(-1.78583728,9.50278869,1.62617301), Vector3(-1.80782690,9.82980866,1.64991077), Vector3(-1.92558780,9.61734676,1.33481247)], # 5142
	[Vector3(0.65830823,8.18337545,-2.78943450), Vector3(0.53539951,8.23597922,-2.48038073), Vector3(0.73524043,9.82980704,-2.98288143)], # 6546
	[Vector3(-0.54403118,8.16782041,-3.09726799), Vector3(-0.55770738,9.82980704,-3.30868077), Vector3(-0.31220713,8.11574354,-3.12731709)], # 8337
	[Vector3(0.15151943,13.39301062,1.65032340), Vector3(-0.09052041,13.25404630,1.59032217), Vector3(0.16417324,13.37325654,1.64151599)], # 5477
	[Vector3(-0.20199702,12.72206268,1.29718999), Vector3(-0.20265828,12.99546804,1.41233561), Vector3(-0.20236986,12.71659584,1.36302888)], # 8239
	[Vector3(0.38783228,8.61605935,2.45574324), Vector3(0.60234150,8.72733035,2.31505494), Vector3(0.64616823,9.82980947,2.47876346)], # 8277
	[Vector3(-2.24168409,9.96082482,-0.38040089), Vector3(-2.45695978,10.86354046,-0.40655310), Vector3(-2.22368765,9.96082482,-0.74334773)], # 6297
	[Vector3(-0.58368161,13.39742122,1.58361869), Vector3(-0.58259962,13.39114213,1.64911233), Vector3(-0.34966350,13.25949774,1.52403588)], # 8243
	[Vector3(-1.64862568,9.97384343,1.96591694), Vector3(-1.09880794,9.97750340,2.56970022), Vector3(-1.70681232,10.43972478,2.10680158)], # 10523
	[Vector3(1.33160033,9.98578959,1.66900048), Vector3(1.40488243,10.48410153,1.80692589), Vector3(0.82702374,9.98213043,2.36284676)], # 10530
	[Vector3(-0.01024996,12.78735433,1.34141167), Vector3(0.14175260,12.94577603,1.40869789), Vector3(-0.21788866,12.72936883,1.31678385)], # cupcake glazing, separate material surface
]
const CREAM_BASE := [
	Vector3(0.12835000,8.03128000,-2.93929000),
	Vector3(0.70381000,8.28426000,-2.58903000),
	Vector3(1.13563000,8.69110000,-2.01147000),
	Vector3(1.50970000,9.30884000,-1.10628000),
	Vector3(1.57122000,9.64922000,-1.18140000),
	Vector3(1.65716000,9.72031000,-0.27747000),
	Vector3(1.52603000,9.70010000,0.79411000),
	Vector3(1.59098000,9.70949000,0.54296000),
	Vector3(1.09164000,9.11283000,1.62157000),
	Vector3(0.46519000,8.58759000,2.27093000),
	Vector3(-0.19370000,8.40249000,2.50622000),
	Vector3(-0.73378000,8.57295000,2.43615000),
	Vector3(-1.27575000,9.02610000,2.08767000),
	Vector3(-1.77908000,9.54569000,1.39636000),
	Vector3(-1.89203000,9.62717000,1.15923000),
	Vector3(-1.78845000,9.68578000,1.40780000),
	Vector3(-2.07793000,9.68578000,0.38038000),
	Vector3(-2.12758000,9.68578000,-0.52306000),
	Vector3(-2.01867000,9.68578000,-1.26089000),
	Vector3(-2.00912000,9.56554000,-1.25536000),
	Vector3(-1.56157000,9.06901000,-2.26637000),
	Vector3(-1.00471000,8.25487000,-2.77051000),
	Vector3(-0.43515000,7.99653000,-3.00420000),
]
const PIVOT := Vector2(-.19579,-.358565)
const LOWER := Vector2(1.3,1.32)
const UPPER := Vector2(2.1,2.2)

static func _root(parents: PackedInt32Array, index: int) -> int:
	while parents[index] != index:
		index = parents[index]
	return index

static func _volumes(rim: Array, low: float, high: float) -> Array:
	var result: Array = []
	for part: PackedVector2Array in Geometry2D.decompose_polygon_in_convex(PackedVector2Array(rim)):
		var center := Vector2.ZERO
		for point in part: center += point
		center /= part.size()
		var planes: Array = [[Vector3.UP, low / SCALE], [Vector3.DOWN, -high / SCALE]]
		for i in part.size():
			var a := part[i]
			var edge := part[(i + 1) % part.size()] - a
			var normal := Vector3(-edge.y, 0, edge.x).normalized()
			if normal.dot(Vector3(center.x-a.x, 0, center.y-a.y)) < 0: normal = -normal
			planes.append([normal, normal.dot(Vector3(a.x, 0, a.y)) / SCALE])
		result.append(planes)
	return result

static func apply(exterior: MeshInstance3D) -> bool:
	var surfaces: Array = []
	var matched := 0
	var tower_matched := 0
	var cream_surface := -1
	# Discover before changing anything: an unexpected source fails closed.
	for s in exterior.mesh.get_surface_count():
		var arrays := exterior.mesh.surface_get_arrays(s)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var ids: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if ids.is_empty():
			for i in vertices.size(): ids.append(i)
		var parents := PackedInt32Array()
		var first: Dictionary = {}
		var seeds := PackedInt32Array()
		var tower_seeds := PackedInt32Array()
		var cream_triangle := -1
		for t in ids.size() / 3:
			parents.append(t)
			for k in 3:
				var point := (vertices[ids[t*3+k]] * SCALE).snapped(Vector3.ONE * .00001)
				if first.has(point): parents[_root(parents, t)] = _root(parents, int(first[point]))
				else: first[point] = t
			for family in 2:
				var source_seeds: Array = ROOF_SEEDS if family == 0 else TOWER_SEEDS
				for seed: Array in source_seeds:
					var found := true
					for point: Vector3 in seed:
						var nearest := INF
						for k in 3: nearest = minf(nearest, point.distance_to(vertices[ids[t*3+k]] * SCALE))
						# Packed mesh positions are quantized (~0.33 mm measured); this
						# identifies source triangles only, never physical clearance.
						if nearest > .001: found = false; break
					if found:
						if family == 0: seeds.append(t); matched += 1
						else:
							tower_seeds.append(t); tower_matched += 1
							if seed == TOWER_SEEDS[2]: cream_surface = s; cream_triangle = t
		var allowed: Dictionary = {}
		for t in seeds: allowed[_root(parents, t)] = true
		var tower: Dictionary = {}
		for t in tower_seeds: tower[_root(parents, t)] = true
		surfaces.append({"arrays": arrays, "ids": ids, "parents": parents, "allowed": allowed, "tower": tower, "cream":_root(parents,cream_triangle) if cream_triangle >= 0 else -1})
	if matched != ROOF_SEEDS.size() or tower_matched != TOWER_SEEDS.size():
		push_error("Tower roof source changed: expected three roof component seeds, found %d; tower components %d/33" % [matched,tower_matched])
		return false
	var widened_rim: Array = []
	for point: Vector2 in CREAM_RIM: widened_rim.append(PIVOT + (point-PIVOT)*LOWER)
	var lower_volumes := _volumes(widened_rim, 5.60, 10.80)
	var upper := _volumes(CUPCAKE_RIM, 11.0, 12.68)
	if lower_volumes.is_empty() or upper.is_empty(): return false
	var skirt := _base_skirt(surfaces,cream_surface)
	if skirt.is_empty(): return false
	var result := ArrayMesh.new()
	var original_triangles := 0
	var untouched_triangles := 0
	var tower_retained := 0
	var roof_changed := 0
	var removed_area := 0.0
	for s in surfaces.size():
		var data: Dictionary = surfaces[s]
		var arrays: Array = data.arrays
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var ids: PackedInt32Array = data.ids
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		for t in ids.size() / 3:
			var polygon: Array = []
			for k in 3:
				var i := ids[t*3+k]
				polygon.append({"p": vertices[i], "n": normals[i], "uv": uvs[i]})
			original_triangles += 1
			var pieces: Array = [polygon]
			var is_tower: bool = data.tower.has(_root(data.parents,t))
			if data.allowed.has(_root(data.parents, t)):
				var volumes: Array = upper if is_tower else lower_volumes
				for planes: Array in volumes:
					var remaining: Array = []
					for piece: Array in pieces:
						if CUT.outside_volume(piece, planes): remaining.append(piece); continue
						for plane: Array in planes:
							if piece.size() < 3: break
							var halves: Array = CUT.divide(piece, plane[0], plane[1])
							if halves[1].size() >= 3: remaining.append(halves[1])
							piece = halves[0]
					pieces = remaining
			var original_area := _area(polygon)
			var retained_area := 0.0
			for piece: Array in pieces: retained_area += _area(piece)
			var lost := maxf(0,original_area-retained_area)
			if lost > .00000001:
				roof_changed += 1
				removed_area += lost*SCALE*SCALE
			elif is_tower: tower_retained += 1
			else: untouched_triangles += 1
			for piece: Array in pieces:
				if is_tower:
					piece = piece.duplicate(true)
					for vertex: Dictionary in piece: _deform(vertex)
				CUT.emit(surface, piece)
		if s == cream_surface:
			for panel: Array in skirt: CUT.emit(surface,panel)
		surface.set_material(exterior.mesh.surface_get_material(s))
		surface.generate_tangents()
		surface.index()
		surface.commit(result)
	print("TOWER_OPENING_AUDIT original=",original_triangles," untouched=",untouched_triangles," tower_retained=",tower_retained," roof_changed=",roof_changed," removed_m2=",removed_area," selected_components=",tower_matched," base_panels=",skirt.size())
	exterior.mesh = result
	for child in exterior.get_children():
		if child is StaticBody3D: child.free()
	exterior.create_trimesh_collision()
	return true

static func _deform(vertex: Dictionary) -> void:
	var p: Vector3 = vertex.p * SCALE
	var t := clampf((p.y-9.75)/(12.40514-9.75),0,1)
	var ease := t*t*(3-2*t)
	var scale_xz := LOWER.lerp(UPPER,ease)
	var derivative := (UPPER-LOWER)*(6*t*(1-t)/(12.40514-9.75))
	var offset := Vector2(p.x,p.z)-PIVOT
	# Inverse-transpose of x/z stretch varying with height, retaining source Y.
	var normal: Vector3 = vertex.n
	normal = Vector3(normal.x/scale_xz.x, normal.y-normal.x*offset.x*derivative.x/scale_xz.x-normal.z*offset.y*derivative.y/scale_xz.y, normal.z/scale_xz.y).normalized()
	var horizontal := PIVOT+offset*scale_xz
	vertex.p = Vector3(horizontal.x,p.y,horizontal.y)/SCALE
	vertex.n = normal

static func _area(poly: Array) -> float:
	var area := 0.0
	for i in range(1,poly.size()-1):
		area += (Vector3(poly[i].p)-Vector3(poly[0].p)).cross(Vector3(poly[i+1].p)-Vector3(poly[0].p)).length()*.5
	return area

static func _base_skirt(surfaces: Array, cream_surface: int) -> Array:
	if cream_surface < 0: return []
	var roof: Array = []
	for data: Dictionary in surfaces:
		var points: PackedVector3Array = data.arrays[Mesh.ARRAY_VERTEX]
		var ids: PackedInt32Array = data.ids
		for t in ids.size()/3:
			var component := _root(data.parents,t)
			if data.allowed.has(component) and not data.tower.has(component):
				roof.append([points[ids[t*3]]*SCALE,points[ids[t*3+1]]*SCALE,points[ids[t*3+2]]*SCALE])
	var arrays: Array = surfaces[cream_surface].arrays
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	# One cream texel from the largest original wall face avoids stretching
	# unrelated atlas seams down the newly exposed wall panels. Same material.
	var ids: PackedInt32Array = surfaces[cream_surface].ids
	var coat_uv := Vector2.ZERO
	var largest := 0.0
	for t in ids.size()/3:
		if _root(surfaces[cream_surface].parents,t) != int(surfaces[cream_surface].cream): continue
		var a := ids[t*3]
		var b := ids[t*3+1]
		var c := ids[t*3+2]
		var area := (vertices[b]-vertices[a]).cross(vertices[c]-vertices[a]).length_squared()
		if area > largest:
			largest = area
			coat_uv = (uvs[a]+uvs[b]+uvs[c])/3.0
	var upper: Array = []
	for original: Vector3 in CREAM_BASE:
		var closest := -1
		var distance := .001
		for i in vertices.size():
			var d := original.distance_to(vertices[i]*SCALE)
			if d < distance: distance = d; closest = i
		if closest < 0:
			push_error("Tower base source rim changed")
			return []
		var top: Dictionary = {"p":vertices[closest],"n":Vector3.UP,"uv":coat_uv}
		_deform(top)
		upper.append(top)
	var panels: Array = []
	for i in upper.size():
		var a: Dictionary = upper[i]
		var b: Dictionary = upper[(i+1)%upper.size()]
		var world_a: Vector3 = a.p*SCALE
		var world_b: Vector3 = b.p*SCALE
		var origin := Vector2(world_a.x,world_a.z)
		var delta := Vector2(world_b.x-world_a.x,world_b.z-world_a.z)
		if delta.length_squared() < .000001: continue
		# Split at every original roof triangle edge. Each interval has a fixed
		# set of covering roof planes, so its lower wall edge cannot bridge a dip.
		var cuts: Array[float] = [0.0,1.0]
		for triangle: Array in roof:
			for edge in 3:
				var p: Vector3 = triangle[edge]
				var q: Vector3 = triangle[(edge+1)%3]
				var line := Vector2(q.x-p.x,q.z-p.z)
				var offset := Vector2(p.x,p.z)-origin
				var determinant := delta.cross(line)
				if absf(determinant) < .000001: continue
				var t := offset.cross(line)/determinant
				var u := offset.cross(delta)/determinant
				if t > .00001 and t < .99999 and u >= 0 and u <= 1: cuts.append(t)
		cuts.sort()
		for j in range(cuts.size()-1):
			if cuts[j+1]-cuts[j] < .00001: continue
			var start: Dictionary = {"p":Vector3(a.p).lerp(b.p,cuts[j]),"n":Vector3.UP,"uv":Vector2(a.uv).lerp(b.uv,cuts[j])}
			var end: Dictionary = {"p":Vector3(a.p).lerp(b.p,cuts[j+1]),"n":Vector3.UP,"uv":Vector2(a.uv).lerp(b.uv,cuts[j+1])}
			var floor_y := _roof_floor(start.p*SCALE,end.p*SCALE,roof)
			if not is_finite(floor_y):
				push_error("Tower expanded base has no original roof underneath")
				return []
			var low_start: Dictionary = start.duplicate()
			var low_end: Dictionary = end.duplicate()
			low_start.p.y = minf(start.p.y,(floor_y-.005)/SCALE)
			low_end.p.y = minf(end.p.y,(floor_y-.005)/SCALE)
			var panel: Array = [start,end,low_end,low_start]
			if _area(panel) < .00000001: continue
			var normal := (Vector3(end.p)-Vector3(start.p)).cross(Vector3(low_start.p)-Vector3(start.p)).normalized()
			for vertex: Dictionary in panel: vertex.n = normal
			panels.append(panel)
	return panels

static func _roof_floor(start: Vector3, end: Vector3, roof: Array) -> float:
	var center := (start+end)*.5
	var floor_y := INF
	for triangle: Array in roof:
		var a: Vector3 = triangle[0]
		var b: Vector3 = triangle[1]
		var c: Vector3 = triangle[2]
		var ab := Vector2(b.x-a.x,b.z-a.z)
		var ac := Vector2(c.x-a.x,c.z-a.z)
		var determinant := ab.cross(ac)
		if absf(determinant) < .000001: continue
		var ap := Vector2(center.x-a.x,center.z-a.z)
		var u := ap.cross(ac)/determinant
		var v := ab.cross(ap)/determinant
		if u < -.00001 or v < -.00001 or u+v > 1.00001: continue
		# The minimum endpoint of any covering affine roof plane is a safe
		# lower bound throughout this interval, including overlapping icing.
		for point: Vector3 in [start,end]:
			ap = Vector2(point.x-a.x,point.z-a.z)
			u = ap.cross(ac)/determinant
			v = ab.cross(ap)/determinant
			floor_y = minf(floor_y,a.y+u*(b.y-a.y)+v*(c.y-a.y))
	return floor_y
