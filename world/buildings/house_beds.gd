extends RefCounted
## house beds extracted from house_interior.gd.
## State and callback dispatch stay on the owning instance; authored transforms and order are unchanged.

const BED := preload("res://world/props/ponyville/pony_bed.scn")
const BED_SIZE:=Vector3(2.05,1.1,2.1)


static func _place_bed(context: Node3D) -> void:
	if (context.floors as Array[Rect2]).is_empty() or is_instance_valid((context.bed as Node3D)):return
	# Towns are staged off-tree and attached later: place the bed once it is really in the world.
	if not context.is_inside_tree():
		if not context.tree_entered.is_connected(context._place_bed):context.tree_entered.connect(context._place_bed.call_deferred,CONNECT_ONE_SHOT)
		return
	# The wall test needs this house's collision in the physics world; wait for it.
	var probe:=PhysicsRayQueryParameters3D.create((context.center() as Vector3)+Vector3.UP,(context.center() as Vector3)+Vector3.DOWN,1)
	if context.get_world_3d().direct_space_state.intersect_ray(probe).is_empty():
		context._bed_tries+=1
		if (context._bed_tries as int)<10:context.get_tree().create_timer(2.0).timeout.connect(context._place_bed)
		else:context._bed_settled=true;context._furnish_when_ready.call_deferred()
		return
	context.bed = (context._create_bed(0) as Node3D)
	context._bed_settled=true
	context._furnish_when_ready.call_deferred()

static func _create_bed(context: Node3D, index: int) -> Node3D:
	var candidates:=(context._bed_candidates() as Array)
	var rng:=RandomNumberGenerator.new();rng.seed=hash((context.place_id() as String) if index == 0 else (context.place_id() as String) + ":" + str(index))
	var design:=context.get_parent().scene_file_path
	var taken:Dictionary=(context._design_spots as Dictionary).get(design,{})
	for c:Dictionary in candidates:
		if taken.has(c.slot):c.weight*=.05
	# Keep shared bedrooms grouped at corners before taking the middle of a wall,
	# where a kitchen counter needs a continuous stretch. Preserve seeded variety
	# within each group; middle-wall positions remain available as a fallback.
	var fallback: Array = []
	if index > 0:
		for c: Dictionary in candidates:
			if not str(c.slot).contains("corner"): fallback.append(c)
		candidates = candidates.filter(func(c: Dictionary) -> bool: return str(c.slot).contains("corner"))
		if candidates.is_empty():
			candidates = fallback
			fallback = []
	while not candidates.is_empty():
		var total:=0.0
		for c:Dictionary in candidates:total+=c.weight
		var roll:=rng.randf()*total;var pick:=0
		for i in candidates.size():
			roll-=candidates[i].weight
			if roll<=0.0:pick=i;break
		var chosen:Dictionary=candidates[pick];candidates.remove_at(pick)
		if candidates.is_empty() and not fallback.is_empty():
			candidates = fallback
			fallback = []
		var fitted:Variant=context._snug(chosen.xf,str(chosen.slot).contains("corner"))
		if fitted==null:continue
		if not _door_relaxed and _blocks_door(context, fitted): continue
		if not (context._clear_other_beds(fitted, false) as bool): continue
		var existing: Array[Node3D] = (context._extra_beds as Array[Node3D]).duplicate()
		if is_instance_valid((context.bed as Node3D)): existing.append((context.bed as Node3D))
		var reserved: Array[Transform3D] = []
		for other: Node3D in existing:
			if is_instance_valid(other): reserved.append(other.global_transform)
		var side:Variant=context._pick_bed_side(fitted, reserved)
		if side==null:continue
		# An existing bed need not keep its first-choice side forever: a second bed
		# can leave a clear foot-end exit even when the space between them is narrow.
		var access_updates: Dictionary = {}
		var accessible: bool = true
		for other: Node3D in existing:
			if not is_instance_valid(other): continue
			var at: Vector3 = other.global_transform * Vector3(other.get_meta("side_local"))
			var candidate_bed: Array[Transform3D] = [fitted]
			if (context._bed_access_clear(at, candidate_bed) as bool): continue
			var obstacles: Array[Transform3D] = [fitted]
			for neighbour: Node3D in existing:
				if is_instance_valid(neighbour) and neighbour != other: obstacles.append(neighbour.global_transform)
			var alternative: Variant = context._pick_bed_side(other.global_transform, obstacles)
			if alternative == null:
				accessible = false
				break
			access_updates[other] = alternative
		if not accessible: continue
		# Set the pose before it enters the tree: added under the (x10) house and moved after,
		# Jolt kept the house scale on the bed's collision, a ~19 m invisible box (2026-09-26).
		var added: Node3D = BED.instantiate()
		added.transform=(context.get_parent() as Node3D).global_transform.affine_inverse()*fitted
		context.get_parent().add_child(added)
		added.global_transform=fitted
		added.set_meta("house",context);added.set_meta("slot",chosen.slot)
		# The same mattress height the rest helpers already assume; it also makes every house bed
		# a place to lie down and cuddle in VR (seating.gd _bed_seat, dev 2026-09-28).
		added.set_meta("mattress_top",.6)
		taken[chosen.slot]=true;(context._design_spots as Dictionary)[design]=taken
		added.set_meta("side_local",side)
		for other: Node3D in access_updates:
			other.set_meta("side_local", access_updates[other])
		return added
	if not _door_relaxed:
		# Every spot sits in the door's swing: a bed there beats no bed at all.
		_door_relaxed = true
		var anyway := _create_bed(context, index)
		_door_relaxed = false
		return anyway
	print("[house] no clear spot for bed %d in %s" % [index + 1, context.get_parent().name])
	return null

