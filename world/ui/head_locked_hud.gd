class_name HeadLockedHUD
extends Node3D
## One scene-pose HUD capture per tracked camera, presented in render-view space.
## Keep registered roots beneath the camera: their original transforms own ray input.
## Render layers and physics collision layers are independent namespaces.

const HUD_LAYER: int = 1 << 18 # Render layer 19; layer 20 belongs to terrain probes/marks.
const HELPER_META: StringName = &"head_locked_hud_helper"
const HUD_SHADER: Shader = preload("res://world/ui/head_locked_hud.gdshader")
const CAPTURE_SIZE: int = 1280
const PLANE_DISTANCE: float = 1.5

var tracked_camera: Camera3D
var capture_viewport: SubViewport
var capture_camera: Camera3D
var overlay: MeshInstance3D
var overlay_material: ShaderMaterial
var _roots: Dictionary = {} # Instance ID -> WeakRef.
var _geometry: Dictionary = {} # Instance ID -> original layer mask + WeakRef.
var _dirty: bool = true
var _camera_had_hud_layer: bool = false
var _closed: bool = false
var _state_restored: bool = false


static func attach(camera: Camera3D, hud_root: Node3D) -> Node3D:
	if not is_instance_valid(camera) or not is_instance_valid(hud_root):
		return null
	if not camera.is_inside_tree() or not camera.is_ancestor_of(hud_root):
		push_error("HeadLockedHUD.attach needs a HUD root beneath an in-tree camera.")
		return null
	var helper: Variant = _get_helper(camera)
	if helper == null:
		var helper_script: GDScript = load("res://world/ui/head_locked_hud.gd") as GDScript
		helper = helper_script.new()
		helper.name = "HeadLockedHUD"
		helper.tracked_camera = camera
		helper._camera_had_hud_layer = (camera.cull_mask & HUD_LAYER) != 0
		camera.set_meta(HELPER_META, weakref(helper))
		camera.add_child(helper)
	helper._roots[hud_root.get_instance_id()] = weakref(hud_root)
	helper._dirty = true
	helper._refresh_geometry()
	return helper


static func detach(camera: Camera3D, hud_root: Node3D) -> void:
	var helper: Variant = _get_helper(camera)
	if helper == null or not is_instance_valid(hud_root):
		return
	helper._roots.erase(hud_root.get_instance_id())
	helper._dirty = true
	helper._refresh_geometry()
	if helper._roots.is_empty():
		helper._close()


