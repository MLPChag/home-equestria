extends RefCounted
## house routing extracted from house_interior.gd.
## State and callback dispatch stay on the owning instance; authored transforms and order are unchanged.

const LINE_CLEARANCE:=.22   # metres: the body's half width at chest height
const LINE_CHEST:=.5        # metres above the floor


static func _measure_passage(context: Node3D) -> void:
	context._passage_done=true
	if (context.floors as Array[Rect2]).size()<2:return
	var a:Rect2=(context.floors as Array[Rect2])[0];var b:Rect2=(context.floors as Array[Rect2])[1]
	var shared:=a.grow(.003).intersection(b.grow(.003))
	if shared.size==Vector2.ZERO:return
	var along_x:=shared.size.x>shared.size.y
	var ca:=a.get_center();var cb:=b.get_center()
	var space:=context.get_world_3d().direct_space_state
	var clear:Array[bool]=[]
	var samples:=15
	for k in samples:
		var t:=(k+.5)/samples
		var p:=Vector2(shared.position.x+shared.size.x*t,shared.get_center().y) if along_x else Vector2(shared.get_center().x,shared.position.y+shared.size.y*t)
		var edge:=context.to_global(Vector3(p.x,(context.floor_y as float),p.y))
		var side_a:=edge+(context.to_global(Vector3(ca.x,(context.floor_y as float),ca.y))-edge).normalized()*.45
		var side_b:=edge+(context.to_global(Vector3(cb.x,(context.floor_y as float),cb.y))-edge).normalized()*.45
		var ok:=true
		for h in [.3,.75]:
			if not space.intersect_ray(PhysicsRayQueryParameters3D.create(side_a+Vector3.UP*h,side_b+Vector3.UP*h,1)).is_empty():ok=false
		clear.append(ok)
	if not clear.has(false):context._passage_open_all=true;return
	var best_start:=-1;var best_len:=0;var run_start:=-1
	for k in samples+1:
		if k<samples and clear[k]:
			if run_start<0:run_start=k
		elif run_start>=0:
			if k-run_start>best_len:best_len=k-run_start;best_start=run_start
			run_start=-1
	if best_start<0:return
	var t:=(best_start+best_len*.5)/samples
	var p:=Vector2(shared.position.x+shared.size.x*t,shared.get_center().y) if along_x else Vector2(shared.get_center().x,shared.position.y+shared.size.y*t)
	context._passage=Vector3(p.x,(context.floor_y as float),p.y)

static func _around_furniture(context: Node3D, from:Vector3,to:Vector3) -> Vector3:
	if not context.is_inside_tree():return Vector3.INF
	var key:=Vector4(snappedf(from.x,.2),snappedf(from.z,.2),snappedf(to.x,.2),snappedf(to.z,.2))
	var now:=Time.get_ticks_msec()
	if (context._around_cache as Dictionary).has(key) and now-int((context._around_cache as Dictionary)[key][0])<500:return (context._around_cache as Dictionary)[key][1]
	if (context._around_cache as Dictionary).size()>64:(context._around_cache as Dictionary).clear()
	var result:=Vector3.INF
	if (context._blocked_line(from,to) as bool):
		var lanes:=(context._lane_route(from,to) as Array[Vector3])
		var start:=0
		for i in lanes.size():
			if horizontal_distance(from,lanes[i])<.3:start=i+1
		for i in range(lanes.size()-1,start-1,-1):
			if not (context._blocked_line(from,lanes[i]) as bool):result=lanes[i];break
	(context._around_cache as Dictionary)[key]=[now,result]
	return result

static func horizontal_distance(a:Vector3,b:Vector3) -> float:
	return Vector2(a.x-b.x,a.z-b.z).length()

static func _lane_route(context: Node3D, from:Vector3,to:Vector3) -> Array[Vector3]:
	var route:Array[Vector3]=[]
	var from_room:=(context._room_of(from) as int);var to_room:=(context._room_of(to) as int)
	route.append((context._room_centre(from_room) as Vector3) if from_room>=0 else (context.inside() as Vector3))
	if from_room>=0 and to_room>=0 and from_room!=to_room and (context.floors as Array[Rect2]).size()>=2:
		if not (context._passage_done as bool):context._measure_passage()
		var main:Rect2=(context.floors as Array[Rect2])[0];var wing:Rect2=(context.floors as Array[Rect2])[1]
		var via:=(context._passage as Vector3) if (context._passage as Vector3).is_finite() and not (context._passage_open_all as bool) else Vector3(wing.get_center().x,(context.floor_y as float),main.end.y-.09)
		route.append(context.to_global(via))
	if to_room>=0 and (to_room!=from_room or from_room<0):route.append((context._room_centre(to_room) as Vector3))
	return route