static func _clear_other_beds(context: Node3D, xf: Transform3D, check_access: bool = true) -> bool:
	var existing: Array = (context._extra_beds as Array[Node3D]).duplicate()
	if is_instance_valid((context.bed as Node3D)): existing.append((context.bed as Node3D))
	for other: Node3D in existing:
		if not is_instance_valid(other): continue
		var old: Transform3D = other.global_transform
		var apart := false
		for axis: Vector3 in [xf.basis.x, xf.basis.z, old.basis.x, old.basis.z]:
			var a := absf(axis.dot(xf.basis.x)) * BED_SIZE.x * .5 + absf(axis.dot(xf.basis.z)) * BED_SIZE.z * .5
			var b := absf(axis.dot(old.basis.x)) * BED_SIZE.x * .5 + absf(axis.dot(old.basis.z)) * BED_SIZE.z * .5
			if absf(axis.dot(old.origin - xf.origin)) > a + b + .12: apart = true
		if not apart: return false
		var candidate_bed: Array[Transform3D] = [xf]
		if check_access and not (context._bed_access_clear(old * Vector3(other.get_meta("side_local")), candidate_bed) as bool): return false
	return true

static func _bed_access_clear(context: Node3D, at: Vector3, reserved: Array[Transform3D]) -> bool:
	for xf: Transform3D in reserved:
		var local: Vector3 = xf.affine_inverse() * at
		if absf(local.x) < BED_SIZE.x * .5 + .35 and absf(local.z) < BED_SIZE.z * .5 + .35: return false
	return true

