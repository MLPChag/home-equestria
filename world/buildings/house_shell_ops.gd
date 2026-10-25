extends RefCounted
## house shell ops extracted from house_interior.gd.
## State and callback dispatch stay on the owning instance; authored transforms and order are unchanged.


static var _opened_meshes:Dictionary={}

static func _clear_ramp(context: Node3D, house:Node3D, terrain_ramp:Node) -> void:
	var ramp:Node3D=terrain_ramp if terrain_ramp!=null else house.get_node_or_null("StairBrush")
	if ramp==null:return
	var hull:=ramp.find_child("RampAndLanding",true,false) as CollisionShape3D
	if hull==null or not (hull.shape is ConvexPolygonShape3D):return
	var pts:PackedVector3Array=(hull.shape as ConvexPolygonShape3D).points
	if pts.size()<10:return
	# Recovery must recognize the actual fitted entrance support, including the
	# terrain replacement, without treating every surface of its house as safe.
	ramp.set_meta(&"house_entrance_support", true)
	var x0:=minf(pts[0].x,pts[5].x);var x1:=maxf(pts[0].x,pts[5].x)
	var outline:=PackedVector2Array()
	for i in 5:outline.append(Vector2(pts[i].z,pts[i].y))
	var to_ramp:=hull.global_transform.affine_inverse()
	var lift:=.06/maxf(hull.global_basis.get_scale().y,.001)
	var margin:=.02/maxf(hull.global_basis.get_scale().x,.001)
	var inside:=func(world:Vector3)->bool:
		var q:=to_ramp*world
		if q.x<x0-margin or q.x>x1+margin:return false
		return Geometry2D.is_point_in_polygon(Vector2(q.z,q.y-lift),outline)
	for holder:CollisionShape3D in house.find_children("*","CollisionShape3D",true,false):
		if not (holder.shape is ConcavePolygonShape3D) or ramp.is_ancestor_of(holder):continue
		var faces:PackedVector3Array=(holder.shape as ConcavePolygonShape3D).get_faces()
		var kept:=PackedVector3Array();var dropped:=0
		var xf:=holder.global_transform
		for i in range(0,faces.size(),3):
			var a:=xf*faces[i];var b:=xf*faces[i+1];var c:=xf*faces[i+2]
			var hits:=int(inside.call(a))+int(inside.call(b))+int(inside.call(c))
			if inside.call((a+b+c)/3.0) or hits>=2:dropped+=1;continue
			kept.append(faces[i]);kept.append(faces[i+1]);kept.append(faces[i+2])
		if dropped==0:continue
		var shape:=ConcavePolygonShape3D.new();shape.backface_collision=true;shape.set_faces(kept)
		holder.shape=shape

static func _prefab_transform(node: Node3D, ancestor: Node3D) -> Transform3D:
	var local := Transform3D.IDENTITY
	var cursor: Node = node
	while cursor != ancestor:
		assert(cursor != null, "Node must belong to this house")
		if cursor is Node3D: local = (cursor as Node3D).transform * local
		cursor = cursor.get_parent()
	return local

static func _open_wing(context: Node3D, house:Node3D) -> void:
	if (context.floors as Array[Rect2]).size()<2:return
	var shared:=(context.floors as Array[Rect2])[0].grow(.003).intersection((context.floors as Array[Rect2])[1].grow(.003))
	if shared.size==Vector2.ZERO:return
	var along_x:=shared.size.x>shared.size.y
	var line:=shared.get_center().y if along_x else shared.get_center().x
	var lo:=(shared.position.x if along_x else shared.position.y)+.015
	var hi:=(shared.end.x if along_x else shared.end.y)-.015
	var cut:={"along_x":along_x,"line":line,"lo":lo,"hi":hi,"y0":(context.floor_y as float)+.005,"y1":(context.floor_y as float)+.21}
	for mesh:MeshInstance3D in house.find_children("*","MeshInstance3D",true,false):
		if mesh.name!="Exterior" or mesh.mesh==null:continue
		# Work in the prefab's local frame. Cancelling large world translations and
		# rotations introduced float noise, invalidating the authored finish hash.
		var xf: Transform3D = context.transform.affine_inverse()*_prefab_transform(mesh, house)
		var old:Mesh=mesh.mesh
		if not _opened_meshes.has(old):_opened_meshes[old]=_cut_mesh(old,xf,cut)
		var opened:Mesh=_opened_meshes[old]
		for other:MeshInstance3D in house.find_children("*","MeshInstance3D",true,false):
			if other.mesh==old:other.mesh=opened
		for holder:CollisionShape3D in mesh.find_children("*","CollisionShape3D",true,false):
			var shape:=holder.shape as ConcavePolygonShape3D
			if shape==null or shape.has_meta("wing_opened"):continue
			var faces:=shape.get_faces();var kept:=PackedVector3Array()
			var fxf: Transform3D = context.transform.affine_inverse()*_prefab_transform(holder, house)
			var back:=fxf.affine_inverse()
			for i in range(0,faces.size(),3):
				var tri:=[fxf*faces[i],fxf*faces[i+1],fxf*faces[i+2]]
				for poly:Array in _pieces(tri,cut):
					for j in range(1,poly.size()-1):
						for bary:Vector3 in [poly[0],poly[j],poly[j+1]]:
							kept.append(back*(tri[0]*bary.x+tri[1]*bary.y+tri[2]*bary.z))
			shape.set_faces(kept);shape.set_meta("wing_opened",true)

