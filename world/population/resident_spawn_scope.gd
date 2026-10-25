extends RefCounted
## Owns an unattached actor until safe placement commits it to the world.
## Tree exit wakes the suspended caller before the final physics frame disappears.
signal resumed
var _host: Node3D
var _tree: SceneTree
var _rig: Node3D
var _requester: Node
var cancelled := false

func _init(host: Node3D, rig: Node3D, requester: Node = null) -> void:
	_host = host; _tree = host.get_tree(); _rig = rig
	host.tree_exiting.connect(_cancel, CONNECT_ONE_SHOT)
	_requester = requester
	if is_instance_valid(requester) and requester != host:
		requester.tree_exiting.connect(_cancel, CONNECT_ONE_SHOT)

## Optional bounded callers (overnight visitors) abandon unsupported placement before waking.
func _deadline_passed() -> bool:
	return is_instance_valid(_requester) and _requester.has_meta("resident_spawn_deadline_msec") and Time.get_ticks_msec() >= int(_requester.get_meta("resident_spawn_deadline_msec"))

func current() -> bool:
	return not cancelled and not _deadline_passed() and is_instance_valid(_host) and _host.is_inside_tree() and not _host.is_queued_for_deletion() and not (is_instance_valid(_requester) and _requester.is_queued_for_deletion())

func wait_physics_frame() -> bool:
	if not current():
		finish(false)
		return false
	_tree.physics_frame.connect(_wake, CONNECT_ONE_SHOT)
	await resumed
	if _tree.physics_frame.is_connected(_wake): _tree.physics_frame.disconnect(_wake)
	if not current():
		finish(false)
		return false
	return true

func _wake() -> void: resumed.emit()

func _cancel() -> void:
	cancelled = true
	finish(false)
	resumed.emit()

func finish(keep_rig: bool) -> void:
	if is_instance_valid(_host) and _host.tree_exiting.is_connected(_cancel):
		_host.tree_exiting.disconnect(_cancel)
	if is_instance_valid(_requester) and _requester.tree_exiting.is_connected(_cancel):
		_requester.tree_exiting.disconnect(_cancel)
	if is_instance_valid(_tree) and _tree.physics_frame.is_connected(_wake):
		_tree.physics_frame.disconnect(_wake)
	if not keep_rig and is_instance_valid(_rig): _rig.free()
	_rig = null
