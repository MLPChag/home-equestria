extends RefCounted
## Convex aperture clipping with interpolated original UVs and normals. Offline only.
static func divide(poly: Array, normal: Vector3, distance: float) -> Array:
	var inside: Array=[];var outside: Array=[]
	for i in poly.size():
		var a: Dictionary=poly[i];var b: Dictionary=poly[(i+1)%poly.size()]
		var da:float=normal.dot(a.p)-distance;var db:float=normal.dot(b.p)-distance
		(inside if da>=0 else outside).append(a)
		if (da>=0)!=(db>=0):
			var t:=da/(da-db)
			var v:={"p":a.p.lerp(b.p,t),"n":a.n.lerp(b.n,t).normalized(),"uv":a.uv.lerp(b.uv,t)}
			inside.append(v);outside.append(v)
	return [inside,outside]

static func outside_volume(poly:Array,planes:Array) -> bool:
	for plane:Array in planes:
		var outside:=true
		for vertex:Dictionary in poly:
			if Vector3(plane[0]).dot(vertex.p)>=float(plane[1]):outside=false;break
		if outside:return true
	return false

static func emit(st: SurfaceTool, poly: Array, offset: Vector3=Vector3.ZERO) -> int:
	for i in range(1,poly.size()-1):
		for v: Dictionary in [poly[0],poly[i],poly[i+1]]:
			st.set_normal(v.n);st.set_uv(v.uv);st.add_vertex(v.p-offset)
	return maxi(0,poly.size()-2)

static func emit_panel(st: SurfaceTool, poly: Array, hinge: Vector3, opening: Dictionary) -> int:
	if poly.size()<3:return 0
	if opening.has("panel_depth"):
		# Some exports stack the surrounding recess over the painted panel.
		# Clip artwork to its measured depth before flattening; keep the knob.
		poly=divide(poly,Vector3.BACK,float(opening.depth)-float(opening.panel_depth))[0]
		poly=divide(poly,Vector3.FORWARD,-float(opening.depth)-float(opening.panel_depth))[0]
		if poly.size()<3:return 0
	var center:=Vector3.ZERO;var normal:=Vector3.ZERO
	for v:Dictionary in poly:center+=v.p;normal+=v.n
	center/=poly.size()
	var h:float=float(opening.top)-float(opening.bottom)
	var knob:bool=center.x>hinge.x+float(opening.width)*.62 and center.y>hinge.y+h*.28 and center.y<hinge.y+h*.65
	# A generated door is painted across a deep sculpted recess. Keep its front
	# artwork and knob, not the recess walls, as the moving wooden panel.
	if not knob and normal.z/float(poly.size())<.3:return 0
	var flat:Array=[]
	for v:Dictionary in poly:
		var q:Dictionary=v.duplicate()
		q.p.z=hinge.z+clampf(q.p.z-float(opening.depth),0.0001,.008 if knob else .0006)
		if not knob:q.n=Vector3.BACK
		flat.append(q)
	return emit(st,flat,hinge)

static func trim_stoop(house:Node3D,opening:Dictionary,spec:Dictionary) -> void:
	# Replace the generated protruding steps with the compact, visible ramp.
	# Preserve original UVs on the wall; only remove the low exterior stair box.
	var planes:Array=[
		[Vector3.RIGHT,float(spec.center_x)-float(spec.width)],
		[Vector3.LEFT,-float(spec.center_x)-float(spec.width)],
		[Vector3.DOWN,-float(opening.bottom)-.008],
		[Vector3.BACK,float(spec.landing_z)]]
	for mi:MeshInstance3D in house.find_children("*","MeshInstance3D",true,false):
		if mi.name!="Exterior":continue
		var result:=ArrayMesh.new()
		var transform:=house.global_transform.affine_inverse()*mi.global_transform
		for index in mi.mesh.get_surface_count():
			var arrays:=mi.mesh.surface_get_arrays(index)
			var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var normals:PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
			var uvs:PackedVector2Array=arrays[Mesh.ARRAY_TEX_UV]
			var ids:PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
			if ids.is_empty():for i in vertices.size():ids.append(i)
			var surface:=SurfaceTool.new();surface.begin(Mesh.PRIMITIVE_TRIANGLES)
			for triangle in range(0,ids.size(),3):
				var polygon:Array=[]
				for k in 3:
					var i:=ids[triangle+k]
					polygon.append({"p":transform*vertices[i],"n":(transform.basis.inverse().transposed()*normals[i]).normalized(),"uv":uvs[i]})
				if outside_volume(polygon,planes):
					emit(surface,polygon);continue
				for plane:Array in planes:
					if polygon.size()<3:break
					var halves:=divide(polygon,plane[0],plane[1])
					emit(surface,halves[1]);polygon=halves[0]
			surface.set_material(mi.mesh.surface_get_material(index));surface.generate_tangents();surface.index();surface.commit(result)
		mi.mesh=result;mi.transform=Transform3D.IDENTITY

