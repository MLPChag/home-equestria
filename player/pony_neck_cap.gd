extends RefCounted
## Close the player's hidden-head opening with the body's own skinned rim.
## Built once on attachment; no shared mesh edits or per-frame geometry work.
##
## Why the edge kept coming back (card #32, dev 2026-10-15 "neck cut off"): the grafted head
## starts exactly at this rim, at the head joint ~18 cm below and ~17 cm behind the eye, and the
## head pitches down with the view. Hiding the head therefore always shows the open rim; the
## sphere and then this flat fan only plugged the hole, the cut edge stayed in view. The shared
## body cannot be reshaped there, because shadows and other cameras see it meeting the head.
## first_person_body() gives the player camera its own copy whose head influence closes the
## neck top into a rounded end; everyone else keeps the original (tools/anonpony/test_neck_closure.gd).
const HEAD_BONE := "pony_head"
## Closure apex above the rim centre, in rim radii along the neck. The rim carries ~0.8 head
## weight, so it ends at ~20 % of its radius, ~0.5 radii up: a dome, not a lid.
const CLOSURE_LIFT := 0.6
const CLOSURE_SCALE := 0.001

static func attach(body: MeshInstance3D) -> MeshInstance3D:
	var rim := _rim(body)
	if rim.is_empty(): return null
	var vertices: PackedVector3Array = rim.vertices
	var bones: PackedInt32Array = rim.bones
	var weights: PackedFloat32Array = rim.weights
	var influences: int = rim.influences
	var loop: Array[int] = []
	loop.assign(rim.loop)
	var representatives: Array[int] = []
	representatives.assign(rim.representatives)
	var points := PackedVector3Array()
	var skin_bones := PackedInt32Array()
	var skin_weights := PackedFloat32Array()
	var center := Vector3.ZERO
	var center_weights: Dictionary = {}
	for vertex in loop:
		var original := representatives[vertex]
		points.append(vertices[original]); center += vertices[original]
		for influence in influences:
			var index := original * influences + influence
			skin_bones.append(bones[index]); skin_weights.append(weights[index])
			center_weights[bones[index]] = float(center_weights.get(bones[index],0.0)) + weights[index] / loop.size()
	center /= loop.size()
	points.append(center)
	var ranked: Array = center_weights.keys()
	ranked.sort_custom(func(a: int,b: int) -> bool: return float(center_weights[a]) > float(center_weights[b]))
	var total := 0.0
	for i in mini(influences,ranked.size()): total += float(center_weights[ranked[i]])
	if total <= 0.0: return null
	for i in influences:
		skin_bones.append(int(ranked[i]) if i < ranked.size() else 0)
		skin_weights.append(float(center_weights[ranked[i]]) / total if i < ranked.size() else 0.0)
	var triangles := PackedInt32Array()
	for i in loop.size():
		var next := (i + 1) % loop.size()
		# Two sides also close the view if a posed eye passes below the neck plane.
		triangles.append_array(PackedInt32Array([loop.size(),i,next,loop.size(),next,i]))
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	for point in points:
		normals.append(Vector3.UP); uv.append(Vector2.ZERO)
	var arrays: Array = []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points; arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv; arrays[Mesh.ARRAY_INDEX] = triangles
	arrays[Mesh.ARRAY_BONES] = skin_bones; arrays[Mesh.ARRAY_WEIGHTS] = skin_weights
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays,[],{},Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if influences == 8 else 0)
	var cap := MeshInstance3D.new(); cap.name = "NeckCapMesh"
	cap.mesh = mesh; cap.skin = body.skin; cap.transform = body.transform
	cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := body.get_active_material(0)
	if material != null:
		cap.material_override = material.duplicate()
		cap.material_override.next_pass = null
	body.get_parent().add_child(cap)
	cap.skeleton = cap.get_path_to(body.get_node(body.skeleton))
	return cap