static func _bed_candidates(context: Node3D) -> Array:
	var s:=context.global_basis.x.length()
	var width:=BED_SIZE.x/s;var length:=BED_SIZE.z/s;var margin:=.03/s
	var door_world:=context.to_global((context.doorway as Vector3))
	var out:=[]
	for r in (context.floors as Array[Rect2]).size():
		var rect:Rect2=(context.floors as Array[Rect2])[r]
		for wall in 4:
			var n:Vector2=[Vector2(0,1),Vector2(0,-1),Vector2(1,0),Vector2(-1,0)][wall]
			var t:=Vector2(n.y,n.x).abs()
			var along_from:=rect.position.x if t.x>0 else rect.position.y
			var along_to:=rect.end.x if t.x>0 else rect.end.y
			var line:=(rect.position.y if n.y>0 else rect.end.y) if n.x==0 else (rect.position.x if n.x>0 else rect.end.x)
			if along_to-along_from<width+2*margin:continue
			var lo:=along_from+width*.5+margin;var hi:=along_to-width*.5-margin
			for slot in ["corner_a","corner_b","wall_30","wall_50","wall_70"]:
				var along:float={"corner_a":lo,"corner_b":hi,"wall_30":lerpf(lo,hi,.3),"wall_50":lerpf(lo,hi,.5),"wall_70":lerpf(lo,hi,.7)}[slot]
				var at:=(Vector2(along,line) if n.x==0 else Vector2(line,along))+n*(length*.5+margin)
				var toward:=(context.global_basis.orthonormalized()*Vector3(n.x,0,n.y)).normalized()
				var xf:=Transform3D(Basis.looking_at(-toward,Vector3.UP),context.to_global(Vector3(at.x,(context.floor_y as float),at.y)))
				if not (context._bed_on_floor(xf) as bool):continue
				var door:=xf.affine_inverse()*door_world
				var gap:=Vector2(maxf(absf(door.x)-BED_SIZE.x*.5,0.0),maxf(absf(door.z)-BED_SIZE.z*.5,0.0)).length()
				if gap<1.4:continue
				# Nor beside the doorway's walking line in to the inside point: house G's bed stood
				# 1.4 m from the doorway yet pinned ponies walking in (dev: ponies stuck at the
				# doors of some houses). Keep 60 cm between the bed and that whole line.
				var line_blocked:=false
				for f:float in [0.0,0.25,0.5,0.75,1.0]:
					var q:=xf.affine_inverse()*door_world.lerp((context.inside() as Vector3),f)
					if Vector2(maxf(absf(q.x)-BED_SIZE.x*.5,0.0),maxf(absf(q.z)-BED_SIZE.z*.5,0.0)).length()<.6:line_blocked=true;break
				if line_blocked:continue
				# Nor in the opening between the room and its wing (house C's bed blocked it).
				if (context.floors as Array[Rect2]).size()>=2:
					var shared:=(context.floors as Array[Rect2])[0].grow(.003).intersection((context.floors as Array[Rect2])[1].grow(.003))
					if shared.size!=Vector2.ZERO:
						# Keep 60 cm between the bed and every point along the opening.
						var along_x:=shared.size.x>shared.size.y
						var blocks:=false
						for f in [0.1,0.3,0.5,0.7,0.9]:
							var q:=Vector2(lerpf(shared.position.x,shared.end.x,f),shared.get_center().y) if along_x else Vector2(shared.get_center().x,lerpf(shared.position.y,shared.end.y,f))
							var wing:=xf.affine_inverse()*context.to_global(Vector3(q.x,(context.floor_y as float),q.y))
							if Vector2(maxf(absf(wing.x)-BED_SIZE.x*.5,0.0),maxf(absf(wing.z)-BED_SIZE.z*.5,0.0)).length()<.6:blocks=true;break
						if blocks:continue
				# Corners (a long side on a wall) are the usual choice; the middle of a wall is rarer.
				out.append({"xf":xf,"weight":5.0 if slot.begins_with("corner") else .5,"slot":"%d:%d:%s"%[r,wall,slot]})
	return out

static func _wall_distance(context: Node3D, xf:Transform3D,direction:Vector3,exclude:Array[RID]=[]) -> float:
	var sideways:=absf(direction.x)>.5
	var shape:=BoxShape3D.new()
	shape.size=Vector3(.04,.7,BED_SIZE.z-.1) if sideways else Vector3(BED_SIZE.x-.1,.7,.04)
	var query:=PhysicsShapeQueryParameters3D.new();query.shape=shape;query.collision_mask=1;query.exclude=exclude
	query.transform=xf*Transform3D(Basis.IDENTITY,Vector3.UP*.5)
	query.motion=xf.basis*direction*4.0
	var result:=context.get_world_3d().direct_space_state.cast_motion(query)
	if result.size()<2 or result[0]>=1.0:return INF
	return result[0]*4.0+.02

