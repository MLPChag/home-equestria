extends Node
## Spectator camera for recording, Vivecraft style: the headset renders its own stereo view
## while the game window shows a separate, watchable camera on the same world.
##
## Modes (key V cycles, Shift+1-4 pick):
##   1 smooth  first person, one-euro filtered position, slerped rotation, roll levelled
##   2 third   over the shoulder, behind and above the body, framing you and the mare
##   3 orbit   slow orbit around the mare (or you, if she is not around)
##   4 face    in front of you, looking back at your face and the mare in your arms
## Enabled by game.gd with `--spectator [mode]`.
##
## In VR (dev 2026-10-11: "VR should render for VR but the main window should be spectator
## mode, Vivecraft does it") the player rig moves into an XR SubViewport that feeds the
## headset, and the root viewport (the game window) renders the spectator camera. Gameplay
## that needs the player's own view asks world/player_view.gd, which returns the headset's
## viewport. An AudioListener3D follows the head so sound stays where the player is.
## Without XR (desktop) the spectator opens a separate window instead, as before;
## `--spectator-separate` forces that in VR too.
## The extra render costs a full frame of GPU work; keep it off outside recording sessions.

const ONE_EURO := preload("res://addons/xr-kit/smooth-input-filter/scripts/one_euro_filter.gd")
const PLAYER_VIEW := preload("res://world/player_view.gd")
const MODES := ["smooth", "third", "orbit", "face"]
## Root viewport settings mirrored onto the headset view (autoload/quality.gd writes the root).
const VIEW_SETTINGS := ["msaa_3d", "scaling_3d_mode", "scaling_3d_scale", "screen_space_aa", "use_taa",
	"positional_shadow_atlas_size", "mesh_lod_threshold", "texture_mipmap_bias", "use_debanding",
	"vrs_mode", "fsr_sharpness"]

@export var mode := 1
@export var fov := 62.0
@export var window_size := Vector2i(1600, 900)
@export var window_position := Vector2i(2600, 190)
## In VR: show the spectator in the game window (true) or a separate OS window (false).
@export var embed := true
## Smooth mode filter: lower cutoff = steadier, higher beta = less lag on fast turns.
@export var allowed_jitter := 0.9
@export var lag_reduction := 3.0
@export var rotation_smoothing := 0.93
@export var level_roll := true
## Third/face modes: where the camera sits relative to the body and how quickly it settles.
@export var third_distance := 2.4
@export var third_height := 1.85
@export var face_distance := 1.5
@export var follow_time := 0.35
@export var orbit_radius := 2.6
@export var orbit_height := 1.15
@export var orbit_period := 28.0

var head: Node3D        # the player's camera (XRCamera3D or desktop Camera3D)
var body: Node3D        # the player's body root
var mare: Node3D          # the mare the shots frame: nearest of `ponies` to the player
var ponies: Array = []
var window: Window
var camera: Camera3D
var xr_view: SubViewport
var listener: AudioListener3D
var _filters: Array = []
var _position := Vector3.ZERO
var _look := Vector3.ZERO
var _yaw := 0.0
var _orbit := 0.0
var _started := false
var _settings_clock := 0.0


func setup(player_head: Node3D, player_body: Node3D, target_mare: Node3D) -> void:
	head = player_head
	body = player_body
	mare = target_mare
	if target_mare != null: ponies.append(target_mare)
	camera = Camera3D.new()
	camera.name = "SpectatorCamera"
	camera.fov = fov
	camera.near = 0.03
	camera.far = 1200.0
	if embed and get_viewport().use_xr:
		_embed_in_game_window()
	else:
		_open_window()
	for i in 3:
		_filters.append(ONE_EURO.new({"cutoff": allowed_jitter, "beta": lag_reduction}))


## VR: the rig renders to the headset from its own SubViewport; the game window shows `camera`.
func _embed_in_game_window() -> void:
	var root := get_tree().root
	var rig: Node = head
	while rig.get_parent() != null and rig.get_parent() != get_parent():
		rig = rig.get_parent()
	xr_view = SubViewport.new()
	xr_view.name = "XRView"
	xr_view.use_xr = true
	xr_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	xr_view.audio_listener_enable_3d = false
	var iface := XRServer.primary_interface
	if iface != null:
		xr_view.size = Vector2i(iface.get_render_target_size())
	_copy_view_settings()
	get_parent().add_child(xr_view)
	rig.reparent(xr_view)
	if head is Camera3D:
		(head as Camera3D).make_current()
	PLAYER_VIEW.xr_viewport = xr_view
	root.use_xr = false
	add_child(camera)
	camera.make_current()
	listener = AudioListener3D.new()
	listener.name = "HeadListener"
	add_child(listener)
	listener.make_current()
	print("[spectator] in the game window, headset view %s, mode %s" % [xr_view.size, MODES[mode - 1]])


## Desktop (or --spectator-separate): a second OS window with the spectator camera.
func _open_window() -> void:
	get_tree().root.gui_embed_subwindows = false
	window = Window.new()
	window.name = "SpectatorWindow"
	window.title = "Home: Equestria — spectator"
	window.size = window_size
	window.position = window_position
	window.unresizable = false
	window.transparent_bg = false
	add_child(window)
	window.add_child(camera)
	camera.make_current()
	window.window_input.connect(func(event: InputEvent): _mode_key(event))
	window.close_requested.connect(func(): set_mode(mode))
	print("[spectator] window %s at %s, mode %s" % [window.size, window.position, MODES[mode - 1]])


func _copy_view_settings() -> void:
	var root := get_tree().root
	for property: String in VIEW_SETTINGS:
		if property in root and xr_view.get(property) != root.get(property):
			xr_view.set(property, root.get(property))


