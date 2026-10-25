extends Control
## Exact centre of the desktop pickup ray; ignores mouse input and menus.
const RADIUS := 2.0
const INK := Color(1.0, 1.0, 1.0, 0.5)
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
func _draw() -> void:
	draw_circle(size * .5, RADIUS, INK, true, -1.0, true)