static func apply(house: Node3D, opening: Dictionary) -> void:
	var contour:=PackedVector2Array()
	for p: Array in opening.contour:contour.append(Vector2(p[0],p[1]))
	# Door silhouettes are convex and counter-clockwise in the shared detector.
	if Geometry2D.is_polygon_clockwise(contour):contour.reverse()
	var planes: Array=[[Vector3.BACK,float(opening.depth)-float(opening.get("cut_back",.045))],[Vector3.FORWARD,-float(opening.depth)-float(opening.get("cut_front",.045))]]
	for i in contour.size():
		var a:=contour[i];var b:=contour[(i+1)%contour.size()]
		var normal:=Vector3(-(b.y-a.y),b.x-a.x,0)
		planes.append([normal,normal.dot(Vector3(a.x,a.y,0))])
	var hinge:=Vector3(float(opening.center)-float(opening.width)*.5,float(opening.bottom),float(opening.get("leaf_depth",opening.depth)))
	var door: AnimatableBody3D=preload("res://world/buildings/hinged_door.gd").new()
	door.name="FrontDoor";door.position=hinge
	door.navigation_box=AABB(Vector3(-.01,0,-float(opening.width)-.01),Vector3(float(opening.width)+.02,float(opening.top)-float(opening.bottom)+.01,float(opening.width)+.02))
	door.handle=Vector3(float(opening.width)*.83,(float(opening.top)-float(opening.bottom))*.45,.009)
	var removed:=0
	var wall_triangles:=PackedVector3Array()
	for mi: MeshInstance3D in house.find_children("*","MeshInstance3D",true,false):
		if mi.name!="Exterior":continue
		var exterior:=ArrayMesh.new();var leaf:=ArrayMesh.new()
		var transform:=house.global_transform.affine_inverse()*mi.global_transform
		for surface in mi.mesh.get_surface_count():
			var arrays:=mi.mesh.surface_get_arrays(surface)
			var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX];var normals:PackedVector3Array=arrays[Mesh.ARRAY_NORMAL];var uvs:PackedVector2Array=arrays[Mesh.ARRAY_TEX_UV]
			var ids:PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
			if ids.is_empty():for i in vertices.size():ids.append(i)
			var outside:=SurfaceTool.new();outside.begin(Mesh.PRIMITIVE_TRIANGLES)
			var panel:=SurfaceTool.new();panel.begin(Mesh.PRIMITIVE_TRIANGLES)
			var nout:=0;var nin:=0
			for triangle in range(0,ids.size(),3):
				var polygon: Array=[]
				for k in 3:
					var i:=ids[triangle+k]
					polygon.append({"p":transform*vertices[i],"n":(transform.basis.inverse().transposed()*normals[i]).normalized(),"uv":uvs[i]})
					wall_triangles.append(transform*vertices[i])
				if outside_volume(polygon,planes):
					nout+=emit(outside,polygon);continue
				for plane: Array in planes:
					if polygon.size()<3:break
					var halves:=divide(polygon,plane[0],plane[1])
					nout+=emit(outside,halves[1]);polygon=halves[0]
				nin+=emit_panel(panel,polygon,hinge,opening)
			if nout>0:
				var wall_material:Material=mi.mesh.surface_get_material(surface).duplicate()
				# These hollow exports have no separate inner wall mesh. Keep the wall
				# opaque from inside as well, so the fitted jamb cannot look detached.
				if wall_material is BaseMaterial3D:wall_material.cull_mode=BaseMaterial3D.CULL_DISABLED
				outside.set_material(wall_material);outside.generate_tangents();outside.index();outside.commit(exterior)
			if nin>0:
				panel.set_material(mi.mesh.surface_get_material(surface));panel.generate_tangents();panel.index();panel.commit(leaf)
			removed+=nin
		mi.mesh=exterior;mi.transform=Transform3D.IDENTITY
		var face:=MeshInstance3D.new();face.name="OriginalDoorArtwork"
		face.mesh=preload("res://tools/buildings/door_panel_cleanup.gd").clean(leaf)
		door.add_child(face)
	assert(removed>0,"No door triangles extracted")
	# A solid 4-cm leaf behind the extracted exterior. No painted duplicate remains.
	var back:=SurfaceTool.new();back.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ids:=Geometry2D.triangulate_polygon(contour)
	for i in ids:
		var p:=contour[i];back.set_normal(Vector3.FORWARD);back.add_vertex(Vector3(p.x,p.y,hinge.z-.004)-hinge)
	var hull:=PackedVector3Array()
	for i in contour.size():
		var a:=Vector3(contour[i].x,contour[i].y,hinge.z)-hinge
		var b:=Vector3(contour[(i+1)%contour.size()].x,contour[(i+1)%contour.size()].y,hinge.z)-hinge
		var inner:=Vector3(0,0,-.004)
		hull.append(a);hull.append(a+inner)
		var normal:=(b-a).cross(inner).normalized()
		for v in [a,b,b+inner,a,b+inner,a+inner]:back.set_normal(normal);back.add_vertex(v)
	var mat:=StandardMaterial3D.new();mat.albedo_color=Color("bb879a");mat.roughness=.9;mat.cull_mode=BaseMaterial3D.CULL_DISABLED;back.set_material(mat)
	var back_mesh:=MeshInstance3D.new();back_mesh.name="LeafThickness";back_mesh.mesh=back.commit();door.add_child(back_mesh)
	var collision:=CollisionShape3D.new();collision.name="LeafCollision";var shape:=ConvexPolygonShape3D.new();shape.points=hull;shape.margin=.0001;collision.shape=shape;door.add_child(collision)
	house.add_child(preload("res://tools/buildings/door_frame.gd").build(contour,hinge.z,wall_triangles,true,.008,false,float(opening.get("frame_back",hinge.z-.008))))
	house.add_child(door)
	house.set_meta("opening_status","front door: left hinge, inward grip drag")
