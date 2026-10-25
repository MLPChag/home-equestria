extends RefCounted
## house floor fit extracted from house_interior.gd.
## State and callback dispatch stay on the owning instance; authored transforms and order are unchanged.

const TRIM_RANGE:=80.0
const WOOD:=preload("res://world/buildings/textures/wood_floor.res")
const INTERIOR:=preload("res://world/buildings/interior_surface.gdshader")


static func _dress_floor(context: Node3D, house:Node3D) -> void:
	var t:=float(absi(hash(str(house.name)+str(roundi(context.global_position.x))+str(roundi(context.global_position.z))))%1000)/1000.0
	var tint:=Color(0.58,0.44,0.34).lerp(Color(1.12,1.04,0.94),t)
	var mat:=ShaderMaterial.new();mat.shader=INTERIOR
	mat.set_shader_parameter("albedo_map",WOOD);mat.set_shader_parameter("has_texture",true)
	mat.set_shader_parameter("planar",true);mat.set_shader_parameter("base_color",tint)
	var dressed:=false
	for mesh:MeshInstance3D in house.find_children("*","MeshInstance3D",true,false):
		if not (str(mesh.name).begins_with("FloorSlab") or mesh.get_parent().name=="InnerThresholdRamp"):continue
		# The prefab's edge-fill sheet reaches up to 0.9 m past the walls (house D) and showed
		# outside; the fitted underlay and skirting below cover what it was for.
		if str(mesh.name).begins_with("FloorSlabEdgeFill"):mesh.visible=false;continue
		mesh.material_override=null;dressed=true
		for i in mesh.mesh.get_surface_count():mesh.set_surface_override_material(i,mat)
	if not dressed:return
	context._floor_material=mat
	context._fit_floor.call_deferred()

static func _walls_ready(context: Node3D) -> bool:
	var space:=context.get_world_3d().direct_space_state
	var up:=context.global_basis.y.normalized()
	for rect:Rect2 in (context.floors as Array[Rect2]):
		var centre:=Vector3(rect.get_center().x,(context.floor_y as float),rect.get_center().y)
		if space.intersect_ray(PhysicsRayQueryParameters3D.create(context.to_global(centre+Vector3.UP*.1),context.to_global(centre-Vector3.UP*.1),1)).is_empty():return false
		var walls:=0
		for side:Vector2 in [Vector2(-1,0),Vector2(1,0),Vector2(0,-1),Vector2(0,1)]:
			var edge:=rect.get_center()+side*rect.size*.5
			var a:=context.to_global(centre)+up*.3
			var b:=context.to_global(Vector3(edge.x+side.x*.35,(context.floor_y as float),edge.y+side.y*.35))+up*.3
			if not space.intersect_ray(PhysicsRayQueryParameters3D.create(a,b,1)).is_empty():walls+=1
		if walls<2:return false
	return true

