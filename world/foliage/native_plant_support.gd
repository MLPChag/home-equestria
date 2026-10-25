class_name NativePlantSupport
extends RefCounted
## Sliced contact reconciliation for imported plants and compact decorative rocks.
const SCALE := preload("res://world/foliage/vegetation_scale.gd")
const BUILDER := preload("res://world/terrain_builder.gd")
const FIXED_META := &"native_support_reconciled_v2"
const MAX_CORRECTION := 128.0
const FLOATING_MARGIN := 0.10
const SOURCE_MARGIN := 5.0
const MAX_ROCK_SPAN := 32.0
const TREE_SUPPORT_META := &"tree_support_y"
const TREE_COLLAR_META := &"tree_collar_offset"
const MAX_SETTLE_SWEEPS := 4
var _scan: Array[Node] = []
var _props: Array[Node3D] = []
var _active: Array[Node3D] = []
var _next := 0
var _collected := false
var _sources: Array[Dictionary] = []
var _records: Dictionary = {}
var _zone_origin := Vector3.ZERO
var _allow_up := false
var visited := 0
var corrections: Array[Dictionary] = []
var support_hits: Array[Dictionary] = []
var diagnostic_hits := false
var _changed := AABB()
var _settling := false
var _settle_frame := -1
var _settle_sweeps := 0
var _moves_since_sweep := false


static func begin(root: Node3D, config: Dictionary = {}, zone_origin := Vector3.ZERO,
		zone_dir := "") -> RefCounted:
	var support_pass: RefCounted = (load("res://world/foliage/native_plant_support.gd") as Script).new()
	support_pass._scan.append(root)
	support_pass._zone_origin = zone_origin
	support_pass._load_sources(config, zone_dir)
	return support_pass


func _load_sources(config: Dictionary, zone_dir: String) -> void:
	for entry in config.get("terrain", []):
		if str(entry.get("mode", "")) != "terrain3d":
			continue
		var meta := BUILDER.load_meta(zone_dir.path_join(str(entry.get("meta", ""))))
		if meta.is_empty():
			continue
		var origin_value: Array = entry.get("origin", [0, 0, 0])
		var origin := _zone_origin + Vector3(float(origin_value[0]),
			float(origin_value[1]) + float(entry.get("y_offset", 0.0)), float(origin_value[2]))
		_sources.append({"meta": meta, "dir": zone_dir, "origin": origin,
			"heights": PackedFloat32Array()})


func advance(space: PhysicsDirectSpaceState3D, terrain: Node, budget_us := 1000) -> bool:
	var started := Time.get_ticks_usec()
	if _settling:
		# Moving a support collider does not become query-visible until the next
		# physics tick. Revisit all retained props after that tick so stacked rocks
		# settle in dependency order instead of preserving a vanished upper support.
		if Engine.get_physics_frames() <= _settle_frame:
			return false
		_settling = false
		_active = _props.duplicate()
		_next = 0
	if not _collected:
		while not _scan.is_empty():
			var node: Node = _scan.pop_back()
			if not is_instance_valid(node):
				continue
			for child in node.get_children():
				_scan.append(child)
			if node is Node3D and _is_candidate(node) and not _is_landmark(str(node.get_path())):
				_props.append(node)
			if Time.get_ticks_usec() - started >= budget_us:
				return false
		_collected = true
		_active = _props.duplicate()
	while _next < _active.size():
		var prop := _active[_next]
		_next += 1
		if is_instance_valid(prop):
			if not _records.has(prop.get_instance_id()):
				visited += 1
			_reconcile(prop, space, terrain)
		if Time.get_ticks_usec() - started >= budget_us:
			return false
	if _has_unstable_support_moves():
		_settling = true
		_settle_frame = Engine.get_physics_frames()
		return false
	return true


func _has_unstable_support_moves() -> bool:
	if not _moves_since_sweep or _settle_sweeps >= MAX_SETTLE_SWEEPS:
		return false
	_moves_since_sweep = false
	_settle_sweeps += 1
	return true

