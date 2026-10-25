extends RefCounted
## A separate query layer for pony heads; unrelated player/body collisions stay unchanged.
const LAYER:=1<<20
var shape:=SphereShape3D.new()
var query:=PhysicsShapeQueryParameters3D.new()

func _init(mask:int=LAYER)->void:
	query.shape=shape;query.collision_mask=mask;query.margin=.001

func project(space:PhysicsDirectSpaceState3D,from:Vector3,to:Vector3,radius:float,exclude:Array[RID]=[])->Vector3:
	if not from.is_finite() or not to.is_finite():return to
	shape.radius=radius;query.exclude=exclude
	var result:=to
	query.transform=Transform3D(Basis.IDENTITY,from);query.motion=to-from
	if from.distance_to(to)<1.0 and not from.is_equal_approx(to):
		var fractions:=space.cast_motion(query)
		if fractions.size()>0 and fractions[0]<1.0:result=from+(to-from)*fractions[0]
	query.motion=Vector3.ZERO
	return _depenetrate(space,result)

## Collide-and-slide for hands on a coat (dev 2026-09-28: petting hands got caught). From a
## clear point toward `to`, the sphere glides along whatever it meets instead of stopping at the
## first touch; it never passes into the body. Then out of any overlap from moving hulls.
func slide(space:PhysicsDirectSpaceState3D,from:Vector3,to:Vector3,radius:float,exclude:Array[RID]=[])->Vector3:
	if not from.is_finite() or not to.is_finite():return to
	shape.radius=radius;query.exclude=exclude
	var at:=from
	var motion:=to-from
	# A tracking jump or teleport: resolve at the target rather than sweep across the world.
	if motion.length()>=1.0:
		at=to;motion=Vector3.ZERO
	for step:int in 3:
		if motion.length_squared()<.00000001:break
		query.transform=Transform3D(Basis.IDENTITY,at);query.motion=motion
		var fractions:=space.cast_motion(query)
		var free:float=fractions[0] if fractions.size()>0 else 1.0
		at+=motion*free
		if free>=1.0:break
		query.motion=Vector3.ZERO
		shape.radius=radius+.002;query.transform.origin=at
		var rest:=space.get_rest_info(query)
		shape.radius=radius
		if rest.is_empty():break
		var normal:Vector3=rest.normal
		if normal.dot(motion)>0.0:normal=-normal
		at+=normal*.0005
		# Keep the part of the remaining motion along the surface; drop the part into it.
		var left:=motion*(1.0-free)
		motion=left-normal*minf(0.0,left.dot(normal))
	query.motion=Vector3.ZERO
	return _depenetrate(space,at)

## cast_motion ignores initial overlaps; resolve those separately (moving/carried heads, hulls).
func _depenetrate(space:PhysicsDirectSpaceState3D,result:Vector3)->Vector3:
	for iteration:int in 4:
		query.transform=Transform3D(Basis.IDENTITY,result)
		var contacts:=space.collide_shape(query,8)
		var push:=Vector3.ZERO
		for i:int in range(0,contacts.size()-1,2):
			var delta:Vector3=contacts[i+1]-contacts[i]
			if delta.length_squared()>push.length_squared():push=delta
		if push.length_squared()<.00000001:break
		result+=push+push.normalized()*.001
	return result

func touching(space:PhysicsDirectSpaceState3D,point:Vector3,radius:float)->Dictionary:
	shape.radius=radius;query.exclude=[];query.transform=Transform3D(Basis.IDENTITY,point);query.motion=Vector3.ZERO
	return space.get_rest_info(query)
