extends Node3D
## A physical lamp with one light. A shared input adapter owns desktop/hand controls.
var lit := true
var light: Light3D
var collider: StaticBody3D
## box: a bounding box instead of the exact surface (many house lamps share a town).
func configure(visual:MeshInstance3D,source_light:Light3D,box:=false)->void:
	light=source_light
	collider=StaticBody3D.new();collider.name="LampSolid"
	collider.transform=visual.transform;collider.collision_layer=1;collider.collision_mask=0
	collider.set_meta("physical_lamp",self)
	var shape:=CollisionShape3D.new();shape.name="LampSurface"
	if box:
		var bounds:=visual.mesh.get_aabb();var cube:=BoxShape3D.new()
		cube.size=bounds.size.max(Vector3.ONE*.04);shape.shape=cube;shape.position=bounds.get_center()
	else:
		var surface:=visual.mesh.create_trimesh_shape();surface.backface_collision=true
		shape.shape=surface
	collider.add_child(shape);add_child(collider)
	set_meta("lamp_touch_center",visual.transform*visual.mesh.get_aabb().get_center())
	add_to_group("physical_lamps",true)
	set_lit(true)
func set_lit(value:bool)->void:
	lit=value
	if is_instance_valid(light):light.visible=value
func toggle()->void:set_lit(not lit)
