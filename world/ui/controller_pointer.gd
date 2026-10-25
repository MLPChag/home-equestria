extends Node3D
## Title-screen style gold controller dot, with a thin ray for inventory aiming.
var dot: MeshInstance3D
var beam: MeshInstance3D
func _ready() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color=Color("edcd84")
	dot=MeshInstance3D.new()
	var sphere:=SphereMesh.new();sphere.radius=.006;sphere.height=.012
	sphere.radial_segments=12;sphere.rings=6;dot.mesh=sphere
	beam=MeshInstance3D.new()
	var box:=BoxMesh.new();box.size=Vector3(.0015,.0015,1);beam.mesh=box
	for mesh in [dot,beam]:
		mesh.material_override=material
		mesh.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mesh)
	hide()
func aim(origin:Vector3,hit:Vector3) -> void:
	if not hit.is_finite() or origin.distance_squared_to(hit)<.000001:hide();return
	show();dot.global_position=hit
	var direction:=hit-origin
	var up:=Vector3.RIGHT if absf(direction.normalized().dot(Vector3.UP))>.99 else Vector3.UP
	beam.global_transform=Transform3D(Basis.looking_at(direction,up).scaled_local(Vector3(1,1,direction.length())),origin+direction*.5)

func set_color(color:Color) -> void:
	if dot!=null:dot.material_override.albedo_color=color