func queue_bounds(bounds: AABB) -> void:
	if not _collected:
		return
	_allow_up = true
	var queued := {}
	var merged: Array[Node3D] = []
	for index in range(_next, _active.size()):
		var pending := _active[index]
		if is_instance_valid(pending):
			queued[pending.get_instance_id()] = true
			merged.append(pending)
	for prop in _props:
		if not is_instance_valid(prop) or queued.has(prop.get_instance_id()):
			continue
		var record: Dictionary = _records.get(prop.get_instance_id(), {})
		if not record.is_empty() and (record.bounds as AABB).intersects(bounds):
			queued[prop.get_instance_id()] = true
			merged.append(prop)
	_active = merged
	_next = 0
	_settle_sweeps = 0
	_moves_since_sweep = false

func pending()->int:return _scan.size()+(_active.size()-_next)+(1 if _settling else 0)
func take_changed_bounds()->AABB:
	var result:=_changed;_changed=AABB();return result

func _reconcile(prop: Node3D, space: PhysicsDirectSpaceState3D, terrain: Node) -> void:
	if _is_plant_root(prop):
		SCALE.refine_groundcover(prop)
	var geometry := _geometry(prop)
	var points: PackedVector3Array = _support_points(prop, geometry)
	if points.is_empty():
		return
	if _is_rock(prop) and maxf(geometry.bounds.size.x, geometry.bounds.size.z) > MAX_ROCK_SPAN:
		return

	var identity := prop.get_instance_id()
	var native_tree := _is_tree_root(prop) and not prop.has_meta(TREE_COLLAR_META) \
		and tree_collar_local(prop).is_finite()
	var previous: Dictionary = _records.get(identity, {})
	var source_attached := _source_attached(points) if previous.is_empty() else bool(previous.source_attached)
	var grounding_confident := source_attached if previous.is_empty() else bool(previous.get("grounding_confident", false))
	geometry.source_attached = source_attached
	geometry.grounding_confident = grounding_confident
	geometry.exclusions = _collision_rids(prop) if previous.is_empty() else previous.exclusions
	_records[identity] = geometry

	var deltas: Array[float] = []
	var root_deltas: Array[float] = []
	var collar_count := 1 if native_tree else 0
	var collar_delta := NAN
	for point_index in points.size():
		var point: Vector3 = points[point_index]
		var hit := _ray_support_hit(point, geometry.exclusions, space)
		var support := float(hit.get("height", NAN))
		if diagnostic_hits and not hit.is_empty() and support_hits.size() < 2048:
			support_hits.append({
				"prop": str(prop.get_path()),
				"point": point,
				"collider": str(hit.get("collider", "")),
				"height": support,
			})
		var ground: float = float(terrain.height_at(point)) if terrain != null and terrain.has_method("height_at") else NAN
		if is_finite(ground) and (not is_finite(support) or ground > support):
			support = ground
		if is_finite(support):
			var point_delta := support - point.y
			deltas.append(point_delta)
			if native_tree and point_index == 0:
				collar_delta = point_delta
			if point_index >= collar_count:
				root_deltas.append(point_delta)
	if deltas.is_empty():
		return

	# A standard decorative prop with every sampled contact floating above final
	# physics/terrain is safe to ground even when its old TerrainData fit was remote.
	# This is persisted so later sculpt edits can move the same prop in either direction.
	var wholly_floating := true
	for value in deltas:
		if value >= -FLOATING_MARGIN:
			wholly_floating = false
			break
	if not grounding_confident:
		for value in deltas:
			if absf(value) <= FLOATING_MARGIN:
				geometry.grounding_confident = true
				_records[identity] = geometry
				grounding_confident = true
				if not native_tree:
					prop.set_meta(FIXED_META, true)
					return
			if value > FLOATING_MARGIN:
				if not native_tree:
					return
		if not wholly_floating:
			if not native_tree:
				return
		grounding_confident = true
		geometry.grounding_confident = true
		_records[identity] = geometry

	# One actual bottom contact preserves a tilted or physically stacked authored prop.
	for value in deltas:
		if absf(value) <= FLOATING_MARGIN:
			if not native_tree:
				prop.set_meta(FIXED_META, true)
				return

	deltas.sort()
	# A collar can sit on a narrow cliff shell while every sampled root remains in
	# open air. In that specific case, lower only until the closest real root reaches
	# support. This seats the root system without forcing downhill roots or asymmetric
	# flares all the way under a slope. On sculpt raises, retain the ordinary rule.
	root_deltas.sort()
	var all_roots_floating := native_tree and not root_deltas.is_empty()
	for value in root_deltas:
		if value >= -FLOATING_MARGIN:
			all_roots_floating = false
			break
	var floating_collar := native_tree and is_finite(collar_delta) and collar_delta < -FLOATING_MARGIN
	var delta: float = collar_delta if floating_collar \
		else (root_deltas.back() if all_roots_floating \
		else (deltas.back() if wholly_floating else deltas[deltas.size() / 2])
		)
	var agreeing := 0
	for value in deltas:
		if absf(value - delta) <= 2.0:
			agreeing += 1
	if (not native_tree and not wholly_floating and agreeing < mini(2, deltas.size())) \
			or absf(delta) <= FLOATING_MARGIN or absf(delta) > MAX_CORRECTION:
		return
	if delta > 0.0 and not _allow_up:
		return

	var before: AABB = geometry.bounds
	prop.global_position += Vector3.UP * delta
	prop.set_meta(FIXED_META, true)
	var after := AABB(before.position + Vector3.UP * delta, before.size)
	_changed = before.merge(after) if _changed.size == Vector3.ZERO else _changed.merge(before).merge(after)
	geometry.bounds = after
	_records[identity] = geometry
	_record_correction(str(prop.get_path()), "rock" if _is_rock(prop) else "plant", delta)
	if native_tree:
		_settle_native_tree_roots(prop, geometry.exclusions, space, terrain)
	elif _is_rock(prop):
		_settle_compact_rock(prop, geometry.exclusions, space, terrain)


