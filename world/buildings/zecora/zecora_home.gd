extends "res://world/buildings/authored_home.gd"
## Dedicated authored home: do not run the standard ten-centimetre shell repairs.
func _init() -> void:
	home_kind = "zecora"