static func _snug(context: Node3D, xf:Transform3D,corner:bool) -> Variant:
	var gap:=.03
	# floor_y is the navigation floor; the visible slab can sit higher. Stand on the slab.
	var down:=context.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(xf.origin+Vector3.UP*1.5,xf.origin+Vector3.DOWN*.5,1))
	if down.is_empty() or down.normal.y<.9:return null
	if absf(float(down.position.y) - (context.center() as Vector3).y) > .3: return null
	xf.origin.y=down.position.y
	var head:=(context._wall_distance(xf,Vector3.FORWARD) as float)
	if head==INF or head>BED_SIZE.z*.5+.6:return null
	xf.origin+=xf.basis*Vector3(0,0,-(head-BED_SIZE.z*.5-gap))
	var away:=Vector3.ZERO
	if corner:
		var left:=(context._wall_distance(xf,Vector3.LEFT) as float)
		var right:=(context._wall_distance(xf,Vector3.RIGHT) as float)
		var side:=-1.0 if left<right else 1.0
		var distance:=minf(left,right)
		if distance>BED_SIZE.x*.5+.6:return null
		xf.origin+=xf.basis*Vector3(side*(distance-BED_SIZE.x*.5-gap),0,0)
		away=Vector3(-side,0,0)
		# Sliding sideways can change what is behind the headboard: close up again.
		head=(context._wall_distance(xf,Vector3.FORWARD) as float)
		if head==INF or head>BED_SIZE.z*.5+.6:return null
		xf.origin+=xf.basis*Vector3(0,0,-(head-BED_SIZE.z*.5-gap))
	for step in 6:
		if (context.bed_clear(xf) as bool) and (context._bed_on_floor(xf,.12) as bool):return xf
		xf.origin+=xf.basis*((Vector3.BACK+away).normalized()*.03)
	return null

static func _bed_on_floor(context: Node3D, xf:Transform3D,slack:=0.0) -> bool:
	for x in [-.5,0.0,.5]:
		for z in [-.5,0.0,.5]:
			var p:=context.to_local(xf*Vector3(x*BED_SIZE.x*.98,0,z*BED_SIZE.z*.98))
			var inside:=false
			for rect:Rect2 in (context.floors as Array[Rect2]):
				if rect.grow(.0005+slack/context.global_basis.x.length()).has_point(Vector2(p.x,p.z)):inside=true;break
			if not inside:return false
	return true

static func bed_clear(context: Node3D, xf:Transform3D,exclude:Array[RID]=[]) -> bool:
	var shape:=BoxShape3D.new();shape.size=Vector3(BED_SIZE.x-.04,BED_SIZE.y-.12,BED_SIZE.z-.04)
	var query:=PhysicsShapeQueryParameters3D.new();query.shape=shape;query.collision_mask=1;query.exclude=exclude
	query.transform=xf*Transform3D(Basis.IDENTITY,Vector3(0,.1+shape.size.y*.5,0))
	return context.get_world_3d().direct_space_state.intersect_shape(query,1).is_empty()

static func _pick_bed_side(context: Node3D, xf:Transform3D, reserved: Array[Transform3D] = []) -> Variant:
	var shape:=SphereShape3D.new();shape.radius=.3
	var query:=PhysicsShapeQueryParameters3D.new();query.shape=shape;query.collision_mask=1
	for local:Vector3 in [Vector3(BED_SIZE.x*.5+.55,0,.25),Vector3(-BED_SIZE.x*.5-.55,0,.25),Vector3(BED_SIZE.x*.5+.55,0,.7),Vector3(-BED_SIZE.x*.5-.55,0,.7),Vector3(0,0,BED_SIZE.z*.5+.6)]:
		var at:=xf*local
		if not (context._bed_access_clear(at, reserved) as bool): continue
		query.transform=Transform3D(Basis.IDENTITY,at+Vector3.UP*.45)
		if (context.contains(at+Vector3.UP*.01) as bool) and context.get_world_3d().direct_space_state.intersect_shape(query,1).is_empty():return local
	return null

static func _bed_index(context: Node3D, id: String) -> int:
	return maxi(0, (context._sleepers as Array).find(id)) / 2