func _settle_native_tree_roots(prop: Node3D, exclusions: Array[RID],
		space: PhysicsDirectSpaceState3D, terrain: Node) -> void:
	var geometry := _geometry(prop)
	var roots: PackedVector3Array = geometry.points
	if roots.is_empty():
		return
	var collar_local := tree_collar_local(prop)
	if not collar_local.is_finite():
		return
	var collar: Vector3 = prop.global_transform * collar_local
	var reach := 0.0
	var deltas: Array[float] = []
	for root_index in roots.size():
		var point: Vector3 = roots[root_index]
		reach = maxf(reach, point.distance_to(collar))
		for other_index in range(root_index):
			reach = maxf(reach, point.distance_to(roots[other_index]))
		var hit := _ray_support_hit(point, exclusions, space)
		var support := float(hit.get("height", NAN))
		var ground: float = float(terrain.height_at(point)) \
			if terrain != null and terrain.has_method("height_at") else NAN
		if is_finite(ground) and (not is_finite(support) or ground > support):
			support = ground
		if is_finite(support):
			deltas.append(support - point.y)
	if deltas.is_empty():
		return
	# Additional seating is allowed only when every actual low-root sample is in
	# open air. Reach bounds the move to this tree's measured root geometry.
	for value in deltas:
		if value >= -FLOATING_MARGIN:
			return
	deltas.sort()
	var delta := float(deltas.back())
	if absf(delta) <= FLOATING_MARGIN or absf(delta) > minf(MAX_CORRECTION, reach + FLOATING_MARGIN):
		return
	var before: AABB = geometry.bounds
	prop.global_position += Vector3.UP * delta
	prop.set_meta(FIXED_META, true)
	var after := AABB(before.position + Vector3.UP * delta, before.size)
	_changed = before.merge(after) if _changed.size == Vector3.ZERO else _changed.merge(before).merge(after)
	var identity := prop.get_instance_id()
	var record: Dictionary = _records.get(identity, {})
	record.bounds = after
	_records[identity] = record
	var path := str(prop.get_path())
	_record_correction(path, "plant", delta)


