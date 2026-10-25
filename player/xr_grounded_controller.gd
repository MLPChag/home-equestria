extends XRController3D
## Controller adapter for the xr-kit physics hands.
##
## xr-kit's own controller script listens for custom OpenXR actions ("grab",
## "thruster", "rotate") that only exist in its bundled action map. This
## project uses the standard godot-xr-tools action map, and the desktop XR
## simulator also emits only standard action names. This script emits the
## signals the xr-kit physics hand expects, from standard actions:
##   grip (float/click)  -> grab
##   primary (vector2)   -> thruster on the left hand, snap turn on the right
##   trigger (float)     -> trigger

signal trigger(value: float)
signal grip(value: float)
signal grab(value: bool)
signal thruster(value: Vector2)
signal thruster_brake(value: bool)
signal turned_x(direction: int, controller: Node3D)
signal turned_y(direction: int, controller: Node3D)
signal free_rotation_signal(value: bool)

## Read by xr-kit physics_hand.gd. Kept false: free rotation is a zero-G
## feature this project does not use.
var free_rotation: bool = false

var _grabbing := false


func _on_input_float_changed(action_name: String, value: float) -> void:
	if action_name == "grip":
		grip.emit(value)
		# Hysteresis so controller drift near the threshold cannot
		# machine-gun grab/drop.
		if not _grabbing and value > 0.65:
			_grabbing = true
			grab.emit(true)
		elif _grabbing and value < 0.35:
			_grabbing = false
			grab.emit(false)
	elif action_name == "trigger":
		trigger.emit(value)


func _on_button_pressed(action_name: String) -> void:
	if action_name == "grip_click" and not _grabbing:
		_grabbing = true
		grab.emit(true)


func _on_button_released(action_name: String) -> void:
	if action_name == "grip_click" and _grabbing:
		_grabbing = false
		grab.emit(false)


func _on_input_vector_2_changed(action_name: String, value: Vector2) -> void:
	if action_name != "primary":
		return
	# The movement stick is the left one unless VR comfort says "Right stick moves".
	var settings := get_node_or_null("/root/Settings")
	var move_tracker: StringName = &"right_hand" if settings != null and str(settings.get_value("vr/move_hand")) == "right" else &"left_hand"
	if tracker == move_tracker:
		thruster.emit(value)
	# Right stick is turning, and the body polls it directly every physics
	# frame (smooth turn) — nothing to emit here.
