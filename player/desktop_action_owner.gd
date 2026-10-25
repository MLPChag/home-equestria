extends RefCounted
## One contextual desktop action owns acquisition/mouse drag at a time.
## Menus cancel the owner BEFORE saving/replacing controls_locked and mouse mode.
const KEY := &"desktop_activity_owner"

static func current(ui: Node) -> Node:
	if not is_instance_valid(ui) or not ui.has_meta(KEY): return null
	var owner: Variant = ui.get_meta(KEY)
	return owner if is_instance_valid(owner) and owner is Node else null

static func available(ui: Node, requester: Node = null) -> bool:
	var owner := current(ui)
	return owner == null or owner == requester

static func claim(ui: Node, owner: Node) -> bool:
	if not is_instance_valid(ui) or not is_instance_valid(owner) or not available(ui, owner): return false
	ui.set_meta(KEY, owner)
	return true

static func release(ui: Node, owner: Node) -> void:
	if is_instance_valid(ui) and ui.has_meta(KEY) and current(ui) == owner: ui.remove_meta(KEY)

static func cancel_current(ui: Node) -> void:
	var owner := current(ui)
	if owner == null:
		if is_instance_valid(ui) and ui.has_meta(KEY): ui.remove_meta(KEY)
		return
	if owner.has_method("cancel_desktop_activity"): owner.cancel_desktop_activity()
	# Release only this claim; the callback may deliberately install another owner.
	release(ui, owner)
