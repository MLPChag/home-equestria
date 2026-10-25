extends Node3D
## Seated VR aiming aids (dev 2026-10-01). The desktop has no crosshair, but a headset hides the
## system cursor, so:
## - mouse captured: a small gaze reticle 1.5 m ahead, where the interactor's centre ray aims;
## - mouse visible and not over the virtual screen's menus: a small dot on the camera's mouse ray
##   (the ray the briefcase, the J inspector and the wardrobe click with), on the first thing it
##   hits within 3 m, else 0.6 m out. Over a menu the screen's own arrow shows instead
##   (world/ui/virtual_screen.gd).
## Both hide while the rig is held (loading cover, title, the wake's closed-eye views), and
## hide_for(owner) hides them while owner is in the tree (the creator and the title draw their own).

const GROUP := "headset_cursor"
const RETICLE_DISTANCE := 1.5
const DOT_RADIUS := 0.0015      # a 3 mm dot
const DOT_REACH := 3.0
const DOT_FALLBACK := 0.6
const RENDER_PRIORITY := 120    # over the virtual screen (90) and every headset overlay

var game: Node
var _camera: Camera3D
var _reticle: MeshInstance3D
var _dot: MeshInstance3D
var _hiders: Array[int] = []     # instance ids
var _dot_distance := DOT_FALLBACK


func setup(host: Node) -> void:
	game = host
	add_to_group(GROUP)
	_camera = _find_camera()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.006; ring.outer_radius = 0.009; ring.rings = 16; ring.ring_segments = 6
	_reticle = _marker("GazeReticle", ring, Color(1, 1, 1, 0.75))
	var ball := SphereMesh.new()
	ball.radius = DOT_RADIUS; ball.height = DOT_RADIUS * 2.0; ball.radial_segments = 12; ball.rings = 6
	_dot = _marker("MouseDot", ball, Color(1.0, 0.93, 0.7, 0.95))


func _marker(marker_name: String, mesh: PrimitiveMesh, color: Color) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	material.no_depth_test = true
	material.render_priority = RENDER_PRIORITY
	mesh.material = material
	var marker := MeshInstance3D.new()
	marker.name = marker_name
	marker.mesh = mesh
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Placed every frame from the camera, so never physics-interpolated.
	marker.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	marker.top_level = true
	marker.hide()
	add_child(marker)
	return marker


## Hidden while `who` is valid and in the tree.
func hide_for(who: Node) -> void:
	if who != null and who.get_instance_id() not in _hiders: _hiders.append(who.get_instance_id())


func _hidden() -> bool:
	# Not over the loading black or the wake's eyes-closed views: the rig is held still then.
	var rig: Variant = game.get("player")
	if is_instance_valid(rig) and rig is Node:
		if not (rig as Node).is_physics_processing(): return true
		if (rig as Node).has_method("view_is_held") and bool(rig.view_is_held()): return true
	var hidden := false
	for id: int in _hiders.duplicate():
		var node := instance_from_id(id) as Node
		if node == null: _hiders.erase(id)
		elif node.is_inside_tree(): hidden = true
	return hidden


func _mouse_free() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and get_tree().root.gui_get_hovered_control() == null


## The hit distance for the dot, at physics rate.
func _physics_process(_delta: float) -> void:
	if not _mouse_free() or not is_instance_valid(_camera) or not _camera.is_inside_tree(): return
	var mouse := get_tree().root.get_mouse_position()
	var from := _camera.project_ray_origin(mouse)
	var direction := _camera.project_ray_normal(mouse)
	if not from.is_finite() or not direction.is_finite(): return
	var query := PhysicsRayQueryParameters3D.create(from, from + direction * DOT_REACH)
	query.collide_with_areas = true
	var body: Variant = game.get("player")
	if body is CollisionObject3D: query.exclude = [(body as CollisionObject3D).get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	_dot_distance = from.distance_to(hit.position) if not hit.is_empty() else DOT_FALLBACK


func _process(_delta: float) -> void:
	if not is_instance_valid(_camera) or not _camera.is_inside_tree(): _camera = _find_camera()
	var suppressed := _camera == null or _hidden() or not _camera.global_transform.is_finite()
	var captured := not suppressed and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var pointing := not suppressed and not captured and _mouse_free()
	_reticle.visible = captured
	_dot.visible = pointing
	if captured:
		var view := _camera.global_basis.orthonormalized()
		# The torus lies flat; tip it up to face the eye.
		_reticle.global_transform = Transform3D(view * Basis(Vector3.RIGHT, PI * 0.5), _camera.global_position - view.z * RETICLE_DISTANCE)
	elif pointing:
		var mouse := get_tree().root.get_mouse_position()
		var from := _camera.project_ray_origin(mouse)
		var direction := _camera.project_ray_normal(mouse)
		if from.is_finite() and direction.is_finite(): _dot.global_position = from + direction * _dot_distance
		else: _dot.hide()


func _find_camera() -> Camera3D:
	if game == null or not is_instance_valid(game.get("player")): return null
	return game._find_camera(game.player) as Camera3D
