extends "res://world/buildings/golden_oak/home.gd"
## Retains the existing tested indoor route/bed APIs, with this building's measured layout.
func configure(layout: Dictionary, interior: Node3D, door_leaf: Node3D) -> void:
	furniture=interior;leaf=door_leaf;radius=layout.radius;loft_y=layout.upper_y;_ceiling_y=layout.ceiling_y
	doorway=layout.door_position;door_width=layout.door_width;doorway_height=layout.door_height
	approach=layout.door_approach;entry_point=layout.door_inside
	floors=[Rect2(-radius,-radius,radius*2,radius*2),Rect2(-.87,4.0,1.74,1.5)]
	stair_path.assign(interior.get_meta("stair_path",[]));bed=interior.ensure_bed("rarity")
	for target:Node in interior.find_children("*","Node3D",true,false):
		if target.has_meta("bed_size"):target.set_meta("house",self)
func configure_owner(_homes:Dictionary)->bool:
	# The requested boutique home replaces Rarity's former generic address; family assignment brings Sweetie.
	set_meta("reserved_for","rarity")
	return true
func _init() -> void:
	home_kind = "boutique"
