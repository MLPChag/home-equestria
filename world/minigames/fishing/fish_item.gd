extends Node3D
## A caught river fish remains a physical inventory item, with its native model.
var _bounds:AABB
var _prepared:bool=false

func prepare()->void:
	if _prepared:return
	var first:bool=true
	for mesh:MeshInstance3D in find_children("*","MeshInstance3D",true,false):
		if mesh.mesh==null:continue
		var xf:Transform3D=Transform3D.IDENTITY
		var node:Node3D=mesh
		while node!=self:
			xf=node.transform*xf
			node=node.get_parent() as Node3D
		var box:AABB=xf*mesh.get_aabb()
		_bounds=box if first else _bounds.merge(box)
		first=false
	get_node("Model").position-=_bounds.get_center()
	_bounds.position=-_bounds.size*.5
	_prepared=true

func configure_body(body:RigidBody3D,collision:CollisionShape3D)->void:
	prepare()
	var shape:BoxShape3D=BoxShape3D.new()
	shape.size=_bounds.size
	collision.shape=shape
	body.mass=.3