static func _fit_floor(context: Node3D) -> void:
	if (context._floor_material as ShaderMaterial)==null:return
	# dev 2026-09-25 (grass along a house D wall): this ran once, deferred, sometimes before the
	# house's collision was in the physics world. With no wall hits the underlay was laid 25 cm
	# inside the room and the edge fill stayed hidden, so the ground showed through. Wait for
	# the floor AND the walls like _place_bed() waits for the floor.
	if not context.is_inside_tree():
		if not context.tree_entered.is_connected(context._fit_floor):context.tree_entered.connect(context._fit_floor.call_deferred,CONNECT_ONE_SHOT)
		return
	if not (context._walls_ready() as bool) and (context._fit_tries as int)<15:
		context._fit_tries+=1
		context.get_tree().create_timer(1.0).timeout.connect(context._fit_floor)
		return
	var space:=context.get_world_3d().direct_space_state
	var scale_m:=maxf(context.global_basis.get_scale().x,.001)
	var up:=context.global_basis.y.normalized()
	var tuck:=.03/scale_m
	for rect:Rect2 in (context.floors as Array[Rect2]):
		var centre:=Vector3(rect.get_center().x,(context.floor_y as float),rect.get_center().y)
		var down:=space.intersect_ray(PhysicsRayQueryParameters3D.create(context.to_global(centre+Vector3.UP*.1),context.to_global(centre-Vector3.UP*.1),1))
		var top:float=context.to_local(down.position).y if not down.is_empty() else (context.floor_y as float)
		var sides:={}
		for side:Vector2 in [Vector2(-1,0),Vector2(1,0),Vector2(0,-1),Vector2(0,1)]:
			var along:=Vector2(side.y,side.x).abs()
			var edge_c:=rect.get_center()+side*rect.size*.5
			var span:=(rect.size*along).length()
			var depth:=(rect.size*side.abs()).length()
			var start:=minf(depth*.3,.12)
			var hits:=[]
			var samples:=9
			for k in samples:
				var f:=(k+.5)/samples-.5
				var at:=edge_c+along*span*f
				var inner:=at-side*start
				var a:=context.to_global(Vector3(inner.x,top,inner.y))+up*.05
				var b:=context.to_global(Vector3(at.x+side.x*.35,top,at.y+side.y*.35))+up*.05
				var hit:=space.intersect_ray(PhysicsRayQueryParameters3D.create(a,b,1))
				if hit.is_empty() or "Door" in str(hit.collider.name) or hit.collider is AnimatableBody3D:
					hits.append(null);continue
				var lp:=context.to_local(hit.position)
				var d:=(Vector2(lp.x,lp.z)-at).dot(side)
				# Beyond ~35 cm out is not this room's wall: an L-wing or a doorway looking
				# through to the far wall (made house C's floor run out the front door).
				if d>.35/scale_m or d<-start+.005:hits.append(null);continue
				hits.append(d)
			var found:=hits.filter(func(h):return h!=null)
			found.sort()
			# No wall measured on this side (doorway, opening): stay 25 cm inside the plan rect
			# and no tuck, since the rect itself can run past the wall (it poked out of house
			# plot_2677 as a ledge that boxed ponies in).
			var offset:float=found[found.size()/2]+tuck if found.size()>=3 else -.25/scale_m
			sides[side]=offset
		# Out to the wall faces (tucked 3 cm under them), never past them.
		var x0:=rect.position.x-float(sides[Vector2(-1,0)])
		var x1:=rect.end.x+float(sides[Vector2(1,0)])
		var z0:=rect.position.y-float(sides[Vector2(0,-1)])
		var z1:=rect.end.y+float(sides[Vector2(0,1)])
		var r:=Rect2(x0,z0,maxf(x1-x0,.01),maxf(z1-z0,.01))
		(context._fitted_rooms as Array[Rect2]).append(r.grow(-.004/scale_m))
		(context._room_tops as Array[float]).append(top)
	context._floor_fitted=true
	context._furnish_when_ready.call_deferred()

static func _dress_door(context: Node3D) -> void:
	var leaf:=(context.door() as Node)
	if leaf==null or leaf.get_node_or_null("InsideArtwork")!=null:return
	var art:=leaf.get_node_or_null("OriginalDoorArtwork") as MeshInstance3D
	if art==null or art.mesh==null:return
	var box:=art.transform*art.mesh.get_aabb()
	var inside:=MeshInstance3D.new();inside.name="InsideArtwork";inside.mesh=art.mesh
	inside.transform=Transform3D(Basis.from_scale(Vector3(1,1,-1)),Vector3(0,0,box.position.z-.0045))*art.transform
	inside.layers=1<<16
	inside.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for i in art.mesh.get_surface_count():
		var src:=art.get_active_material(i)
		var tex:Texture2D=src.albedo_texture if src is BaseMaterial3D else (src.get_shader_parameter("albedo_map") if src is ShaderMaterial else null)
		var mat:=ShaderMaterial.new();mat.shader=INTERIOR
		mat.set_shader_parameter("albedo_map",tex);mat.set_shader_parameter("has_texture",tex!=null)
		if src is BaseMaterial3D:mat.set_shader_parameter("base_color",(src as BaseMaterial3D).albedo_color)
		inside.set_surface_override_material(i,mat)
	leaf.add_child(inside)
	context.limit_range(inside,TRIM_RANGE,false)

