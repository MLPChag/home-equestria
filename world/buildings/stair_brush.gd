extends RefCounted
## Bake a visible stone ramp and landing matching its walkable collision.
## Dimensions are asset-local; the packed house supplies scale and rotation.
static func build(spec: Dictionary) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "StairBrush"
	body.collision_layer = 1
	body.collision_mask = 0
	var points := PackedVector3Array()
	var toe_y: float = spec.get("toe_y", -.025)
	var bottom := minf(-.08, toe_y-.04)
	# Extend the toe below the foundation plane to avoid a raised collision lip.
	for x: float in [spec.center_x-spec.width*.5, spec.center_x+spec.width*.5]:
		for yz: Vector2 in [Vector2(bottom,spec.back_z),Vector2(spec.height,spec.back_z),Vector2(spec.height,spec.landing_z),Vector2(toe_y,spec.toe_z),Vector2(bottom,spec.toe_z)]:
			points.append(Vector3(x,yz.x,yz.y))
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	shape.margin = .0001
	var collision := CollisionShape3D.new()
	collision.name = "RampAndLanding"
	collision.shape = shape
	body.add_child(collision)
	# Render the same convex hull, so there is no invisible slope above the steps.
	var surface:=SurfaceTool.new();surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var face:=PackedVector2Array()
	for i in 5:face.append(Vector2(points[i].z,points[i].y))
	var ids:=Geometry2D.triangulate_polygon(face)
	for i in range(0,ids.size(),3):
		for j in [ids[i],ids[i+1],ids[i+2]]:surface.add_vertex(points[j])
		for j in [ids[i+2],ids[i+1],ids[i]]:surface.add_vertex(points[j+5])
	for i in 5:
		var next:=(i+1)%5
		for j in [i,i+5,next+5,i,next+5,next]:surface.add_vertex(points[j])
	surface.generate_normals();surface.index()
	var mesh:=surface.commit()
	var stone:=MeshInstance3D.new();stone.name="StoneRamp"
	var material:=StandardMaterial3D.new();material.albedo_color=Color("bcb4b0");material.roughness=1.0;material.cull_mode=BaseMaterial3D.CULL_DISABLED
	stone.mesh=mesh;stone.material_override=material
	body.add_child(stone)
	return body
