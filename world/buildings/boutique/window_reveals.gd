extends RefCounted
## Interior linings follow the original glass contours; no source artwork is replaced.
const STAIR := preload("res://world/buildings/cloudominium/architecture_stair.gd")
const CENTERS := [45.0,90.0,135.0,225.0,270.0,315.0]
static func measure(mesh: Mesh, source_to_room: Transform3D) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var vertices: PackedVector3Array = mesh.surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
	for degrees: float in CENTERS:
		var points: Array[Vector3] = []
		var center := Vector3.ZERO
		for vertex: Vector3 in vertices:
			var point := source_to_room*vertex
			var angle := wrapf(rad_to_deg(atan2(point.x,point.z))-degrees,-180,180)
			if absf(angle)>20 or point.y<.6 or point.y>4.1: continue
			if not points.has(point): points.append(point); center += point
		assert(points.size()==12, "Remeasure the boutique's original oval glass")
		center /= points.size()
		var projected := PackedVector2Array()
		for point: Vector3 in points:
			# Overlap the original glass by a narrow border, closing the reveal at oblique views.
			point = center+(point-center)*.97
			projected.append(Vector2(wrapf(atan2(point.x,point.z)-deg_to_rad(degrees),-PI,PI),point.y))
		var order := Geometry2D.convex_hull(projected)
		order.resize(order.size()-1)
		var boundary: Array[Vector3] = []
		for point: Vector2 in order: boundary.append(center+(points[projected.find(point)]-center)*.97)
		result.append({"degrees":degrees,"outline":order,"glass":boundary})
	return result

static func build(mesh: RefCounted, radius: float, windows: Array) -> void:
	for window: Dictionary in windows:
		var polygon: PackedVector2Array = window.outline
		var center := Vector2.ZERO
		for point: Vector2 in polygon: center += point
		center /= polygon.size()
		# Overlap the segmented lining edges by 1 cm, avoiding cracks between chord grids.
		var half_width := deg_to_rad(15.15)
		var corners := PackedVector2Array([Vector2(-half_width,.69),Vector2(half_width,.69),Vector2(half_width,4.06),Vector2(-half_width,4.06)])
		var angles: Array[float] = []
		for point: Vector2 in polygon: angles.append((point-center).angle())
		for point: Vector2 in corners: angles.append((point-center).angle())
		for column in range(-6,7):
			for y: float in [.69,4.06]: angles.append((Vector2(deg_to_rad(column*2.5),y)-center).angle())
		angles.sort()
		var inner: Array[Vector3] = []; var outer: Array[Vector3] = []; var glass: Array[Vector3] = []
		for angle: float in angles:
			var direction := Vector2.from_angle(angle)
			var end := center+direction*10
			for n in polygon.size():
				var crossing: Variant = Geometry2D.segment_intersects_segment(center,end,polygon[n],polygon[(n+1)%polygon.size()])
				if crossing == null: continue
				var point: Vector2 = crossing
				var t := polygon[n].distance_to(point)/polygon[n].distance_to(polygon[(n+1)%polygon.size()])
				inner.append(STAIR.polar(radius,deg_to_rad(window.degrees)+point.x,point.y))
				glass.append(Vector3(window.glass[n]).lerp(window.glass[(n+1)%polygon.size()],t))
				break
			for n in corners.size():
				var crossing: Variant = Geometry2D.segment_intersects_segment(center,end,corners[n],corners[(n+1)%corners.size()])
				if crossing == null: continue
				var point: Vector2 = crossing
				outer.append(STAIR.polar(radius,deg_to_rad(window.degrees)+point.x,point.y))
				break
		assert(inner.size()==angles.size() and outer.size()==angles.size())
		for n in inner.size():
			var next := (n+1)%inner.size()
			var normal := -STAIR.outward(deg_to_rad(window.degrees))
			mesh.quad("wall",outer[n],outer[next],inner[next],inner[n],normal)
			# Jambs face the opening, not the room's radial normal. The oval's tapered
			# depth can otherwise turn an oblique jamb away and expose a daylight sliver.
			var opening := STAIR.polar(radius,deg_to_rad(window.degrees)+center.x,center.y)
			var reveal_normal := opening-(inner[n]+inner[next])*.5
			mesh.quad("cream",inner[n],inner[next],glass[next],glass[n],reveal_normal)