func _exit_tree() -> void:
	if PLAYER_VIEW.xr_viewport == xr_view:
		PLAYER_VIEW.xr_viewport = null


func set_mode(value: int) -> void:
	mode = clampi(value, 1, MODES.size())
	_started = false
	print("[spectator] mode %d %s" % [mode, MODES[mode - 1]])


func _unhandled_input(event: InputEvent) -> void:
	if _mode_key(event):
		get_viewport().set_input_as_handled()
		return
	# Embedded recording moves the player under an XR SubViewport. SubViewports
	# do not receive the window's keyboard events automatically.
	if is_instance_valid(xr_view) and event is InputEventKey:
		xr_view.push_input(event, true)
		if xr_view.is_input_handled():get_viewport().set_input_as_handled()


## V cycles, Shift+1..4 picks. Returns true when the key was a spectator key.
func _mode_key(event: InputEvent) -> bool:
	if not (event is InputEventKey) or not event.pressed or event.echo: return false
	var key := (event as InputEventKey).physical_keycode
	if key == KEY_V:
		set_mode(mode % MODES.size() + 1)
		return true
	if key >= KEY_1 and key <= KEY_4 and event.shift_pressed:
		set_mode(key - KEY_1 + 1)
		return true
	return false


func _process(delta: float) -> void:
	if head == null or camera == null: return
	if listener != null:
		listener.global_transform = head.global_transform
	if xr_view != null:
		_settings_clock -= delta
		if _settings_clock <= 0.0:
			_settings_clock = 1.0
			_copy_view_settings()
	var head_pose := head.global_transform
	var alpha := 1.0 - exp(-delta / follow_time)
	match mode:
		1:
			_smooth(head_pose, delta)
			return
		2:
			var forward := _flat_forward(head_pose.basis)
			var wanted := head_pose.origin - forward * third_distance
			wanted.y = body.global_position.y + third_height if body != null else head_pose.origin.y + 0.4
			var focus := head_pose.origin + forward * 1.2
			if _mare_near(6.0):
				focus = focus.lerp(_mare_head(), 0.5)
			_settle(wanted, focus, alpha)
		3:
			_orbit += delta * TAU / orbit_period
			var centre: Vector3 = _mare_head() if _mare_near(12.0) else head_pose.origin
			var wanted := centre + Vector3(sin(_orbit) * orbit_radius, 0.0, cos(_orbit) * orbit_radius)
			wanted.y = (mare.global_position.y if _mare_near(12.0) else body.global_position.y) + orbit_height
			_settle(wanted, centre, alpha)
		4:
			var forward := _flat_forward(head_pose.basis)
			var wanted := head_pose.origin + forward * face_distance
			wanted.y = head_pose.origin.y - 0.15
			var focus := head_pose.origin
			if _mare_near(2.5):
				focus = focus.lerp(_mare_head(), 0.4)
			_settle(wanted, focus, alpha)


func _smooth(head_pose: Transform3D, delta: float) -> void:
	var origin := head_pose.origin
	var filtered := Vector3(_filters[0].filter(origin.x, delta), _filters[1].filter(origin.y, delta),
		_filters[2].filter(origin.z, delta))
	var target_basis := head_pose.basis.orthonormalized()
	if level_roll:
		var forward := -target_basis.z
		var right := forward.cross(Vector3.UP)
		if right.length() > 0.05:
			right = right.normalized()
			target_basis = Basis(right, right.cross(forward).normalized(), -forward)
	var current := camera.global_transform.basis.orthonormalized() if _started else target_basis
	var q1 := Quaternion(current)
	var q2 := Quaternion(target_basis)
	var blended := q1.slerp(q2, 1.0 - pow(rotation_smoothing, delta * 60.0))
	camera.global_transform = Transform3D(Basis(blended), filtered)
	_started = true


func _settle(wanted: Vector3, focus: Vector3, alpha: float) -> void:
	if not _started:
		_position = wanted
		_look = focus
		_started = true
	_position = _position.lerp(wanted, alpha)
	_look = _look.lerp(focus, alpha)
	# Pull the camera in front of walls between the subject and the lens.
	var space := camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(_look, _position, 1)
	var hit := space.intersect_ray(query)
	var origin: Vector3 = _position
	if hit.has("position"):
		origin = (hit.position as Vector3) + ((_look - _position).normalized() * 0.15)
	if origin.distance_to(_look) > 0.05:
		camera.global_transform = Transform3D.IDENTITY.translated(origin).looking_at(_look, Vector3.UP)


func _flat_forward(basis: Basis) -> Vector3:
	var forward := -basis.z
	forward.y = 0.0
	if forward.length() < 0.05:
		forward = Vector3(sin(_yaw), 0.0, cos(_yaw))
	forward = forward.normalized()
	_yaw = atan2(forward.x, forward.z)
	return forward


## Another mare the spectator may frame; the nearest one to the player is chosen each frame.
func add_mare(target: Node3D) -> void:
	if target != null and target not in ponies:
		ponies.append(target)
	if mare == null:
		mare = target


func _pick_mare() -> void:
	if head == null:
		return
	var best: Node3D = null
	var best_distance := INF
	for candidate in ponies:
		if candidate == null or not is_instance_valid(candidate):
			continue
		var d: float = candidate.global_position.distance_to(head.global_position)
		if d < best_distance:
			best_distance = d
			best = candidate
	if best != null:
		mare = best


func _mare_near(distance: float) -> bool:
	_pick_mare()
	return mare != null and is_instance_valid(mare) and head != null \
		and mare.global_position.distance_to(head.global_position) < distance


func _mare_head() -> Vector3:
	if mare != null and is_instance_valid(mare) and mare.get("boop_node") != null and mare.boop_node.snoot != null:
		return mare.boop_node.nose_world()
	return mare.global_position + Vector3.UP * 0.8
