extends Node3D
## Opaque physical carrier under the existing controls. It never owns input or changes
## their coordinates. The mount's measured clearance must include this back face.
const BACK := -0.008
const RIM_WIDTH := 0.002
var bounds := Rect2()
var _backing: MeshInstance3D
var _rim: Array[MeshInstance3D] = []

func _init() -> void:
	name = "ForearmCarrier"
	var base := StandardMaterial3D.new()
	base.albedo_color = Color("283332")
	base.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var edge := StandardMaterial3D.new()
	edge.albedo_color = Color("71837b")
	edge.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_backing = _box("Backing", base)
	for i in 4: _rim.append(_box("Rim%d" % i, edge))

func _box(node_name: String, material: Material) -> MeshInstance3D:
	var box := MeshInstance3D.new()
	box.name = node_name
	box.mesh = BoxMesh.new()
	box.material_override = material
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(box)
	return box

func fit(rect: Rect2, top: float = -0.002) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0 or top <= BACK: return
	bounds = rect
	var center := rect.get_center()
	(_backing.mesh as BoxMesh).size = Vector3(rect.size.x, rect.size.y, top - BACK)
	_backing.position = Vector3(center.x, center.y, (top + BACK) * 0.5)
	# The small rim stands one millimetre above the backing, outside the display content.
	var height := 0.002
	for i in 4:
		var horizontal := i < 2
		var size := Vector3(rect.size.x, RIM_WIDTH, height) if horizontal else Vector3(RIM_WIDTH, rect.size.y - RIM_WIDTH * 2.0, height)
		(_rim[i].mesh as BoxMesh).size = size
		var rim_position := Vector3(center.x, center.y, top)
		if horizontal: rim_position.y = rect.position.y + RIM_WIDTH * 0.5 if i == 0 else rect.end.y - RIM_WIDTH * 0.5
		else: rim_position.x = rect.position.x + RIM_WIDTH * 0.5 if i == 2 else rect.end.x - RIM_WIDTH * 0.5
		_rim[i].position = rim_position
