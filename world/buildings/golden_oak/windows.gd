extends RefCounted
## Real oval apertures through the curved lining and original bark. Coordinates in room metres.
const KIT = preload("res://world/buildings/golden_oak/furniture_kit.gd")
const SEGMENTS := 32
const SPLAY := .16 # Modest outward flare through the thick bark.
static var _windows: Array[Dictionary] = []

static func definitions() -> Array[Dictionary]:
	if not _windows.is_empty(): return _windows
	for row: Array in [["TwilightWindow",166.0,5.58,1.22,1.05,true], ["ReadingWindow",170.0,1.96,.86,.87,false]]:
		var angle := deg_to_rad(float(row[1]))
		var outward := Vector3(sin(angle),0,cos(angle))
		var tangent := Vector3(cos(angle),0,-sin(angle))
		var centre := outward * 5.01 + Vector3.UP * float(row[2])
		var planes: Array[Plane] = [Plane(-outward,-4.55),Plane(outward,12.0)]
		for i in SEGMENTS:
			var theta := TAU * (i + .5) / SEGMENTS
			var side := tangent * (cos(theta) / float(row[3])) + Vector3.UP * (sin(theta) / float(row[4]))
			var edge := cos(PI / SEGMENTS)
			var raw := side-outward*(edge*SPLAY)
			planes.append(Plane(raw.normalized(), (side.dot(centre)+edge-edge*SPLAY*5.01)/raw.length()))
		_windows.append({"name":row[0],"centre":centre,"out":outward,"right":tangent,"w":float(row[3]),"h":float(row[4]),"curtains":row[5],"planes":planes,"faces":PackedVector3Array()})
	return _windows

static func begin_shell() -> void:
	for window: Dictionary in definitions(): window.faces = PackedVector3Array()

static func _candidate(poly: Array, window: Dictionary, margin: float = 1.0) -> bool:
	var minimum := Vector3(INF,INF,INF)
	var maximum := Vector3(-INF,-INF,-INF)
	for vertex: Array in poly:
		var p: Vector3 = vertex[0] - window.centre
		var depth := Vector3(vertex[0]).dot(window.out)
		var q := Vector3(p.dot(window.right),p.y,depth)
		minimum = minimum.min(q); maximum = maximum.max(q)
	var spread := maxf(1.0,1.0+SPLAY*(maximum.z-5.01))*margin
	return minimum.x < float(window.w)*spread and maximum.x > -float(window.w)*spread and minimum.y < float(window.h)*spread and maximum.y > -float(window.h)*spread and minimum.z < 12.0 and maximum.z > 4.55

## Subtract a convex aperture from a polygon, preserving normals and UVs at cut edges.
static func _subtract(poly: Array, window: Dictionary) -> Array:
	if not _candidate(poly, window): return [poly]
	var remaining := poly
	var outside: Array = []
	for plane: Plane in window.planes:
		if remaining.size() < 3: break
		var inside: Array = []
		var clipped: Array = []
		for i in remaining.size():
			var a: Array = remaining[i]
			var b: Array = remaining[(i+1)%remaining.size()]
			var da := plane.distance_to(a[0]); var db := plane.distance_to(b[0])
			if da <= 0: inside.append(a)
			else: clipped.append(a)
			if (da <= 0) != (db <= 0):
				var t := da / (da-db)
				var cut: Array = [Vector3(a[0]).lerp(b[0],t), Vector3(a[1]).lerp(b[1],t).normalized(), Vector2(a[2]).lerp(b[2],t)]
				inside.append(cut); clipped.append(cut)
		if clipped.size() >= 3: outside.append(clipped)
		remaining = inside
	return outside

static func polygons(poly: Array) -> Array:
	var pieces: Array = [poly]
	for window: Dictionary in definitions():
		var next: Array = []
		for piece: Array in pieces: next.append_array(_subtract(piece,window))
		pieces = next
	return pieces

static func cut_surface(arrays: Array, origin: Vector3) -> Array:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for offset in range(0,indices.size(),3):
		var triangle: Array = []
		for j in 3:
			var i := indices[offset+j]
			triangle.append([(vertices[i]-origin)*2.0,normals[i],uvs[i] if not uvs.is_empty() else Vector2.ZERO])
		for window: Dictionary in definitions():
			if _candidate(triangle,window,1.25):
				for vertex: Array in triangle: window.faces.append(vertex[0])
		for poly: Array in polygons(triangle):
			for j in range(1,poly.size()-1):
				for i: int in [0,j,j+1]:
					st.set_normal(poly[i][1]); st.set_uv(poly[i][2]); st.add_vertex(origin+Vector3(poly[i][0])*.5)
	st.index()
	return st.commit_to_arrays()

static func wall_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for tri: Array in [[a,b,c],[a,c,d]]:
		var triangle: Array = []
		for point: Vector3 in tri: triangle.append([point,Vector3.UP,Vector2.ZERO])
		for poly: Array in polygons(triangle):
			for j in range(1,poly.size()-1):
				for i: int in [0,j,j+1]: st.add_vertex(poly[i][0])

