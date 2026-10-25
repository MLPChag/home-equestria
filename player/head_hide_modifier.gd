extends SkeletonModifier3D
## Hides the avatar's own head from the player by collapsing the head bone.
##
## A VR body's head mesh sits exactly where the camera is: without this the
## player sees the inside of their own skull. The whole body is one skinned
## mesh, so visual layers cannot split the head off — scaling the head bone
## to zero removes the skinned vertices instead. Runs after the IK modifiers
## because modifier order is tree order.
##
## The collapsed head would also vanish from the body's shadow (a headless
## shadow). A shadow-only copy of the head geometry follows the head's pose
## from just before the collapse, so the shadow keeps its head while the camera
## still sees nothing (dev 2026-10-13).
##
## Set influence to 0 to show the head (mirrors, third-person captures).

@export var head_bone: StringName = &"ValveBiped.Bip01_Head1"
@export var shadow_head := true

var _idx := -1
var _proxy: MeshInstance3D
var _proxy_built := false


func _process_modification() -> void:
	if not is_inside_tree():
		return
	var skel := get_skeleton()
	if not is_instance_valid(skel) or not skel.is_inside_tree():
		return
	if _idx == -1:
		_idx = skel.find_bone(head_bone)
		if _idx == -1:
			return
	if shadow_head:
		if not _proxy_built:
			_proxy_built = true
			_proxy = _build_proxy(skel)
		if _proxy != null:
			var head_pose := skel.global_transform * skel.get_bone_global_pose(_idx)
			if head_pose.is_finite() and _proxy.is_inside_tree():
				_proxy.global_transform = head_pose
				_proxy.visible = true
	var pose := skel.get_bone_pose(_idx)
	skel.set_bone_pose(_idx, Transform3D(pose.basis.scaled(Vector3.ONE * 0.001), pose.origin))


func _process(_delta: float) -> void:
	# Modification stops when inactive (mirrors, third person): the real head is back.
	if _proxy != null and not active:
		_proxy.visible = false


func _exit_tree() -> void:
	if _proxy != null and is_instance_valid(_proxy):
		_proxy.queue_free()
	_proxy = null
	_proxy_built = false


## Triangles of every skinned mesh under the skeleton that belong to the head
## (head bone or its children carry most of the weight), in head-bone space.
func _build_proxy(skel: Skeleton3D) -> MeshInstance3D:
	var head_set := {}
	var stack: Array[int] = [_idx]
	while not stack.is_empty():
		var b: int = stack.pop_back()
		head_set[b] = true
		for c in skel.get_bone_children(b): stack.append(c)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for mi: MeshInstance3D in skel.find_children("*", "MeshInstance3D", false, false):
		if mi.mesh == null or mi.skin == null: continue
		var skin := mi.skin
		var bind_bone := PackedInt32Array()
		var head_bind := -1
		for i in skin.get_bind_count():
			var bone := skin.get_bind_bone(i)
			if bone < 0: bone = skel.find_bone(skin.get_bind_name(i))
			bind_bone.append(bone)
			if bone == _idx: head_bind = i
		if head_bind == -1: continue
		var to_head := skin.get_bind_pose(head_bind)
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if arrays[Mesh.ARRAY_BONES] != null else PackedInt32Array()
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if arrays[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
			if bones.is_empty() or v.is_empty(): continue
			var per := bones.size() / v.size()
			var in_head := PackedByteArray()
			in_head.resize(v.size())
			for vi in v.size():
				var w := 0.0
				for k in per:
					var bind := bones[vi * per + k]
					if bind >= 0 and bind < bind_bone.size() and head_set.has(bind_bone[bind]):
						w += weights[vi * per + k]
				in_head[vi] = 1 if w > 0.5 else 0
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if idx.is_empty():
				idx.resize(v.size())
				for i in v.size(): idx[i] = i
			var nb := to_head.basis.inverse().transposed()
			for t in idx.size() / 3:
				var a := idx[t * 3]; var b := idx[t * 3 + 1]; var c := idx[t * 3 + 2]
				if in_head[a] == 0 or in_head[b] == 0 or in_head[c] == 0: continue
				for vi: int in [a, b, c]:
					verts.append(to_head * v[vi])
					normals.append((nb * n[vi]).normalized() if not n.is_empty() else Vector3.UP)
	if verts.is_empty(): return null
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	var proxy := MeshInstance3D.new()
	proxy.name = "HeadShadow"
	proxy.mesh = mesh
	proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	proxy.top_level = true
	proxy.visible = false
	add_child.call_deferred(proxy)
	return proxy