static func _pieces(tri:Array,cut:Dictionary) -> Array:
	var whole:=[[Vector3(1,0,0),Vector3(0,1,0),Vector3(0,0,1)]]
	var a:Vector3=tri[0];var b:Vector3=tri[1];var c:Vector3=tri[2]
	var n:=(b-a).cross(c-a)
	if n.length_squared()<1e-14:return whole
	var nn:=n.normalized()
	if absf(nn.y)>.5 or (absf(nn.z) if cut.along_x else absf(nn.x))<.8:return whole
	var line:float=cut.line
	for v:Vector3 in tri:
		if absf((v.z if cut.along_x else v.x)-line)>.06:return whole
	var coord:=func(bary:Vector3)->Vector2:
		var p:Vector3=a*bary.x+b*bary.y+c*bary.z
		return Vector2(p.x if cut.along_x else p.z,p.y)
	# Does it touch the opening at all?
	var box:=Rect2(Vector2(cut.lo,cut.y0),Vector2(float(cut.hi)-float(cut.lo),float(cut.y1)-float(cut.y0)))
	var tri2:=PackedVector2Array([coord.call(whole[0][0]),coord.call(whole[0][1]),coord.call(whole[0][2])])
	var bounds:=Rect2(tri2[0],Vector2.ZERO).expand(tri2[1]).expand(tri2[2])
	if not bounds.intersects(box):return whole
	var out:=[]
	# along < lo | along > hi | inside the span below y0 | inside the span above y1
	for spec in [[[0,-1,cut.lo]],[[0,1,cut.hi]],[[0,1,cut.lo],[0,-1,cut.hi],[1,-1,cut.y0]],[[0,1,cut.lo],[0,-1,cut.hi],[1,1,cut.y1]]]:
		var poly:Array=whole[0].duplicate()
		for plane in spec:
			poly=_clip(poly,coord,int(plane[0]),int(plane[1]),float(plane[2]))
			if poly.size()<3:break
		if poly.size()>=3:out.append(poly)
	return out

static func _clip(poly:Array,coord:Callable,axis:int,sign:int,value:float) -> Array:
	var out:=[]
	for i in poly.size():
		var p:Vector3=poly[i];var q:Vector3=poly[(i+1)%poly.size()]
		var dp:float=sign*((coord.call(p) as Vector2)[axis]-value)
		var dq:float=sign*((coord.call(q) as Vector2)[axis]-value)
		if dp>=0:out.append(p)
		if (dp>=0)!=(dq>=0):out.append(p.lerp(q,dp/(dp-dq)))
	return out

static func _cut_mesh(source:Mesh,xf:Transform3D,cut:Dictionary) -> Mesh:
	var out:=ArrayMesh.new()
	var depths:Vector2=Vector2(INF,-INF)
	for s in source.get_surface_count():
		var arrays:=source.surface_get_arrays(s)
		var v:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var index:PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
		if index.is_empty():index=PackedInt32Array(range(v.size()))
		var kept:=PackedInt32Array()
		for i in range(0,index.size(),3):
			var ids:=[index[i],index[i+1],index[i+2]]
			var pieces:=_pieces([xf*v[ids[0]],xf*v[ids[1]],xf*v[ids[2]]],cut)
			if pieces.size()==1 and pieces[0].size()==3 and pieces[0][0]==Vector3(1,0,0) and pieces[0][1]==Vector3(0,1,0):
				kept.append_array(ids);continue
			for id:int in ids:
				var p:Vector3=xf*v[id]
				var d:float=p.z if cut.along_x else p.x
				depths.x=minf(depths.x,d);depths.y=maxf(depths.y,d)
			for poly:Array in pieces:
				var new_ids:=[]
				for bary:Vector3 in poly:new_ids.append(_interpolate_vertex(arrays,ids,bary))
				for j in range(1,new_ids.size()-1):kept.append_array([new_ids[0],new_ids[j],new_ids[j+1]])
		arrays[Mesh.ARRAY_INDEX]=kept
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		out.surface_set_material(s,source.surface_get_material(s))
	if depths.is_finite():out.set_meta("wing_cut_depths",depths)
	return out

