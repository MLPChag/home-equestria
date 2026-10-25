extends "res://world/buildings/authored_home.gd"
## Public working barn: the existing house portal/travel contract, no residential allocation.
func _ready() -> void:
	super._ready()
	set_process(false); set_physics_process(false)

func fits(profile:Resource) -> bool:return door_width>profile.radius*2+.08 and 3.20>profile.clearance+.1
func inside() -> Vector3:return to_global(Vector3(1.857,floor_y,8.5))
func center() -> Vector3:return to_global(Vector3(1.857,floor_y,0))
func slots() -> Array[Vector3]:
	return [to_global(Vector3(.4,floor_y,0)),to_global(Vector3(3.3,floor_y,0)),to_global(Vector3(.4,floor_y,-2)),to_global(Vector3(3.3,floor_y,-2))]

func _init() -> void:
	home_kind = "barn"
