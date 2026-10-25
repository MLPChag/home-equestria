extends Node3D
## World Panel: the map's flat SubViewport → Sprite3D presentation, with actual GUI input.
## Rays intersect the panel mathematically; no extra 3D camera or physics body.
const PIXELS := Vector2i(900, 840)
const PIXEL_SIZE := 0.0014
var viewport: SubViewport
var display: Sprite3D
var content: Control
var _last_pixel := Vector2(-1, -1)
var _pressed := false

func _ready() -> void:
	viewport = SubViewport.new()
	viewport.size = PIXELS
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(viewport)
	content = Control.new()
	content.size = PIXELS
	viewport.add_child(content)
	display = Sprite3D.new()
	display.texture = viewport.get_texture()
	display.pixel_size = PIXEL_SIZE
	display.shaded = false
	display.double_sided = false
	display.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	display.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(display)

func refresh() -> void:
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func ray_to_pixel(origin: Vector3, direction: Vector3) -> Vector2:
	var local_origin := to_local(origin)
	var local_direction := global_basis.inverse() * direction
	if local_direction.z >= -0.00001: return Vector2(-1, -1)
	var distance := -local_origin.z / local_direction.z
	if distance < 0.0: return Vector2(-1, -1)
	var point := local_origin + local_direction * distance
	var pixel := Vector2(point.x, -point.y) / PIXEL_SIZE + Vector2(PIXELS) * 0.5
	return pixel if Rect2(Vector2.ZERO, PIXELS).has_point(pixel) else Vector2(-1, -1)

func pixel_to_world(pixel: Vector2) -> Vector3:
	var local := (pixel - Vector2(PIXELS) * 0.5) * PIXEL_SIZE
	return to_global(Vector3(local.x, -local.y, 0.005))

func point_at(pixel: Vector2) -> void:
	if pixel.is_equal_approx(_last_pixel): return
	var event := InputEventMouseMotion.new()
	event.position = pixel
	event.global_position = pixel
	event.relative = pixel - _last_pixel
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if _pressed else 0
	_last_pixel = pixel
	viewport.push_input(event, true)
	refresh()

func press(value: bool) -> void:
	if value and _last_pixel.x < 0: return
	if _pressed == value: return
	_pressed = value
	var event := InputEventMouseButton.new()
	event.position = _last_pixel
	event.global_position = _last_pixel
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = value
	viewport.push_input(event, true)
	refresh()

func send_key(event: InputEventKey) -> void:
	viewport.push_input(event, true)
	refresh()