static func _get_helper(camera: Camera3D) -> Variant:
	if not is_instance_valid(camera) or not camera.has_meta(HELPER_META):
		return null
	var reference: WeakRef = camera.get_meta(HELPER_META) as WeakRef
	if reference == null:
		return null
	var helper: Variant = reference.get_ref()
	if helper == null or helper._closed or helper.is_queued_for_deletion():
		return null
	return helper


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	process_priority = 100000
	capture_viewport = SubViewport.new()
	capture_viewport.name = "HUDCapture"
	capture_viewport.size = Vector2i(CAPTURE_SIZE, CAPTURE_SIZE)
	capture_viewport.transparent_bg = true
	capture_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	capture_viewport.msaa_3d = Viewport.MSAA_4X
	capture_viewport.world_3d = tracked_camera.get_world_3d()
	add_child(capture_viewport)

	capture_camera = Camera3D.new()
	capture_camera.name = "HUDCaptureCamera"
	capture_camera.cull_mask = HUD_LAYER
	capture_camera.fov = 90.0
	capture_camera.near = 0.01
	capture_camera.far = 20.0
	capture_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var environment: Environment = Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.background_color = Color(0, 0, 0, 0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	capture_camera.environment = environment
	capture_viewport.add_child(capture_camera)
	capture_camera.make_current()

	overlay_material = ShaderMaterial.new()
	overlay_material.shader = HUD_SHADER
	overlay_material.set_shader_parameter("hud_texture", capture_viewport.get_texture())
	overlay_material.set_shader_parameter("head_center", Vector3(0, 0, -PLANE_DISTANCE))
	overlay_material.render_priority = 127
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2.ONE * PLANE_DISTANCE * 2.0
	overlay = MeshInstance3D.new()
	overlay.name = "HUDRenderViewOverlay"
	overlay.mesh = quad
	overlay.material_override = overlay_material
	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	overlay.layers = 1 # Excluded from the capture camera's HUD-only mask.
	overlay.extra_cull_margin = 16384.0
	overlay.position = Vector3(0, 0, -PLANE_DISTANCE)
	add_child(overlay)
	# Keep layer culling: ignore_culling also bypasses the capture camera's mask,
	# feeding this texture back into itself and retaining hidden/old HUD pixels.
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	RenderingServer.frame_pre_draw.connect(_sync_capture)
	_sync_capture()


func _process(_delta: float) -> void:
	if _closed:
		return
	for root_id: int in _roots.keys():
		var root: Node = (_roots[root_id] as WeakRef).get_ref() as Node
		if root == null or not root.is_inside_tree() or not tracked_camera.is_ancestor_of(root):
			_roots.erase(root_id)
			_dirty = true
	if _dirty:
		_refresh_geometry()
	if _roots.is_empty():
		_close()
		return
	_sync_capture()


func _sync_capture() -> void:
	if _closed or not is_instance_valid(tracked_camera) or not tracked_camera.is_inside_tree():
		return
	tracked_camera.cull_mask &= ~HUD_LAYER
	if _dirty:
		_refresh_geometry()
	var camera_world: World3D = tracked_camera.get_world_3d()
	if capture_viewport.world_3d != camera_world:
		capture_viewport.world_3d = camera_world
	# Intentionally copy the NODE pose, never the XR render pose. HUD children use
	# that same node pose, so capture cancels it before the view-space presentation.
	capture_camera.global_transform = tracked_camera.global_transform
	capture_camera.h_offset = tracked_camera.h_offset
	capture_camera.v_offset = tracked_camera.v_offset


func _on_node_added(node: Node) -> void:
	for reference: WeakRef in _roots.values():
		var root: Node = reference.get_ref() as Node
		if root != null and (root == node or root.is_ancestor_of(node)):
			_dirty = true
			return


func _on_node_removed(node: Node) -> void:
	var instance_id: int = node.get_instance_id()
	if _roots.has(instance_id) or _geometry.has(instance_id):
		_dirty = true


func _refresh_geometry() -> void:
	var wanted: Dictionary = {}
	for reference: WeakRef in _roots.values():
		var root: Node = reference.get_ref() as Node
		if root != null and root.is_inside_tree():
			_collect_geometry(root, wanted)
	for instance_id: int in _geometry.keys():
		if wanted.has(instance_id):
			continue
		_restore_geometry(instance_id)
	for instance_id: int in wanted:
		var visual: GeometryInstance3D = wanted[instance_id] as GeometryInstance3D
		if not _geometry.has(instance_id):
			_geometry[instance_id] = {"reference": weakref(visual), "layers": visual.layers}
		visual.layers = HUD_LAYER
	_dirty = false


func _collect_geometry(node: Node, wanted: Dictionary) -> void:
	if node is GeometryInstance3D:
		wanted[node.get_instance_id()] = node
	for child: Node in node.get_children():
		_collect_geometry(child, wanted)


func _restore_geometry(instance_id: int) -> void:
	var entry: Dictionary = _geometry[instance_id]
	var visual: GeometryInstance3D = (entry["reference"] as WeakRef).get_ref() as GeometryInstance3D
	if visual != null:
		visual.layers = int(entry["layers"])
	_geometry.erase(instance_id)


func _close() -> void:
	if _closed:
		return
	_closed = true
	_restore_state()
	overlay.visible = false
	capture_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	queue_free()


func _restore_state() -> void:
	# Closing restores immediately; delayed tree exit must not restore again over
	# a replacement helper attached during the same frame.
	if _state_restored:
		return
	_state_restored = true
	for instance_id: int in _geometry.keys():
		_restore_geometry(instance_id)
	if is_instance_valid(tracked_camera):
		if _camera_had_hud_layer:
			tracked_camera.cull_mask |= HUD_LAYER
		else:
			tracked_camera.cull_mask &= ~HUD_LAYER
		if tracked_camera.has_meta(HELPER_META):
			var reference: WeakRef = tracked_camera.get_meta(HELPER_META) as WeakRef
			if reference != null and reference.get_ref() == self:
				tracked_camera.remove_meta(HELPER_META)


func _exit_tree() -> void:
	_closed = true
	if RenderingServer.frame_pre_draw.is_connected(_sync_capture):
		RenderingServer.frame_pre_draw.disconnect(_sync_capture)
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	if get_tree().node_removed.is_connected(_on_node_removed):
		get_tree().node_removed.disconnect(_on_node_removed)
	_restore_state()
