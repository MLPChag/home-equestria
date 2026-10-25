extends Node3D
## Register the authored lanterns with the existing dusk/daylight controller.
func _ready() -> void:
	preload("res://world/street_lamps.gd").prepare(self)
