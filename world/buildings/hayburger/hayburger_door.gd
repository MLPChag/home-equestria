extends "res://world/buildings/hinged_door.gd"
## Shop latch permits egress from the inside, including after closing time.
var locked := false
var entrance: Node3D

func can_grip(point: Vector3) -> bool:
	return (not locked or entrance.is_inside(point)) and super.can_grip(point)

func toggle_door() -> void:
	var camera: Camera3D = preload("res://world/player_view.gd").camera(self)
	if locked and (camera == null or not entrance.is_inside(camera.global_position)): return
	super.toggle_door()
	if locked:
		_close_after_passage = true
		_close_delay = 4.0

func request_passage(pony: Node3D) -> bool:
	if not is_instance_valid(pony) or (locked and not entrance.is_inside(pony.global_position)): return false
	return super.request_passage(pony)

func end_grip() -> void:
	super.end_grip()
	if locked:
		_close_after_passage = true
		_close_delay = 3.0

func _physics_process(delta: float) -> void:
	# If someone blocks closing, the base door stops safely. Retry after they move.
	if locked and not is_instance_valid(holder) and _visitors.is_empty() and _close_delay <= 0:
		target = 0.0
	super._physics_process(delta)