static func ensure_bed(context: Node3D, id: String = "") -> Node3D:
	if not is_instance_valid((context.bed as Node3D)):context._place_bed()
	if not is_instance_valid((context.bed as Node3D)): return null
	var index := (context._bed_index(id) as int)
	while (context._extra_beds as Array[Node3D]).size() < index:
		if Time.get_ticks_msec() < (context._bed_retry_at as int): return null
		var extra := (context._create_bed((context._extra_beds as Array[Node3D]).size() + 1) as Node3D)
		if extra == null:
			context._bed_retry_at = Time.get_ticks_msec() + 10000
			return null
		(context._extra_beds as Array[Node3D]).append(extra)
	return (context.bed as Node3D) if index == 0 else (context._extra_beds as Array[Node3D])[index - 1]

static func bed_shared(context: Node3D, id: String) -> bool:
	return not id.is_empty() and (context._sleepers as Array).size() > (context._bed_index(id) as int) * 2 + 1

static func bed_side(context: Node3D, id: String = "") -> Vector3:
	var target := (context.ensure_bed(id) as Node3D)
	if target == null:return Vector3.INF
	return target.global_transform*Vector3(target.get_meta("side_local",Vector3(0,0,BED_SIZE.z*.5+.6)))

static func bed_rest(context: Node3D, id: String = "") -> Transform3D:
	var target := (context.ensure_bed(id) as Node3D)
	if target == null: return Transform3D(Basis.IDENTITY, Vector3.INF)
	var top:float=target.get_meta("mattress_top",.6)
	var lane := 0.0
	if (context.bed_shared(id) as bool): lane = -.48 if (context._sleepers as Array).find(id) % 2 == 0 else .48
	return Transform3D(Basis.looking_at(-target.global_basis.z,Vector3.UP),target.global_position+Vector3.UP*top+target.global_basis.z*.15+target.global_basis.x*lane)

static func on_mattress(context: Node3D, point: Vector3, id: String = "") -> bool:
	var target := (context.ensure_bed(id) as Node3D)
	if target == null: return false
	var local := target.to_local(point)
	var top: float = target.get_meta("mattress_top", .6)
	var size: Vector3 = target.get_meta("bed_size", BED_SIZE)
	return absf(point.y - target.global_position.y - top) <= .4 and absf(local.x) < size.x * .5 + .12 \
		and absf(local.z) < size.z * .5 + .12

## The front door swings through this bed spot (dev 2026-10-14: in house C the door opened into the
## bed). The leaf's outline at 0..90 degrees about its hinge (hinged_door.gd) against the bed's
## footprint, both in world XZ, with a 4 cm gap.
## True during the fallback pass of _create_bed that may block the door swing.
static var _door_relaxed := false
static func _blocks_door(context: Node3D, xf: Transform3D) -> bool:
	var leaf := context.door() as Node3D
	if leaf == null or leaf.get_parent() == null: return false
	var box: AABB = leaf.get("navigation_box")
	if not box.has_volume(): return false
	var parent: Transform3D = (leaf.get_parent() as Node3D).global_transform
	var right := xf.basis.x.normalized() * BED_SIZE.x * .5
	var ahead := xf.basis.z.normalized() * BED_SIZE.z * .5
	var bed := PackedVector2Array()
	for corner: Vector3 in [xf.origin - right - ahead, xf.origin + right - ahead, xf.origin + right + ahead, xf.origin - right + ahead]:
		bed.append(Vector2(corner.x, corner.z))
	for step in 11:
		var turn := Basis(Vector3.UP, PI * .5 * float(step) / 10.0 * float(leaf.get("swing_direction")))
		var outline := PackedVector2Array()
		for corner: Vector3 in [box.position, Vector3(box.end.x, box.position.y, box.position.z), Vector3(box.end.x, box.position.y, box.end.z), Vector3(box.position.x, box.position.y, box.end.z)]:
			var at: Vector3 = parent * (leaf.position + turn * corner)
			outline.append(Vector2(at.x, at.z))
		var grown := Geometry2D.offset_polygon(outline, .04)
		if not Geometry2D.intersect_polygons(bed, grown[0] if not grown.is_empty() else outline).is_empty(): return true
	return false