func _settle_compact_rock(prop: Node3D, exclusions: Array[RID],
		space: PhysicsDirectSpaceState3D, terrain: Node) -> void:
	var geometry := _geometry(prop)
	var deltas: Array[float] = []
	for point: Vector3 in geometry.points:
		var hit := _ray_support_hit(point, exclusions, space)
		var support := float(hit.get("height", NAN))
		var ground: float = float(terrain.height_at(point)) \
			if terrain != null and terrain.has_method("height_at") else NAN
		if is_finite(ground) and (not is_finite(support) or ground > support):
			support = ground
		if is_finite(support):
			deltas.append(support - point.y)
	if deltas.is_empty():
		return
	# A compact rock may first touch an overlapping decorative rock while its whole
	# base remains above the final terrain. Settle once more only in that unambiguous
	# case; a single real platform/base contact preserves the authored placement.
	for value in deltas:
		if value >= -FLOATING_MARGIN:
			return
	deltas.sort()
	var delta := float(deltas.back())
	if absf(delta) <= FLOATING_MARGIN or absf(delta) > MAX_CORRECTION:
		return
	var before: AABB = geometry.bounds
	prop.global_position += Vector3.UP * delta
	prop.set_meta(FIXED_META, true)
	var after := AABB(before.position + Vector3.UP * delta, before.size)
	_changed = before.merge(after) if _changed.size == Vector3.ZERO else _changed.merge(before).merge(after)
	var identity := prop.get_instance_id()
	var record: Dictionary = _records.get(identity, {})
	record.bounds = after
	_records[identity] = record
	var path := str(prop.get_path())
	_record_correction(path, "rock", delta)


func _record_correction(path: String, kind: String, delta: float) -> void:
	_moves_since_sweep = true
	for correction: Dictionary in corrections:
		if str(correction.path) == path:
			correction.delta = float(correction.delta) + delta
			return
	corrections.append({"path": path, "kind": kind, "delta": delta})

func _geometry(prop:Node3D)->Dictionary:
	var vertices:=PackedVector3Array();var bounds:=AABB();var found:=false
	var meshes:Array[Node]=[prop];meshes.append_array(prop.find_children("*","MeshInstance3D",true,false))
	for item in meshes:
		var mi:=item as MeshInstance3D
		if mi==null or mi.mesh==null or not mi.visible:continue
		var box:=mi.global_transform*mi.get_aabb();bounds=box if not found else bounds.merge(box);found=true
		for surface in mi.mesh.get_surface_count():
			var arrays:=mi.mesh.surface_get_arrays(surface)
			if arrays.size()>Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
				for vertex in arrays[Mesh.ARRAY_VERTEX]:vertices.append(mi.global_transform*vertex)
	var points:=PackedVector3Array()
	if not found or vertices.is_empty():return {"bounds":bounds,"points":points}
	var minimum:=INF
	for vertex in vertices:minimum=minf(minimum,vertex.y)
	var candidates:=PackedVector3Array();var threshold:=minimum+maxf(.2,bounds.size.y*.025)
	for vertex in vertices:
		if vertex.y<=threshold:candidates.append(vertex)
	for direction in [Vector2(-1,0),Vector2(1,0),Vector2(0,-1),Vector2(0,1),Vector2.ZERO]:
		var best:=Vector3(NAN,NAN,NAN);var score:=-INF
		for point in candidates:
			var value:=Vector2(point.x,point.z).dot(direction) if direction!=Vector2.ZERO else -Vector2(point.x,point.z).distance_squared_to(Vector2(bounds.get_center().x,bounds.get_center().z))
			if value>score:score=value;best=point
		if best.is_finite() and not points.has(best):points.append(best)
	return {"bounds":bounds,"points":points}


