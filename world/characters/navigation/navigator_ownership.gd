extends RefCounted
## Who may command a navigator (split from pony_navigator.gd, 2026-10-13). The fields stay on
## the navigator (`command_owner`, `wander_enabled`, `reserved_by`, `denied_owners`, ...); these
## static functions hold the rules for a story encounter's reservation
## (docs/plans/AI_CONTEXT_AND_INTERRUPTION_RESILIENCE_2026_10_02.md).


## The `command_owner` setter's check while she is reserved: false records a refused takeover.
static func admit_owner(nav: Node, value: String) -> bool:
	if nav._owner_permitted(value): return true
	nav._owner_denied_at = Vector2i(Engine.get_process_frames(), Engine.get_physics_frames())
	var denied: Array = nav.denied_owners
	denied.append(value)
	if denied.size() > 16: denied.pop_front()
	var pony: Variant = nav.pony
	print("[presence] %s is reserved by %s: refused %s" % [pony.name if is_instance_valid(pony) else "?", nav.reserved_by, value])
	return false


## Model tag command ids (pony_action_schema.gd: "t<turn>-<index>-<type>").
static var AI_TAG_ID := RegEx.create_from_string("^t\\d+-\\d+-[a-z_]+$")

static func owner_permitted(nav: Node, owner: String) -> bool:
	for prefix: String in nav._reserved_owners:
		if prefix == "ai:":
			if AI_TAG_ID.search(owner) != null: return true
		elif owner.begins_with(prefix): return true
	# The AI's own small, compatible moves during the scene (tag ids end with their type).
	return owner.ends_with("-approach") or owner.ends_with("-stay")


static func reserve(nav: Node, encounter: String, owners: Array) -> void:
	if nav.reserved_by == encounter:
		nav._reserved_owners = owners.duplicate()
		return
	if String(nav.reserved_by).is_empty(): nav._reserved_wander = nav.wander_enabled
	nav.reserved_by = encounter
	nav._reserved_owners = owners.duplicate()
	nav.wander_enabled = false
	var owner: String = nav.command_owner
	if not nav._owner_permitted(owner) and (owner != "" or nav._has_target or nav._wandering):
		nav.stay()
		nav.command_owner = ""
	var pony: Variant = nav.pony
	print("[presence] %s reserved by %s" % [pony.name if is_instance_valid(pony) else "?", encounter])


static func release_reservation(nav: Node, encounter: String) -> void:
	if nav.reserved_by != encounter: return
	nav.reserved_by = ""
	nav._reserved_owners = []
	nav.wander_enabled = nav._reserved_wander
	var pony: Variant = nav.pony
	print("[presence] %s released by %s" % [pony.name if is_instance_valid(pony) else "?", encounter])


## Movement refused while reserved: no permitted owner holds her, or a takeover was just refused.
static func movement_refused(nav: Node, kind: String) -> bool:
	if String(nav.reserved_by).is_empty(): return false
	var denied_at: Vector2i = nav._owner_denied_at
	var owner: String = nav.command_owner
	var just_denied := denied_at.x == Engine.get_process_frames() or denied_at.y == Engine.get_physics_frames()
	if just_denied or owner == "" or not nav._owner_permitted(owner):
		var denied: Array = nav.denied_owners
		denied.append("%s by %s" % [kind, owner if owner != "" else "routine"])
		if denied.size() > 16: denied.pop_front()
		return true
	return false