static func _room_centre(context: Node3D, room:int) -> Vector3:
	var r:Rect2=(context.floors as Array[Rect2])[room]
	return context.to_global(Vector3(r.get_center().x,(context.floor_y as float),r.get_center().y))

static func _blocked_line(context: Node3D, a:Vector3,b:Vector3) -> bool:
	var level:float=context.to_global(Vector3(0,(context.floor_y as float),0)).y+LINE_CHEST
	var shape:=SphereShape3D.new();shape.radius=LINE_CLEARANCE
	var query:=PhysicsShapeQueryParameters3D.new();query.shape=shape;query.collision_mask=1
	query.transform=Transform3D(Basis.IDENTITY,Vector3(a.x,level,a.z))
	query.motion=Vector3(b.x-a.x,0,b.z-a.z)
	var motion:=context.get_world_3d().direct_space_state.cast_motion(query)
	return motion.size()==2 and motion[0]<.999

static func _room_of(context: Node3D, point:Vector3) -> int:
	var p:=context.to_local(point)
	for i in (context.floors as Array[Rect2]).size():
		if (context.floors as Array[Rect2])[i].grow(.002).has_point(Vector2(p.x,p.z)):return i
	return -1

static func local_waypoint(context: Node3D, from:Vector3,to:Vector3) -> Vector3:
	var around:=(context._around_furniture(from,to) as Vector3)
	if around.is_finite():return around
	# Single rooms always returned the destination, even after 80 containment probes.
	# Keep the same route without rescanning its floor on every navigator tick.
	if (context.floors as Array[Rect2]).size()==1:return to
	if (context.floors as Array[Rect2]).size()>=2 and not (context._passage_done as bool):context._measure_passage()
	var from_room:=(context._room_of(from) as int);var to_room:=(context._room_of(to) as int)
	if (context.floors as Array[Rect2]).size()>=2 and from_room>=0 and to_room>=0 and from_room!=to_room and not (context._passage_open_all as bool) and (context._passage as Vector3).is_finite():
		# Through the opening: line up on this side of it, then step through to the other.
		var into:Vector2=(context.floors as Array[Rect2])[to_room].get_center()-Vector2((context._passage as Vector3).x,(context._passage as Vector3).z)
		var shared:=(context.floors as Array[Rect2])[0].grow(.003).intersection((context.floors as Array[Rect2])[1].grow(.003))
		var normal:=Vector2(signf(into.x),0.0) if shared.size.y>shared.size.x else Vector2(0.0,signf(into.y))
		var step:=.06
		var near_side:=(context._passage as Vector3)-Vector3(normal.x,0,normal.y)*step
		var far_side:=(context._passage as Vector3)+Vector3(normal.x,0,normal.y)*step
		# Once lined up at the opening, keep going through rather than re-aiming at it.
		if context.to_local(from).distance_to((context._passage as Vector3))<step+.03:return context.to_global(far_side)
		return context.to_global(near_side)
	var clear:=true
	# Check body clearance around the inside corner, not only the root point.
	var padding:float=.05*context.global_basis.x.length()
	var frame:=context.global_basis.orthonormalized()
	for i in 20:
		var point:=from.lerp(to,(i+1)/20.0)
		for offset:Vector3 in [Vector3.LEFT,Vector3.RIGHT,Vector3.FORWARD,Vector3.BACK]:
			if not (context.contains(point+frame*offset*padding) as bool):clear=false;break
		if not clear:break
	if clear or (context.floors as Array[Rect2]).size()==1:return to
	# Both present L-shaped houses have a rear main room and a front wing.
	# Bend in the main room, comfortably behind the concave wall corner.
	var main:Rect2=(context.floors as Array[Rect2])[0];var wing:Rect2=(context.floors as Array[Rect2])[1]
	var corner:=Vector3(wing.get_center().x,(context.floor_y as float),main.end.y-.09)
	if context.to_local(from).distance_to(corner)<.025:return to
	return context.to_global(corner)

