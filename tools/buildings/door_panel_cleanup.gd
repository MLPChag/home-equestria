extends RefCounted
## Offline panel cleanup: retain one artwork surface, including original UVs.
## The flattened recess folds sit in front of the actual panel; prefer the panel.
static func side(p:Vector3,a:Vector3,b:Vector3) -> float:
	return (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
static func split(poly:Array,a:Vector3,b:Vector3,orientation:float) -> Array:
	var inside:=[];var outside:=[]
	for i in poly.size():
		var x:Dictionary=poly[i];var y:Dictionary=poly[(i+1)%poly.size()]
		var dx:=side(x.p,a,b)*orientation;var dy:=side(y.p,a,b)*orientation
		(inside if dx>=0 else outside).append(x)
		if (dx>=0)!=(dy>=0):
			var t:=dx/(dx-dy)
			var cut:={"p":x.p.lerp(y.p,t),"n":x.n.lerp(y.n,t).normalized(),"uv":x.uv.lerp(y.uv,t)}
			inside.append(cut);outside.append(cut)
	return [inside,outside]
static func subtract(poly:Array,triangle:Array) -> Array:
	var subject:=PackedVector2Array();var cutter:=PackedVector2Array()
	for v:Dictionary in poly:subject.append(Vector2(v.p.x,v.p.y))
	for v:Dictionary in triangle:cutter.append(Vector2(v.p.x,v.p.y))
	if Geometry2D.intersect_polygons(subject,cutter).is_empty():return [poly]
	var pieces:=[];var remaining:=poly
	var direction:=signf(side(triangle[2].p,triangle[0].p,triangle[1].p))
	for edge in 3:
		if remaining.size()<3:break
		var halves:=split(remaining,triangle[edge].p,triangle[(edge+1)%3].p,direction)
		if halves[1].size()>=3:pieces.append(halves[1])
		remaining=halves[0]
	return pieces
static func clean(source:Mesh) -> ArrayMesh:
	var triangles:=[]
	for surface in source.get_surface_count():
		var a:=source.surface_get_arrays(surface)
		var indices:PackedInt32Array=a[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			for i in a[Mesh.ARRAY_VERTEX].size():indices.append(i)
		for t in range(0,indices.size(),3):
			var poly:=[];var depth:=0.0;var rect:=Rect2()
			for k in 3:
				var i:=indices[t+k];var p:Vector3=a[Mesh.ARRAY_VERTEX][i]
				poly.append({"p":p,"n":a[Mesh.ARRAY_NORMAL][i],"uv":a[Mesh.ARRAY_TEX_UV][i]})
				depth+=p.z
				rect=Rect2(Vector2(p.x,p.y),Vector2.ZERO) if k==0 else rect.expand(Vector2(p.x,p.y))
			if absf(side(poly[2].p,poly[0].p,poly[1].p))>1e-12:
				triangles.append({"poly":poly,"depth":depth/3,"surface":surface,"bounds":rect})
	triangles.sort_custom(func(a,b):return a.depth<b.depth)
	var output:=[]
	for s in source.get_surface_count():output.append([])
	var nearer:=[]
	for triangle:Dictionary in triangles:
		var pieces:Array=[triangle.poly]
		for front:Dictionary in nearer:
			if not triangle.bounds.intersects(front.bounds):continue
			var next:=[]
			for poly:Array in pieces:next.append_array(subtract(poly,front.poly))
			pieces=next
			if pieces.is_empty():break
		output[triangle.surface].append_array(pieces)
		nearer.append(triangle)
	var result:=ArrayMesh.new()
	for surface in output.size():
		var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES);var count:=0
		for poly:Array in output[surface]:
			for i in range(1,poly.size()-1):
				if absf(side(poly[i+1].p,poly[0].p,poly[i].p))<1e-12:continue
				for v:Dictionary in [poly[0],poly[i],poly[i+1]]:
					st.set_normal(v.n);st.set_uv(v.uv);st.add_vertex(v.p)
				count+=1
		if count>0:
			st.set_material(source.surface_get_material(surface));st.generate_tangents();st.index();st.commit(result)
	return result
