extends CanvasLayer
## Debug distance tool (dev 2026-10-23: "a measuring tool ... she'll be locked in place and on
## my hud it'll say how many meters she is from me"). N on the pony nearest the crosshair holds
## her in place and shows her live distance; N again (on her or on nothing) lets her go, N on
## another pony switches. Developer builds only (world/dev_tools.gd); K stays the kiss key.
## Picks by angle, not physics, so ponies on the far tiers (no active collider) still count.
const PICK_DEGREES := 4.0
const PICK_RANGE := 600.0
var _pony: Node3D
var _was_wandering := false
var _label: Label
var _hold := 0.0

func _ready() -> void:
	layer = 90
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 28)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 8)
	_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_label.position.y = 60.0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_label.visible = false
	add_child(_label)

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.physical_keycode != KEY_N: return
	var picked := _pick()
	var previous := _pony
	_release()
	if picked != null and picked != previous: _lock(picked)
	get_viewport().set_input_as_handled()

func _pick() -> Node3D:
	var camera := get_viewport().get_camera_3d()
	if camera == null: return null
	var forward := -camera.global_basis.z
	var best: Node3D
	var best_angle := deg_to_rad(PICK_DEGREES)
	for node in get_tree().get_nodes_in_group("sim_ponies"):
		var pony := node as Node3D
		if pony == null or not pony.is_inside_tree(): continue
		var to := pony.global_position + Vector3.UP * 0.8 - camera.global_position
		if to.length() > PICK_RANGE or to.length() < 0.3: continue
		var angle := forward.angle_to(to)
		if angle < best_angle: best_angle = angle; best = pony
	return best

func _lock(pony: Node3D) -> void:
	_pony = pony
	var nav: Node = pony.get_node_or_null("Navigator")
	if nav != null:
		_was_wandering = bool(nav.get("wander_enabled"))
		nav.stay(); nav.set("command_owner", "debug:measure")
	_label.visible = true

func _release() -> void:
	if is_instance_valid(_pony):
		var nav: Node = _pony.get_node_or_null("Navigator")
		if nav != null and str(nav.get("command_owner")) == "debug:measure":
			nav.set("command_owner", "")
			nav.set("wander_enabled", _was_wandering)
	_pony = null
	_label.visible = false

func _process(delta: float) -> void:
	if _pony == null: return
	if not is_instance_valid(_pony) or not _pony.is_inside_tree():
		_release(); return
	var camera := get_viewport().get_camera_3d()
	if camera == null: return
	# Routines may try to move her; keep re-asserting the hold twice a second.
	_hold -= delta
	if _hold <= 0.0:
		_hold = 0.5
		var nav: Node = _pony.get_node_or_null("Navigator")
		if nav != null and str(nav.get("command_owner")) != "debug:measure":
			nav.stay(); nav.set("command_owner", "debug:measure")
	var offset := _pony.global_position - camera.global_position
	var flat := Vector2(offset.x, offset.z).length()
	var identity: Resource = _pony.get("identity") if "identity" in _pony else null
	var name_text := str(identity.get("display_name")) if identity != null and identity.get("display_name") != null else str(_pony.name)
	_label.text = "%s: %.1f m  (ground %.1f m, height %+.1f m)\nN: release" % [name_text, offset.length(), flat, offset.y]

func _exit_tree() -> void:
	_release()