## A copy of `body` for the player camera only: same mesh, materials and skeleton, but a
## skin whose head bind pins its influence to a point above the rim centre. The rim and
## the band above ~3 cm that the head weights reach close into a rounded end; the rest of
## the body is identical. Returns null (and changes nothing) when the rim is unfamiliar.
static func first_person_body(body: MeshInstance3D) -> MeshInstance3D:
	var rim := _rim(body)
	if rim.is_empty() or body.skin == null: return null
	var skeleton := body.get_node_or_null(body.skeleton) as Skeleton3D
	if skeleton == null: return null
	var head := -1
	for bind in body.skin.get_bind_count():
		var name := String(body.skin.get_bind_name(bind))
		if name == HEAD_BONE or (name.is_empty() and body.skin.get_bind_bone(bind) == skeleton.find_bone(HEAD_BONE)):
			head = bind
	if head < 0: return null
	var vertices: PackedVector3Array = rim.vertices
	var points: Array[Vector3] = []
	var center := Vector3.ZERO
	for vertex: int in rim.loop:
		points.append(vertices[int(rim.representatives[vertex])]); center += points[-1]
	center /= points.size()
	var axis := Vector3.ZERO   # Newell normal of the rim loop
	var radius := 0.0
	for i in points.size():
		var a := points[i]; var b := points[(i + 1) % points.size()]
		axis += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
		radius += a.distance_to(center) / points.size()
	var bind: Transform3D = body.skin.get_bind_pose(head)
	# bind maps mesh space to the head bone; its inverse origin is the head joint in mesh space.
	var toward_head: Vector3 = bind.affine_inverse().origin - center
	if axis.length_squared() < 1e-12 or radius <= 0.0: return null
	axis = axis.normalized() * signf(axis.dot(toward_head) if absf(axis.dot(toward_head)) > 1e-9 else 1.0)
	var apex := center + axis * radius * CLOSURE_LIFT
	var basis := bind.basis * CLOSURE_SCALE
	var skin := body.skin.duplicate() as Skin
	skin.set_bind_pose(head, Transform3D(basis, bind * apex - basis * apex))
	var copy := MeshInstance3D.new(); copy.name = "FirstPersonBody"
	copy.mesh = body.mesh; copy.skin = skin; copy.transform = body.transform
	copy.material_override = body.material_override; copy.material_overlay = body.material_overlay
	for surface in body.mesh.get_surface_count():
		copy.set_surface_override_material(surface, body.get_surface_override_material(surface))
	copy.cast_shadow = body.cast_shadow; copy.custom_aabb = body.custom_aabb
	copy.extra_cull_margin = body.extra_cull_margin; copy.layers = body.layers
	body.get_parent().add_child(copy)
	copy.skeleton = copy.get_path_to(skeleton)
	return copy

## The body's single open boundary (the neck rim) as original vertex indices, or {}.
static func _rim(body: MeshInstance3D) -> Dictionary:
	if body == null or body.mesh == null or body.mesh.get_surface_count() != 1: return {}
	var source: Array = body.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = source[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = source[Mesh.ARRAY_INDEX]
	var bones: PackedInt32Array = source[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = source[Mesh.ARRAY_WEIGHTS]
	if vertices.is_empty() or indices.is_empty() or bones.is_empty(): return {}
	var influences: int = bones.size() / vertices.size()
	if influences not in [4,8]: return {}
	# UV/normal seams duplicate vertices. Weld positions only for boundary discovery;
	# the output retains each boundary vertex's original skin binding.
	var weld: Dictionary = {}
	var representatives: Array[int] = []
	var welded := PackedInt32Array()
	for i in vertices.size():
		var key := vertices[i].snapped(Vector3.ONE * .00001)
		if not weld.has(key):
			weld[key] = representatives.size()
			representatives.append(i)
		welded.append(int(weld[key]))
	var edges: Dictionary = {}
	for triangle in range(0,indices.size(),3):
		for side in 3:
			var a := welded[indices[triangle + side]]
			var b := welded[indices[triangle + (side + 1) % 3]]
			var edge := Vector2i(mini(a,b),maxi(a,b))
			edges[edge] = int(edges.get(edge,0)) + 1
	var boundary: Dictionary = {}
	for edge: Vector2i in edges:
		if int(edges[edge]) != 1: continue
		if not boundary.has(edge.x): boundary[edge.x] = []
		if not boundary.has(edge.y): boundary[edge.y] = []
		boundary[edge.x].append(edge.y)
		boundary[edge.y].append(edge.x)
	if boundary.size() < 3: return {}
	for neighbours: Array in boundary.values():
		if neighbours.size() != 2: return {}
	var loop: Array[int] = []
	var current: int = boundary.keys()[0]
	var previous := -1
	while not loop.has(current):
		loop.append(current)
		var neighbours: Array = boundary[current]
		var next: int = neighbours[0] if int(neighbours[0]) != previous else neighbours[1]
		previous = current
		current = next
	# These player bodies have one open neck rim. Refuse unfamiliar topology rather
	# than cap another opening or silently bridge disconnected loops.
	if current != loop[0] or loop.size() != boundary.size(): return {}
	return {"vertices":vertices,"bones":bones,"weights":weights,"influences":influences,"loop":loop,"representatives":representatives}