func _support_points(prop: Node3D, geometry: Dictionary) -> PackedVector3Array:
	if not _is_tree_root(prop):
		return geometry.points
	# Tree roots are intentionally below grade. Reconciliation therefore samples
	# the authored trunk collar, not the lowest root tips used for bushes/rocks.
	# Approved replacements store the collar in their recentered asset. Native
	# Everfree prefab roots do not consistently share the trunk's XZ: Tree01's
	# authored trunk is about 75 m from its wrapper origin. Derive that transition
	# from the actual transformed trunk ring instead of ray-casting below the wrapper.
	var local_support := Vector3.ZERO
	var measured := Vector3(NAN, NAN, NAN)
	if prop.has_meta(TREE_COLLAR_META):
		local_support = prop.get_meta(TREE_COLLAR_META) as Vector3
	else:
		measured = tree_collar_local(prop)
		if measured.is_finite():
			local_support = measured
		else:
			local_support.y = float(prop.get_meta(TREE_SUPPORT_META, 0.0))
	var result := PackedVector3Array([prop.global_transform * local_support])
	# Native roots can span several metres across sloped ground. Their transformed
	# lowest vertices are a secondary exposure guard; the collar remains the primary
	# anatomical reference and is the point used on ordinary ground.
	if not prop.has_meta(TREE_COLLAR_META) and measured.is_finite():
		for point: Vector3 in geometry.points:
			if not result.has(point):
				result.append(point)
	return result


## Returns the centre of the authored trunk/root transition in `prop` coordinates.
## Everfree trunk meshes cross local Y=0 where the visible trunk meets its root flare;
## averaging a narrow ring is stable across their asymmetric decorative root tips.
## `initial_basis` lets the catalogue extractor measure the same point after applying
## the source instance's complete inherited rotation and scale.
static func tree_collar_local(prop: Node3D, initial_basis := Basis.IDENTITY) -> Vector3:
	var stack: Array = [[prop, Transform3D(initial_basis, Vector3.ZERO)]]
	var trunk_points := PackedVector3Array()
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var node: Node = item[0]
		var transform: Transform3D = item[1]
		if node is Node3D and not (node as Node3D).visible:
			continue
		if node is MeshInstance3D and node.mesh != null \
				and str(node.name).to_lower().contains("trunk"):
			for surface in node.mesh.get_surface_count():
				var arrays: Array = node.mesh.surface_get_arrays(surface)
				if arrays.size() <= Mesh.ARRAY_VERTEX \
						or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
					continue
				for vertex: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
					trunk_points.append(transform * vertex)
		for child in node.get_children():
			stack.append([child, transform * child.transform if child is Node3D else transform])
	if trunk_points.is_empty():
		return Vector3(NAN, NAN, NAN)
	var ring := PackedVector3Array()
	for point in trunk_points:
		if absf(point.y) <= 0.25:
			ring.append(point)
	if ring.is_empty():
		return Vector3(NAN, NAN, NAN)
	var collar := Vector3.ZERO
	for point in ring:
		collar += point
	collar /= ring.size()
	# Y=0 is the authored anatomy boundary. Sampling the lowest vertices would put
	# deliberately buried roots on top of the ground again.
	collar.y = 0.0
	return collar

func _source_attached(points:PackedVector3Array)->bool:
	for point in points:
		for source in _sources:
			var origin:Vector3=source.origin;var meta:Dictionary=source.meta
			var u:=(origin.x-point.x)/float(meta.size_x);var v:=(point.z-origin.z)/float(meta.size_z)
			if u<0 or u>1 or v<0 or v>1:continue
			var heights:PackedFloat32Array=source.heights
			if heights.is_empty():heights=BUILDER.load_heights(source.dir,meta);source.heights=heights
			var y:=origin.y+BUILDER.sample_norm(heights,int(meta.resolution),u,v)*float(meta.height_scale)
			if absf(point.y-y)<=SOURCE_MARGIN:return true
	return false

