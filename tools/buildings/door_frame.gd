extends RefCounted
## Offline fitted jamb: outer edge meets the source wall; inner edge rebates the leaf.
static func offset_vertex(contour:PackedVector2Array,i:int,amount:float) -> Vector2:
	var a:Vector2=(contour[i]-contour[(i+contour.size()-1)%contour.size()]).normalized()
	var b:Vector2=(contour[(i+1)%contour.size()]-contour[i]).normalized()
	var na:=Vector2(a.y,-a.x);var nb:=Vector2(b.y,-b.x)
	return contour[i]+(na+nb)*amount/maxf(1.0+na.dot(nb),.1)

static func wall_depth(triangles:PackedVector3Array,xy:Vector2,depth:float) -> float:
	var start:=Vector3(xy.x,xy.y,depth+.15)
	var end:=Vector3(xy.x,xy.y,depth-.15)
	var nearest:float=-INF
	for i in range(0,triangles.size(),3):
		var hit:Variant=Geometry3D.segment_intersects_triangle(start,end,triangles[i],triangles[i+1],triangles[i+2])
		if hit!=null:nearest=maxf(nearest,hit.z)
	return nearest

static func quad(st:SurfaceTool,a:Vector3,b:Vector3,c:Vector3,d:Vector3) -> void:
	var normal:Vector3=(c-a).cross(b-a).normalized()
	for p:Vector3 in [a,b,c,a,c,d]:st.set_normal(normal);st.add_vertex(p)

static func build(contour:PackedVector2Array,depth:float,triangles:PackedVector3Array,threshold:bool=true,step_length:float=.008,surface_lip:bool=false,back_depth:float=NAN) -> MeshInstance3D:
	if is_nan(back_depth):back_depth=depth-.008
	var inner:=PackedVector3Array();var outer:=PackedVector3Array()
	var bottom:float=INF
	for p:Vector2 in contour:bottom=minf(bottom,p.y)
	for i in contour.size():
		var j: int=(i+1)%contour.size()
		var count:=maxi(1,ceili(contour[i].distance_to(contour[j])/step_length))
		for step in count:
			var t:=float(step)/count
			var rim:Vector2=offset_vertex(contour,i,.006).lerp(offset_vertex(contour,j,.006),t)
			var lip:Vector2=offset_vertex(contour,i,-.001).lerp(offset_vertex(contour,j,-.001),t)
			# 2 mm overlap into the original outer surface avoids a coplanar seam.
			var z:=wall_depth(triangles,rim,depth)+.0002
			# The threshold meets the floor; it must not stretch onto the front step.
			if threshold and rim.y<bottom+.002:z=depth+.003
			# A flowerbox below a window is not its wall support. Keep the
			# bottom casing behind projecting flowers and the existing sill.
			if surface_lip and rim.y<bottom+.01:z=minf(z,depth+.006)
			outer.append(Vector3(rim.x,rim.y,z))
			inner.append(Vector3(lip.x,lip.y,depth+.001))
	# Small holes in a generated wall must not turn into deep spikes in the jamb.
	# Bridge only missing samples between the two nearest measured neighbours.
	var measured:=outer.duplicate()
	for i in outer.size():
		if is_finite(measured[i].z):continue
		var before:=1;var after:=1
		while before<outer.size() and not is_finite(measured[posmod(i-before,outer.size())].z):before+=1
		while after<outer.size() and not is_finite(measured[(i+after)%outer.size()].z):after+=1
		assert(before<outer.size(),"Door frame has no wall support")
		outer[i].z=lerpf(measured[posmod(i-before,outer.size())].z,measured[(i+after)%outer.size()].z,float(before)/(before+after))
	if surface_lip:
		# Raised casing stays in front of plaster all the way to the cut edge.
		# The separate rebate below still reaches the recessed glazing.
		for i in inner.size():
			inner[i].z=maxf(inner[i].z,outer[i].z+.001)
	var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in inner.size():
		var j: int=(i+1)%inner.size()
		var ai:=inner[i];var bi:=inner[j];var ao:=outer[i];var bo:=outer[j]
		var ab:=Vector3(ai.x,ai.y,back_depth);var bb:=Vector3(bi.x,bi.y,back_depth)
		quad(st,ai,bi,bo,ao)
		quad(st,ai,ab,bb,bi)
		quad(st,ab,ao,bo,bb)
	var mat:=StandardMaterial3D.new();mat.albedo_color=Color("ad8977");mat.roughness=.9;mat.cull_mode=BaseMaterial3D.CULL_DISABLED;st.set_material(mat)
	var frame:=MeshInstance3D.new();frame.name="DoorReveal";frame.mesh=st.commit()
	frame.create_trimesh_collision()
	return frame