static func _interpolate_vertex(arrays:Array,ids:Array,w:Vector3) -> int:
	var verts:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var index:=verts.size()
	for slot in [Mesh.ARRAY_VERTEX,Mesh.ARRAY_NORMAL]:
		var data=arrays[slot]
		if data==null or data.is_empty():continue
		var value:Vector3=data[ids[0]]*w.x+data[ids[1]]*w.y+data[ids[2]]*w.z
		data.append(value.normalized() if slot==Mesh.ARRAY_NORMAL else value);arrays[slot]=data
	for slot in [Mesh.ARRAY_TEX_UV,Mesh.ARRAY_TEX_UV2]:
		var data=arrays[slot]
		if data==null or data.is_empty():continue
		data.append(data[ids[0]]*w.x+data[ids[1]]*w.y+data[ids[2]]*w.z);arrays[slot]=data
	var colors=arrays[Mesh.ARRAY_COLOR]
	if colors!=null and not colors.is_empty():
		colors.append(colors[ids[0]]*w.x+colors[ids[1]]*w.y+colors[ids[2]]*w.z);arrays[Mesh.ARRAY_COLOR]=colors
	var tangents=arrays[Mesh.ARRAY_TANGENT]
	if tangents!=null and not tangents.is_empty():
		for k in 4:tangents.append(tangents[ids[0]*4+k]*w.x+tangents[ids[1]*4+k]*w.y+tangents[ids[2]*4+k]*w.z)
		arrays[Mesh.ARRAY_TANGENT]=tangents
	for slot in [Mesh.ARRAY_BONES,Mesh.ARRAY_WEIGHTS,Mesh.ARRAY_CUSTOM0,Mesh.ARRAY_CUSTOM1,Mesh.ARRAY_CUSTOM2,Mesh.ARRAY_CUSTOM3]:
		var data=arrays[slot]
		if data==null or data.is_empty():continue
		var stride:=int(data.size()/verts.size())
		var src:int=ids[0] if w.x>=w.y and w.x>=w.z else (ids[1] if w.y>=w.z else ids[2])
		for k in stride:data.append(data[src*stride+k])
		arrays[slot]=data
	return index


static func add_frame(home:Node3D,opened:Mesh,cut:Dictionary) -> void:
	if home.has_node("WingOpeningFrame") or not opened.has_meta("wing_cut_depths"):return
	var scale_m:float=home.global_basis.get_scale().x
	var measured:Vector2=opened.get_meta("wing_cut_depths")
	var depth:float=maxf(measured.y-measured.x,.10/scale_m)+.03/scale_m
	var middle:float=(measured.x+measured.y)*.5
	var width:float=.14/scale_m
	var bottom:float=home.floor_y-.025/scale_m
	var height:float=float(cut.y1)-bottom
	var st:SurfaceTool=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for entry:Array in [[float(cut.lo)-width*.5,bottom+height*.5,width,height], [float(cut.hi)+width*.5,bottom+height*.5,width,height], [(float(cut.lo)+float(cut.hi))*.5,float(cut.y1)+width*.5,float(cut.hi)-float(cut.lo)+width*2,width]]:
		var box:BoxMesh=BoxMesh.new()
		var pos:Vector3
		if cut.along_x:
			box.size=Vector3(entry[2],entry[3],depth);pos=Vector3(entry[0],entry[1],middle)
		else:
			box.size=Vector3(depth,entry[3],entry[2]);pos=Vector3(middle,entry[1],entry[0])
		st.append_from(box,0,Transform3D(Basis.IDENTITY,pos))
	var material:StandardMaterial3D=StandardMaterial3D.new()
	material.albedo_texture=home.WOOD
	material.albedo_color=Color(.72,.52,.36)
	material.roughness=.88;material.uv1_triplanar=true;material.uv1_world_triplanar=true
	material.uv1_scale=Vector3.ONE/1.4
	var frame:MeshInstance3D=MeshInstance3D.new();frame.name="WingOpeningFrame"
	frame.mesh=st.commit();frame.material_override=material;frame.layers=1<<16
	frame.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	home.add_child(frame)
	# Indoor trim: stops where house_interior.gd stops the rest (TRIM_RANGE, limit_range()).
	frame.visibility_range_end=80.0;frame.visibility_range_end_margin=6.0