func _collision_rids(prop:Node3D)->Array[RID]:
	var result:Array[RID]=[]
	for body in prop.find_children("*","CollisionObject3D",true,false):
		result.append((body as CollisionObject3D).get_rid())
	return result

func _ray_support_hit(point:Vector3,exclude:Array[RID],space:PhysicsDirectSpaceState3D)->Dictionary:
	if space==null:return {}
	var query:=PhysicsRayQueryParameters3D.create(point+Vector3.UP*.5,point+Vector3.DOWN*MAX_CORRECTION)
	query.collision_mask=1;query.collide_with_areas=false;query.exclude=exclude
	for attempt in 4:
		var hit:=space.intersect_ray(query)
		if hit.is_empty():return {}
		var collider:Variant=hit.get("collider")
		if not _has_plant_ancestor(collider):
			return {"height":float(hit.position.y),"collider":str(collider.get_path()) if collider is Node else str(collider)}
		# Another tree's trunk/canopy is not ground. Allocate an expanded exclusion
		# only on this uncommon retry path, then continue toward terrain or a rock.
		query.exclude=query.exclude.duplicate()
		query.exclude.append((collider as CollisionObject3D).get_rid())
	return {}

static func _has_plant_ancestor(value: Variant) -> bool:
	var node := value as Node
	while node != null:
		if node is Node3D and _is_plant_root(node):
			return true
		node = node.get_parent()
	return false

## Compatibility for the offline audit. This is the lowest transformed geometry sample,
## rather than the old root-XZ AABB estimate.
func _visual_base(prop:Node3D)->Vector3:
	var geometry:=_geometry(prop);var points:PackedVector3Array=geometry.points
	if points.is_empty():return Vector3(NAN,NAN,NAN)
	var best:=points[0]
	for point in points:
		if point.y<best.y:best=point
	return best

static func _is_candidate(node:Node3D)->bool:return _is_plant_root(node) or _is_rock(node)
static func _is_tree_root(node: Node3D) -> bool:
	if node.has_meta(&"grassy_tree_variant"): return true
	var name := str(node.name).to_lower()
	return name.begins_with("everfreetree") or name.begins_with("tree0") or name.begins_with("cactus")
static func _is_rock(node:Node3D)->bool:
	var name:=str(node.name).to_lower();return node is MeshInstance3D and (name.begins_with("rock0") or name=="rock")
static func _is_plant_root(node:Node3D)->bool:
	if node.has_meta(&"grassy_tree_variant"): return true
	var name:=str(node.name).to_lower()
	if name.contains("lod") or (name.contains("_") and not node.has_meta(SCALE.APPLIED_META)):return false
	if not (name.begins_with("everfreetree") or name.begins_with("tree0") or name.begins_with("everfreebush") or name.begins_with("bush") or name.begins_with("fern") or name.begins_with("brambles") or name.contains("thorn") or name.begins_with("cactus")):return false
	var parent:=node.get_parent()
	while parent!=null:
		var ancestor:=str(parent.name).to_lower()
		if ancestor.begins_with("everfreetree") or ancestor.begins_with("tree0") or ancestor.begins_with("everfreebush") or ancestor.begins_with("bush") or ancestor.begins_with("fern") or ancestor.begins_with("brambles") or ancestor.contains("thorn") or ancestor.begins_with("cactus"):return false
		parent=parent.get_parent()
	return true
static func _is_landmark(path:String)->bool:
	var lower:=path.to_lower();return lower.contains("zecora") or lower.contains("hut") or lower.contains("bridge") or lower.contains("entrance") or lower.contains("mountain") or lower.contains("landscapeaddon") or lower.contains("rootcluster")
