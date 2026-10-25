extends RefCounted
## Same ordered contact query, with immutable skin data flattened once at bind.
## No decimation, approximate contacts, changed tolerances or GPU readback.
var offsets := PackedInt32Array()
var joints := PackedInt32Array()
var positions := PackedVector3Array()
var weights := PackedFloat64Array()
var dominant := PackedInt32Array()
var contacts: Array = []
var collar := PackedByteArray()
var tolerance := 0.0

func build(source: Array, exemptions := PackedByteArray(), tie_tolerance := 0.0) -> void:
	contacts = source
	collar = exemptions
	tolerance = tie_tolerance
	offsets.clear(); joints.clear(); positions.clear(); weights.clear(); dominant.clear()
	for contact: Array in contacts:
		offsets.append(joints.size())
		var best := -1
		var weight := 0.0
		for item: Array in contact:
			var bone := int(item[0])
			var amount := float(item[2])
			joints.append(bone); positions.append(item[1]); weights.append(amount)
			if bone >= 0 and amount > weight: best = bone; weight = amount
		dominant.append(best if weight > .000001 else -1)
	offsets.append(joints.size())

func deepest(frames: Array[Transform3D], mount: Transform3D, anchor: Vector3,
		planes: Array[Dictionary], capsules: Array[Dictionary], skin_margin: float) -> Dictionary:
	# Per-pose geometry is shared by every contact, not rebuilt inside its loop.
	var plane_positions := PackedVector3Array()
	var plane_normals := PackedVector3Array()
	var plane_present := PackedByteArray()
	for plane in planes:
		plane_present.append(int(not plane.is_empty()))
		plane_positions.append(plane.get("position", Vector3.ZERO))
		plane_normals.append(plane.get("normal", Vector3.UP))
	var bases := PackedVector3Array()
	var axes := PackedVector3Array()
	var lengths := PackedFloat64Array()
	var radii := PackedFloat64Array()
	for capsule in capsules:
		var a: Vector3 = capsule.a
		var ab: Vector3 = Vector3(capsule.b) - a
		bases.append(a); axes.append(ab)
		lengths.append(maxf(ab.length_squared(), .000001))
		radii.append(float(capsule.radius) + .005)
	var deepest := 0.0
	var selected := -1
	var selected_normal := Vector3.ZERO
	for index in dominant.size():
		var bone := dominant[index]
		if bone < 0: continue
		var point := Vector3.ZERO
		var begin:=offsets[index]
		if offsets[index+1]==begin+1:
			point=((mount if joints[begin]<0 else frames[joints[begin]])*positions[begin])*weights[begin]
		else:
			for i in range(begin, offsets[index + 1]):
				point += ((mount if joints[i] < 0 else frames[joints[i]]) * positions[i]) * weights[i]
		if plane_present[bone]:
			var normal := plane_normals[bone]
			var depth := skin_margin - (point - plane_positions[bone]).dot(normal)
			if depth > deepest + tolerance:
				deepest = depth; selected = index; selected_normal = normal
		if (not collar.is_empty() and collar[index]) or point.distance_squared_to(anchor) < .11 * .11: continue
		for i in bases.size():
			var center := bases[i] + axes[i] * clampf((point - bases[i]).dot(axes[i]) / lengths[i], 0.0, 1.0)
			var offset := point - center
			# Exterior points cannot improve a nonnegative penetration. Preserve
			# ordering/tie rules and exact sqrt for all possible actual contacts.
			if offset.length_squared()>radii[i]*radii[i]:continue
			var distance := offset.length()
			var depth := radii[i] - distance
			if depth > deepest + tolerance and distance > .00001:
				deepest = depth; selected = index; selected_normal = offset / distance
	return {} if selected < 0 else {"depth": deepest, "normal": selected_normal, "inf": contacts[selected]}