static func _rim_point(window: Dictionary, theta: float, inner: bool) -> Vector3:
	var tangent: Vector3 = window.right
	var outward: Vector3 = window.out
	var x: float = cos(theta)*float(window.w)
	var y: float = float(window.centre.y)+sin(theta)*float(window.h)
	var point := tangent*x + outward*sqrt(5.01*5.01-x*x) + Vector3.UP*y
	if inner: return point
	var offset := tangent*x+Vector3.UP*(y-float(window.centre.y))
	var growth := offset*SPLAY
	var start := outward*4.6+Vector3.UP*float(window.centre.y)+offset+growth*(4.6-5.01)
	var end := outward*12.0+Vector3.UP*float(window.centre.y)+offset+growth*(12.0-5.01)
	var nearest := 12.0
	var faces: PackedVector3Array = window.faces
	for i in range(0,faces.size(),3):
		var hit: Variant = Geometry3D.segment_intersects_triangle(start,end,faces[i],faces[i+1],faces[i+2])
		if hit != null: nearest = minf(nearest,Vector3(hit).dot(outward))
	var depth := nearest if nearest < 11.99 else 5.75
	return outward*depth+Vector3.UP*float(window.centre.y)+offset+growth*(depth-5.01)

static func build(parent: Node3D) -> void:
	var wood := KIT.material("bd6857")
	wood.cull_mode = BaseMaterial3D.CULL_DISABLED
	var edge := KIT.material("efad7a")
	var bars := KIT.material("b46865")
	for window: Dictionary in definitions():
		var frame := Node3D.new(); frame.name = window.name; parent.add_child(frame)
		frame.set_meta("window_centre",window.centre)
		frame.set_meta("window_outward",window.out)
		var inner := PackedVector3Array(); var outer := PackedVector3Array()
		for i in SEGMENTS+1:
			var theta := TAU*i/SEGMENTS
			inner.append(_rim_point(window,theta,true))
			outer.append(_rim_point(window,theta,false))
		var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES); st.set_material(wood)
		for i in SEGMENTS:
			for p: Vector3 in [inner[i],outer[i],outer[i+1],inner[i],outer[i+1],inner[i+1]]: st.add_vertex(p)
		st.generate_normals()
		var reveal := MeshInstance3D.new(); reveal.name="CarvedWindowReveal"; reveal.mesh=st.commit(); frame.add_child(reveal)
		reveal.create_trimesh_collision()
		KIT.tube(frame,"InnerOvalTrim",inner,.065,edge)
		KIT.tube(frame,"OuterOvalTrim",outer,.065,wood)
		# A nearly clear pane leaves the real outside world visible, with no emissive sky card.
		var glass := StandardMaterial3D.new()
		glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glass.albedo_color = Color(.63,.85,.94,.09)
		glass.roughness = .2
		glass.cull_mode = BaseMaterial3D.CULL_DISABLED
		var pane := SurfaceTool.new(); pane.begin(Mesh.PRIMITIVE_TRIANGLES); pane.set_material(glass)
		for i in SEGMENTS:
			for point: Vector3 in [Vector3(window.centre),inner[i],inner[i+1]]: pane.add_vertex(point)
		pane.generate_normals()
		var view := MeshInstance3D.new(); view.name="ClearWindowPane"; view.mesh=pane.commit()
		view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; frame.add_child(view)
		view.create_trimesh_collision()
		for collision: CollisionShape3D in view.find_children("*","CollisionShape3D",true,false):
			(collision.shape as ConcavePolygonShape3D).backface_collision=true
		# Sweeping curved mullions echo the show's arched bedroom window.
		for side: float in [-1.0,1.0]:
			var curve := PackedVector3Array()
			for i in 25:
				var t := i/24.0
				var x: float = side*float(window.w)*(.04+.59*sin(PI*t))
				var y: float = lerpf(-float(window.h)*.97,float(window.h)*.97,t)
				curve.append(Vector3(window.centre)+Vector3(window.right)*x+Vector3.UP*y-Vector3(window.out)*.035)
			KIT.tube(frame,"CurvedRoseMullion",curve,.023,bars)
		if bool(window.curtains): _curtains(frame,window)
		window.faces = PackedVector3Array() # Fitting samples are only needed during construction.

static func _curtains(parent: Node3D, window: Dictionary) -> void:
	var fabric := KIT.material("f1d04e"); fabric.cull_mode=BaseMaterial3D.CULL_DISABLED
	var gold := KIT.material("cb9940")
	var centre: Vector3 = window.centre-Vector3(window.out)*.14
	var right: Vector3 = window.right
	var out: Vector3 = window.out
	var rod := PackedVector3Array([centre-right*1.55+Vector3.UP*1.16,centre+right*1.55+Vector3.UP*1.16])
	KIT.tube(parent,"BedroomCurtainRod",rod,.045,KIT.material("e8b98a"))
	for side: float in [-1.0,1.0]:
		var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES); st.set_material(fabric)
		for row in 24:
			for col in 12:
				var quad: Array[Vector3] = []
				for uv: Vector2 in [Vector2(col,row),Vector2(col+1,row),Vector2(col+1,row+1),Vector2(col,row+1)]:
					var u := uv.x/12.0; var v := uv.y/24.0
					var width := .22+.43*pow(absf(v-.42)*1.72,1.2)
					var x := side*(1.39-width*u)
					quad.append(centre+right*x+Vector3.UP*lerpf(-1.08,1.18,v)-out*(.045*sin(u*TAU*3.0)+.18*sin(v*PI)))
				for i: int in [0,1,2,0,2,3]:st.add_vertex(quad[i])
		st.generate_normals()
		var curtain := MeshInstance3D.new();curtain.name="GoldBedroomCurtain";curtain.mesh=st.commit();parent.add_child(curtain)
		KIT.tube(parent,"CurtainTie",PackedVector3Array([centre+right*(side*1.12)-Vector3.UP*.16-out*.22,centre+right*(side*1.44)-Vector3.UP*.10-out*.1]),.04,gold)
